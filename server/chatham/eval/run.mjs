#!/usr/bin/env node
// Chatham Gate evaluation runner.
// node server/chatham/eval/run.mjs [--mock] [--layers L0,L1,...] [--ablation] [--only id1,id2]
//                                  [--threshold 0.5] [--flag-threshold 0.7] [--attack-samples 1] [--concurrency 4]

import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { computeLeaks, attackAccuracy, retention as retentionMean, aggregate, redact } from './metrics.mjs';
import { mockAttack, llmAttack, mockRetention, llmRetention, hasKey, LLM_MODEL, mockAttackNames, llmOutsider, mockOutsider, scoreOutsider } from './judge.mjs';

// ASSUMPTION: DeepSeek "flash" list prices; verify against the current price sheet before quoting.
export const PRICE = { inputPerM: 0.07, outputPerM: 0.28, note: 'assumed DeepSeek flash: $0.07/M in, $0.28/M out' };

const HERE = path.dirname(fileURLToPath(import.meta.url));
// Test-only overrides (smoke tests with stub fixtures); defaults follow CONTRACT.md layout.
const DATA_DIR = process.env.CHATHAM_EVAL_DATA_DIR || path.join(HERE, 'data');
const OUT_DIR = process.env.CHATHAM_EVAL_OUT_DIR || HERE;
const GATE_MODULE = process.env.CHATHAM_EVAL_GATE_MODULE || path.join(HERE, '..', 'lib', 'gate.mjs');
const ALL = ['L0', 'L1', 'L2', 'L3', 'L4'];
const ABLATION = [
  // Floor: attacker sees ONLY roster + the gold idea texts (no digest). Measures how much
  // attribution is inherent in the ideas themselves (role-linked content) — no gate can go below it
  // without destroying the idea.
  { name: 'ideas-only', layers: null, empty: true },
  { name: 'raw', layers: [] },
  { name: 'L0+L1', layers: ['L0', 'L1'] },
  { name: '+L2', layers: ['L0', 'L1', 'L2'] },
  { name: '+L3', layers: ['L0', 'L1', 'L2', 'L3'] },
  { name: '+L4', layers: [...ALL] },
];
const KNOWLEDGE_CONFIGS = new Set(['ideas-only', 'raw', '+L3', '+L4']);

function parseArgs(argv) {
  const a = { mock: false, layers: null, ablation: false, only: null, threshold: 0.5, flagThreshold: 0.7, attackSamples: 1, concurrency: 4 };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const val = () => {
      if (k.includes('=')) return k.slice(k.indexOf('=') + 1);
      const v = argv[++i];
      if (v === undefined) throw new Error(`missing value for ${k}`);
      return v;
    };
    const key = k.split('=')[0];
    if (key === '--mock') a.mock = true;
    else if (key === '--ablation') a.ablation = true;
    else if (key === '--layers') a.layers = val().split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
    else if (key === '--only') a.only = val().split(',').map((s) => s.trim()).filter(Boolean);
    else if (key === '--threshold') a.threshold = Number(val());
    else if (key === '--flag-threshold') a.flagThreshold = Number(val());
    else if (key === '--attack-samples') a.attackSamples = Math.max(1, parseInt(val(), 10) || 1);
    else if (key === '--concurrency') a.concurrency = Math.max(1, parseInt(val(), 10) || 4);
    else if (key === '-h' || key === '--help') { a.help = true; }
    else throw new Error(`unknown argument: ${k}`);
  }
  if (a.layers) {
    const bad = a.layers.filter((l) => !ALL.includes(l) && l !== 'RAW');
    if (bad.length) throw new Error(`unknown layer(s): ${bad.join(',')}`);
    if (a.layers.includes('RAW')) a.layers = [];
  }
  return a;
}

async function loadTranscripts(only) {
  let files;
  try { files = (await readdir(DATA_DIR)).filter((f) => f.endsWith('.json')).sort(); }
  catch { throw new Error(`no data directory at ${DATA_DIR}`); }
  const out = [];
  for (const f of files) {
    const t = JSON.parse(await readFile(path.join(DATA_DIR, f), 'utf8'));
    t.id ??= f.replace(/\.json$/, '');
    if (only && !only.includes(t.id)) continue;
    t.gold ??= { identifiers: [], ideas: [] };
    t.gold.identifiers ??= [];
    t.gold.ideas ??= [];
    t.roster ??= [];
    out.push(t);
  }
  if (!out.length) throw new Error(`no transcripts loaded from ${DATA_DIR}${only ? ` matching --only ${only}` : ''}`);
  return out;
}

async function pool(items, limit, fn) {
  const res = new Array(items.length);
  let next = 0;
  const worker = async () => { while (next < items.length) { const i = next++; res[i] = await fn(items[i], i); } };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return res;
}

async function evalOne(runGate, t, cfg, opts) {
  const row = { transcript: t.id, config: cfg.name, layers: cfg.layers };
  let gate;
  const t0 = performance.now();
  try {
    gate = cfg.empty
      ? { digest: '(no digest available)', claims: [], meta: { promptTokens: 0, completionTokens: 0, ms: 0 } }
      : await runGate(t, { layers: cfg.layers, mock: !opts.llm, threshold: opts.threshold, flagThreshold: opts.flagThreshold });
  } catch (e) {
    return { ...row, error: `runGate: ${e?.message || e}` };
  }
  row.ms = Math.round(performance.now() - t0);
  row.gateMetaMs = gate?.meta?.ms;
  row.digest = String(gate?.digest ?? '');
  row.claims = gate?.claims;
  row.meta = gate?.meta;
  row.promptTokens = gate?.meta?.promptTokens || 0;
  row.completionTokens = gate?.meta?.completionTokens || 0;

  row.leaks = computeLeaks(row.digest, t);

  const ideas = t.gold.ideas;
  const N = t.roster.length || 1;
  row.evalUsage = { promptTokens: 0, completionTokens: 0 };
  const addUsage = (u) => { row.evalUsage.promptTokens += u?.prompt_tokens || 0; row.evalUsage.completionTokens += u?.completion_tokens || 0; };

  // attribution attack (averaged over samples)
  try {
    const samples = [];
    const nS = opts.llm ? opts.attackSamples : 1; // mock is deterministic: one sample is enough
    for (let s = 0; s < nS; s++) {
      if (opts.llm) { const r = await llmAttack(t.roster, row.digest, ideas, { sample: s }); addUsage(r.usage); samples.push(r.guesses); }
      else samples.push(mockAttack(t.roster, row.digest, ideas));
    }
    const accs = samples.map((g) => attackAccuracy(g, ideas));
    const correct = accs.reduce((a, x) => a + x.correct, 0) / samples.length; // mean correct per sample
    row.attack = { correct, total: ideas.length, acc: ideas.length ? correct / ideas.length : null, baselineSum: ideas.length / N, baseline: 1 / N, samples: samples.length, guesses: samples };
  } catch (e) {
    row.attack = { correct: 0, total: 0, acc: null, baselineSum: 0, error: String(e?.message || e) };
  }

  // attacker knowledge levels (b) names-only and (c) outsider — for raw / +L3 / +L4 (and ideas-only floor for b)
  if (KNOWLEDGE_CONFIGS.has(cfg.name)) {
    try {
      const g = opts.llm ? await llmAttack(t.roster, row.digest, ideas, { knowledge: 'names' }) : { guesses: mockAttackNames(t.roster, row.digest, ideas) };
      addUsage(g.usage);
      const a = attackAccuracy(g.guesses, ideas);
      row.attackNames = { correct: a.correct, total: a.total, acc: a.acc };
    } catch (e) { row.attackNames = { correct: 0, total: 0, acc: null, error: String(e?.message || e) }; }
    if (!cfg.empty) try {
      const o = opts.llm ? await llmOutsider(row.digest, ideas) : mockOutsider(t.roster, row.digest);
      addUsage(o.usage);
      row.outsider = { ...scoreOutsider(t.roster, ideas, o), guessedAttendees: (o.attendees || []).length };
    } catch (e) { row.outsider = { error: String(e?.message || e) }; }
  }
  // strict digest (role-revealing flagged claims cut) — full-roster attack + retention
  if (gate?.digestStrict && gate?.meta?.flagged && opts.llm) {
    try {
      const g = await llmAttack(t.roster, gate.digestStrict, ideas, {}); addUsage(g.usage);
      const r = await llmRetention(gate.digestStrict, ideas); addUsage(r.usage);
      row.strict = { attack: attackAccuracy(g.guesses, ideas), retention: retentionMean(r.scores) };
    } catch (e) { row.strict = { error: String(e?.message || e) }; }
  }
  row.flagged = gate?.meta?.flagged || 0;
  row.claimCount = gate?.claims?.length || 0;

  // idea retention
  try {
    let scores;
    if (opts.llm) { const r = await llmRetention(row.digest, ideas); addUsage(r.usage); scores = r.scores; }
    else scores = mockRetention(row.digest, ideas);
    row.retention = { sum: scores.reduce((a, s) => a + s.score, 0), n: scores.length, mean: retentionMean(scores), scores };
  } catch (e) {
    row.retention = { sum: 0, n: 0, mean: null, error: String(e?.message || e) };
  }
  return row;
}

// ---------------------------------------------------------------- formatting
const pct = (x) => (x == null ? '—' : (x * 100).toFixed(1));
const num = (x, d = 0) => (x == null ? '—' : Number(x).toFixed(d));
const COLS = ['config', 'directLeak%', 'affilLeak%', 'quasiLeak%', 'styleLeak%', 'attackAcc%', 'randomBaseline%', 'retention%', 'avgLatencyMs', 'tokens', 'est$'];

function aggCells(name, a) {
  return [name, pct(a.directLeak), pct(a.affilLeak), pct(a.quasiLeak), pct(a.styleLeak), pct(a.attackAcc), pct(a.randomBaseline), pct(a.retention), num(a.avgLatencyMs), String(a.tokens), a.usd.toFixed(5)];
}
function rowCells(r) {
  if (r.error) return [r.transcript, r.config, 'ERROR', '', '', '', '', '', '', '', '', ''];
  const lr = (c) => { const b = r.leaks.by[c]; return b.total ? `${pct(b.leaked / b.total)} (${b.leaked}/${b.total})` : '—'; };
  return [r.transcript, r.config, lr('direct'), lr('affil'), lr('quasi'), lr('style'), pct(r.attack?.acc), pct(r.attack?.baseline), pct(r.retention?.mean), num(r.ms), String(r.promptTokens + r.completionTokens), (((r.promptTokens * PRICE.inputPerM) + (r.completionTokens * PRICE.outputPerM)) / 1e6).toFixed(5)];
}
const KCOLS = ['config', '(a) fullRoster attack%', '(b) namesOnly attack%', '(c) outsider: roster members named', '(c) outsider: speaker hit%', 'random%'];
const FCOLS = ['transcript', 'flagged/claims', 'dropped', 'strict attack%', 'strict retention%'];
const ROW_COLS = ['transcript', 'config', 'directLeak%', 'affilLeak%', 'quasiLeak%', 'styleLeak%', 'attackAcc%', 'randomBaseline%', 'retention%', 'latencyMs', 'tokens', 'est$'];

const width = (s) => [...String(s)].reduce((w, ch) => w + (/[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(ch) ? 2 : 1), 0);
function textTable(head, rows) {
  const w = head.map((h, i) => Math.max(width(h), ...rows.map((r) => width(r[i] ?? ''))));
  const line = (r) => r.map((c, i) => String(c ?? '') + ' '.repeat(w[i] - width(c ?? ''))).join('  ');
  return [line(head), w.map((n) => '-'.repeat(n)).join('  '), ...rows.map(line)].join('\n');
}
function mdTable(head, rows) {
  const esc = (c) => String(c ?? '').replace(/\|/g, '\\|');
  return [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...rows.map((r) => `| ${r.map(esc).join(' | ')} |`)].join('\n');
}

// ---------------------------------------------------------------- main
async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('usage: node server/chatham/eval/run.mjs [--mock] [--layers L0,L1,L2,L3,L4] [--ablation] [--only id1,id2] [--threshold 0.5] [--flag-threshold 0.7] [--attack-samples 1] [--concurrency 4]');
    return;
  }
  const keyPresent = hasKey();
  const llm = keyPresent && !args.mock;
  const modeLabel = llm ? `LLM (judge model: ${LLM_MODEL})` : 'MOCK — offline heuristics, NOT LLM numbers';
  const outBase = keyPresent && args.mock ? 'results-mock' : 'results';

  let runGate;
  try {
    ({ runGate } = await import(pathToFileURL(path.resolve(GATE_MODULE)).href));
  } catch (e) {
    throw new Error(`cannot import lib/gate.mjs: ${e?.message || e}`);
  }
  if (typeof runGate !== 'function') throw new Error('lib/gate.mjs does not export runGate');

  const transcripts = await loadTranscripts(args.only);
  const configs = args.layers && !args.ablation
    ? [{ name: args.layers.length ? args.layers.join('+') : 'raw', layers: args.layers }]
    : ABLATION;

  console.log(`Chatham Gate eval — ${new Date().toISOString()}`);
  console.log(`mode: ${modeLabel}; gate mock=${!llm}; transcripts: ${transcripts.map((t) => t.id).join(', ')}; threshold=${args.threshold}; flagThreshold=${args.flagThreshold}; attack samples=${llm ? args.attackSamples : 1}`);
  if (!keyPresent && !args.mock) console.log('(CHATHAM_LLM_KEY not set → falling back to mock mode)');

  const opts = { llm, threshold: args.threshold, flagThreshold: args.flagThreshold, attackSamples: args.attackSamples };
  const allRows = [];
  const aggs = [];
  for (const cfg of configs) {
    const rows = await pool(transcripts, args.concurrency, (t) => evalOne(runGate, t, cfg, opts));
    for (const r of rows) if (r.error) console.error(`  [${cfg.name}] ${r.transcript}: ${r.error}`);
    allRows.push(...rows);
    aggs.push({ config: cfg.name, layers: cfg.layers, ...aggregate(rows, PRICE) });
  }

  const aggTable = aggs.map((a) => aggCells(a.config, a));
  const P = (a, b) => (b ? pct(a / b) : '—');
  const S = (rows, f) => rows.reduce((x, r) => x + (f(r) || 0), 0);
  const kTable = configs.filter((c) => KNOWLEDGE_CONFIGS.has(c.name)).map((c) => {
    const rs = allRows.filter((r) => r.config === c.name && !r.error);
    const o = rs.filter((r) => r.outsider && !r.outsider.error);
    return [c.name,
      P(S(rs, (r) => r.attack?.correct), S(rs, (r) => r.attack?.total)),
      P(S(rs, (r) => r.attackNames?.correct), S(rs, (r) => r.attackNames?.total)),
      c.empty ? '—' : `${S(o, (r) => r.outsider.exposed)}/${S(o, (r) => r.outsider.n)} (${S(o, (r) => r.outsider.people)} by name, ${S(o, (r) => r.outsider.orgs)} by org)`,
      c.empty ? '—' : P(S(o, (r) => r.outsider.speakerHits), S(o, (r) => r.outsider.ideas)),
      P(S(rs, (r) => r.attack?.baselineSum), S(rs, (r) => r.attack?.total))];
  });
  const fTable = configs.filter((c) => c.name === '+L4').flatMap((c) => {
    const rs = allRows.filter((r) => r.config === c.name && !r.error);
    const st = rs.filter((r) => r.strict && !r.strict.error);
    const per = rs.map((r) => [r.transcript, `${r.flagged}/${r.claimCount}`, String(r.meta?.dropped ?? 0), r.strict?.attack ? pct(r.strict.attack.acc) : '—', r.strict?.retention != null ? pct(r.strict.retention) : '—']);
    const sA = S(st, (r) => r.strict.attack.correct), sT = S(st, (r) => r.strict.attack.total);
    return [...per, ['ALL', `${S(rs, (r) => r.flagged)}/${S(rs, (r) => r.claimCount)}`, String(S(rs, (r) => r.meta?.dropped)), P(sA, sT), st.length ? pct(S(st, (r) => r.strict.retention) / st.length) : '—']];
  });
  const perRows = transcripts.flatMap((t) => allRows.filter((r) => r.transcript === t.id)).map(rowCells);

  console.log('\nAggregate (pooled over transcripts)' + (llm ? '' : ' [MOCK: attack/retention are heuristic, not LLM]'));
  console.log(textTable(COLS, aggTable));
  console.log('\nAttacker knowledge levels');
  console.log(textTable(KCOLS, kTable));
  console.log('\nRole-revealing risk flags (L4 residual)');
  console.log(textTable(FCOLS, fTable));
  console.log('\nPer transcript');
  console.log(textTable(ROW_COLS, perRows));
  console.log(`\nest$ uses ${PRICE.note} (assumption). Latency/tokens are gate-only; eval-judge calls excluded.`);

  // ---------- results.md
  const ts = new Date().toISOString();
  const md = [];
  md.push('# Chatham Gate — evaluation results', '');
  md.push(`- Run: ${ts}`);
  md.push(`- Mode: ${modeLabel}`);
  md.push(`- Gate run with mock=${!llm}; threshold=${args.threshold}; flagThreshold=${args.flagThreshold}; attack samples=${llm ? args.attackSamples : 1}`);
  md.push(`- Transcripts: ${transcripts.map((t) => `${t.id} (${t.roster.length} speakers, ${t.gold.ideas.length} ideas, ${t.gold.identifiers.length} identifiers)`).join('; ')}`);
  md.push(`- Cost estimate: ${PRICE.note} — **assumption**. Latency and tokens are gate-only (judge/attacker calls excluded).`);
  md.push('- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.');
  if (!llm) md.push('- **MOCK numbers**: attacker and retention judge are deterministic bigram heuristics, not an LLM. Do not quote as LLM results.');
  md.push('', '## Aggregate', '', mdTable(COLS, aggTable), '');
  md.push('## Attacker knowledge levels', '', '(a) full roster incl. org/title (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.', '', mdTable(KCOLS, kTable), '');
  md.push('## Role-revealing risk flags (L4 residual)', '', 'Claims still attributable at ≥ threshold after the last L4 round are marked `[review: role-revealing]` for human review instead of being silently kept or dropped. "strict" = the digest with all flagged claims cut (full-roster attacker).', '', mdTable(FCOLS, fTable), '');
  md.push('## How to read this', '',
    '- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. Its accuracy is the attribution that is inherent in *what* was said (e.g. "only the oncologist would argue for surgery"). No de-identification that keeps the idea can push the full-roster attack much below that floor.',
    '- **(a) full roster with org/title** is an insider: someone in the room, or who knows the attendee list and their jobs. The Gate removes the surface signals (names, orgs, style) and brings accuracy from ~raw down to about the ideas-only floor, but not to random 1/N. That gap is the honest core finding: role-linked content stays attributable to insiders.',
    '- **(c) outsider with no roster** is the outward threat the Rule targets: the digest must not reveal who attended. This is the number to watch for public release.',
    '- Role-revealing flags (`--flag-threshold`, default 0.7) are a review aid, not a guarantee. The full digest is what an insider sees if reviewers keep everything; "strict" is the digest if reviewers cut every flagged claim.',
    '- Attacker, generaliser and judge all use the same model (deepseek-flash). A stronger or differently-trained attacker may do better. n = 7 synthetic transcripts × 8–9 ideas, 2 attack samples: differences of a few points are noise.', '');
  md.push('## Per transcript', '', mdTable(ROW_COLS, perRows), '');
  md.push('## Leaked identifiers per config', '', '_Leaked strings are redacted to their first 2 characters._', '');
  for (const cfg of configs) {
    const rows = allRows.filter((r) => r.config === cfg.name && !r.error);
    const leaked = rows.flatMap((r) => r.leaks.items.filter((i) => i.leaked).map((i) => ({ ...i, transcript: r.transcript })));
    md.push(`### ${cfg.name} (${leaked.length} leaked)`, '');
    if (!leaked.length) { md.push('_none_', ''); continue; }
    md.push(mdTable(['transcript', 'category', 'kind', 'owner', 'identifier'], leaked.map((i) => [i.transcript, i.category, i.kind, i.owner, redact(i.text)])), '');
  }
  const errs = allRows.filter((r) => r.error || r.attack?.error || r.retention?.error);
  if (errs.length) {
    md.push('## Errors', '');
    for (const r of errs) md.push(`- ${r.transcript} / ${r.config}: ${r.error || r.attack?.error || r.retention?.error}`);
    md.push('');
  }
  await writeFile(path.join(OUT_DIR, `${outBase}.md`), md.join('\n'), 'utf8');
  await writeFile(path.join(OUT_DIR, `${outBase}.json`), JSON.stringify({
    timestamp: ts, mode: llm ? 'llm' : 'mock', judgeModel: llm ? LLM_MODEL : null, price: PRICE,
    args: { ...args }, configs: aggs, rows: allRows,
  }, null, 2), 'utf8');
  console.log(`\nwrote ${path.join(OUT_DIR, `${outBase}.md`)} and ${outBase}.json`);
}

main().catch((e) => { console.error(`eval failed: ${e?.message || e}`); process.exitCode = 1; });
