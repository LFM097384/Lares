#!/usr/bin/env node
// Gate v2 evaluation runner (forked from the frozen prototype server/chatham/eval/run.mjs).
// node server/anonym-agent/eval/run.mjs [--mock] [--layers L0,L1,...] [--ablation] [--configs +L3,+L4] [--only id1,id2]
//        [--threshold 0.5] [--flag-threshold 0.7] [--attack-samples 1] [--concurrency 4] [--mosaic] [--out results]
// LLM env (eval runner only): LARES_AI_LLM_KEY (required for LLM mode), LARES_AI_LLM_BASE_URL, LARES_AI_LLM_MODEL.
// The key is never logged and never written anywhere.

import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import {
  computeLeaks, attackAccuracy, retention as retentionMean, aggregate, redact,
  publicFactRetention, selfAuthorLeaks, scoreTone, splitSessions,
} from './metrics.mjs';
import {
  mockAttack, llmAttack, mockRetention, llmRetention, hasKey, LLM_MODEL, LLM_BASE_URL, mockAttackNames,
  llmOutsider, mockOutsider, scoreOutsider, mockTone, llmTone,
} from './judge.mjs';

// ASSUMPTION: DeepSeek "flash" list prices; verify against the current price sheet before quoting.
export const PRICE = { inputPerM: 0.07, outputPerM: 0.28, note: 'assumed DeepSeek flash: $0.07/M in, $0.28/M out' };

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = process.env.ANONYM_EVAL_DATA_DIR || path.join(HERE, 'data');
const OUT_DIR = process.env.ANONYM_EVAL_OUT_DIR || HERE;
const GATE_MODULE = process.env.ANONYM_EVAL_GATE_MODULE || path.join(HERE, '..', 'core', 'gate', 'gate.mjs');
const LLM_MODULE = path.join(HERE, '..', 'core', 'gate', 'llm.mjs');
const MEMORY_MODULE = path.join(HERE, '..', 'core', 'memory.mjs');
const PROTO_RESULTS = path.join(HERE, '..', '..', 'chatham', 'eval', 'results.json');
const OLD_SET = ['academic', 'journalist', 'medical', 'ngo', 'startup', 'thinktank', 'union'];
const MOSAIC_CIRCLES = ['policy', 'bookclub'];
const MOSAIC_SESSIONS = 3;

const ALL = ['L0', 'L1', 'L2', 'L3', 'L4'];
const ABLATION = [
  // Floor: attacker sees ONLY roster + the gold idea texts (no digest).
  { name: 'ideas-only', layers: null, empty: true },
  { name: 'raw', layers: [] },
  { name: 'L0+L1', layers: ['L0', 'L1'] },
  { name: '+L2', layers: ['L0', 'L1', 'L2'] },
  { name: '+L3', layers: ['L0', 'L1', 'L2', 'L3'] },
  { name: '+L4', layers: [...ALL] },
];
const KNOWLEDGE_CONFIGS = new Set(['ideas-only', 'raw', '+L3', '+L4']);
export const TARGETS = [
  { key: 'publicFactRetention', label: 'publicFactRetention ≥ 90%', ok: (v) => v != null && v >= 0.9, fmt: 'pct' },
  { key: 'toneLeak', label: 'toneLeak ≤ 10%', ok: (v) => v != null && v <= 0.1, fmt: 'pct' },
  { key: 'stancePreserved', label: 'stancePreserved ≥ 85%', ok: (v) => v != null && v >= 0.85, fmt: 'pct' },
  { key: 'selfAuthorLeak', label: 'selfAuthorLeak = 0 (works + publicName)', ok: (v) => v === 0, fmt: 'int' },
  { key: 'directLeak', label: 'directLeak ≈ 0 (≤ 1%)', ok: (v) => v != null && v <= 0.01, fmt: 'pct' },
  { key: 'affilLeak', label: 'affilLeak ≈ 0 (≤ 1%)', ok: (v) => v != null && v <= 0.01, fmt: 'pct' },
  { key: 'outsiderNamed', label: 'outsider names 0 roster members', ok: (v) => v === 0, fmt: 'int' },
  { key: 'retention', label: 'idea retention ≥ 85%', ok: (v) => v != null && v >= 0.85, fmt: 'pct' },
];

export function parseArgs(argv) {
  const a = { mock: false, layers: null, ablation: false, configs: null, only: null, threshold: 0.5, flagThreshold: 0.7, attackSamples: 1, concurrency: 4, mosaic: false, out: null };
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
    else if (key === '--mosaic') a.mosaic = true;
    else if (key === '--layers') a.layers = val().split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
    else if (key === '--configs') a.configs = val().split(',').map((s) => s.trim()).filter(Boolean);
    else if (key === '--only') a.only = val().split(',').map((s) => s.trim()).filter(Boolean);
    else if (key === '--threshold') a.threshold = Number(val());
    else if (key === '--flag-threshold') a.flagThreshold = Number(val());
    else if (key === '--attack-samples') a.attackSamples = Math.max(1, parseInt(val(), 10) || 1);
    else if (key === '--concurrency') a.concurrency = Math.max(1, parseInt(val(), 10) || 4);
    else if (key === '--out') a.out = val().replace(/\.(md|json)$/i, '');
    else if (key === '-h' || key === '--help') { a.help = true; }
    else throw new Error(`unknown argument: ${k}`);
  }
  if (a.layers) {
    const bad = a.layers.filter((l) => !ALL.includes(l) && l !== 'RAW');
    if (bad.length) throw new Error(`unknown layer(s): ${bad.join(',')}`);
    if (a.layers.includes('RAW')) a.layers = [];
  }
  if (a.configs) {
    const names = new Set(ABLATION.map((c) => c.name));
    const bad = a.configs.filter((c) => !names.has(c));
    if (bad.length) throw new Error(`unknown config(s): ${bad.join(',')} (known: ${[...names].join(',')})`);
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
    t.gold ??= {};
    for (const k of ['identifiers', 'ideas', 'publicFacts', 'toneMarkers', 'selfAuthor']) t.gold[k] ??= [];
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

const gateOpts = (layers, opts) => ({ llm: opts.llm, layers, mock: !opts.llm, threshold: opts.threshold, flagThreshold: opts.flagThreshold });

async function evalOne(runGate, t, cfg, opts) {
  const row = { transcript: t.id, config: cfg.name, layers: cfg.layers };
  let gate;
  const t0 = performance.now();
  try {
    gate = cfg.empty
      ? { digest: '(no digest available)', claims: [], meta: { promptTokens: 0, completionTokens: 0, ms: 0 } }
      : await runGate(t, gateOpts(cfg.layers, opts));
  } catch (e) {
    return { ...row, error: `runGate: ${e?.message || e}` };
  }
  row.ms = Math.round(performance.now() - t0);
  row.gateMetaMs = gate?.meta?.ms;
  row.digest = String(gate?.digest ?? '');
  row.digestStrict = gate?.digestStrict;
  row.claims = gate?.claims;
  row.meta = gate?.meta;
  row.promptTokens = gate?.meta?.promptTokens || 0;
  row.completionTokens = gate?.meta?.completionTokens || 0;
  const claims = Array.isArray(gate?.claims) ? gate.claims : [];
  row.claimFlags = {
    publicFact: claims.filter((c) => (c.flags || []).includes('public-fact')).length,
    toneNeutralised: claims.filter((c) => (c.flags || []).includes('tone-neutralised')).length,
    roleRevealing: claims.filter((c) => c.risk || (c.flags || []).includes('role-revealing')).length,
  };

  row.leaks = computeLeaks(row.digest, t);

  const ideas = t.gold.ideas;
  const N = t.roster.length || 1;
  row.evalUsage = { promptTokens: 0, completionTokens: 0 };
  const addUsage = (u) => { row.evalUsage.promptTokens += u?.prompt_tokens || 0; row.evalUsage.completionTokens += u?.completion_tokens || 0; };

  // ---- Gate v2 metrics (skipped for the no-digest floor)
  if (!cfg.empty) {
    if (t.gold.publicFacts.length) row.publicFacts = publicFactRetention(row.digest, t.gold.publicFacts);
    if (t.gold.selfAuthor.length || t.roster.some((p) => p.works?.length || p.publicName)) row.selfAuthor = selfAuthorLeaks(row.digest, t);
    if (t.gold.toneMarkers.length) {
      try {
        let judged;
        if (opts.llm) { const r = await llmTone(row.digest, t.gold.toneMarkers); addUsage(r.usage); judged = r.results; }
        else judged = mockTone(row.digest, t.gold.toneMarkers);
        row.tone = scoreTone(row.digest, t.gold.toneMarkers, judged);
        row.tone.judged = judged;
      } catch (e) { row.tone = { error: String(e?.message || e) }; }
    }
  }

  // attribution attack (averaged over samples)
  try {
    const samples = [];
    const nS = opts.llm ? opts.attackSamples : 1;
    for (let s = 0; s < nS; s++) {
      if (opts.llm) { const r = await llmAttack(t.roster, row.digest, ideas, { sample: s }); addUsage(r.usage); samples.push(r.guesses); }
      else samples.push(mockAttack(t.roster, row.digest, ideas));
    }
    const accs = samples.map((g) => attackAccuracy(g, ideas));
    const correct = accs.reduce((a, x) => a + x.correct, 0) / samples.length;
    row.attack = { correct, total: ideas.length, acc: ideas.length ? correct / ideas.length : null, baselineSum: ideas.length / N, baseline: 1 / N, samples: samples.length, guesses: samples };
  } catch (e) {
    row.attack = { correct: 0, total: 0, acc: null, baselineSum: 0, error: String(e?.message || e) };
  }

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
  if (gate?.digestStrict && gate?.meta?.flagged && opts.llm) {
    try {
      const g = await llmAttack(t.roster, gate.digestStrict, ideas, {}); addUsage(g.usage);
      const r = await llmRetention(gate.digestStrict, ideas); addUsage(r.usage);
      row.strict = { attack: attackAccuracy(g.guesses, ideas), retention: retentionMean(r.scores) };
    } catch (e) { row.strict = { error: String(e?.message || e) }; }
  }
  row.flagged = gate?.meta?.flagged || 0;
  row.claimCount = claims.length;

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

// ---------------------------------------------------------------- Gate v2 aggregation
export function aggregateV2(rows) {
  const ok = rows.filter((r) => !r.error);
  const S = (f) => ok.reduce((a, r) => a + (f(r) || 0), 0);
  const pf = ok.filter((r) => r.publicFacts);
  const sa = ok.filter((r) => r.selfAuthor);
  const tn = ok.filter((r) => r.tone && !r.tone.error);
  const pfT = S((r) => r.publicFacts?.total);
  const tP = tn.reduce((a, r) => a + r.tone.present, 0);
  const tT = tn.reduce((a, r) => a + r.tone.total, 0);
  const o = ok.filter((r) => r.outsider && !r.outsider.error);
  return {
    publicFactKept: S((r) => r.publicFacts?.kept), publicFactTotal: pfT,
    publicFactRetention: pf.length && pfT ? S((r) => r.publicFacts?.kept) / pfT : null,
    selfAuthorWorks: sa.length ? S((r) => r.selfAuthor?.works) : null,
    selfAuthorWorksTotal: S((r) => r.selfAuthor?.worksTotal),
    publicNameLeak: sa.length ? S((r) => r.selfAuthor?.publicNames) : null,
    publicNameTotal: S((r) => r.selfAuthor?.publicNamesTotal),
    selfAuthorLeak: sa.length ? S((r) => r.selfAuthor?.works) + S((r) => r.selfAuthor?.publicNames) : null,
    toneLeaks: tn.reduce((a, r) => a + r.tone.leaks, 0), tonePresent: tP, toneTotal: tT,
    toneLeak: tP ? tn.reduce((a, r) => a + r.tone.leaks, 0) / tP : null,
    stancePreservedN: tn.reduce((a, r) => a + r.tone.preserved, 0),
    stancePreserved: tT ? tn.reduce((a, r) => a + r.tone.preserved, 0) / tT : null,
    outsiderNamed: o.length ? S((r) => r.outsider?.exposed) : null, outsiderN: S((r) => r.outsider?.n),
    publicFactFlags: S((r) => r.claimFlags?.publicFact), toneFlags: S((r) => r.claimFlags?.toneNeutralised), claims: S((r) => r.claimCount),
    evalPromptTokens: S((r) => r.evalUsage?.promptTokens), evalCompletionTokens: S((r) => r.evalUsage?.completionTokens),
  };
}

// ---------------------------------------------------------------- mosaic check
async function mosaicEval(runGate, transcripts, opts, log) {
  const out = { circles: [], memory: null, note: '' };
  const circles = transcripts.filter((t) => MOSAIC_CIRCLES.includes(t.id));
  if (!circles.length) { out.note = `mosaic circles ${MOSAIC_CIRCLES.join(',')} not in the loaded transcripts`; return out; }
  let memMod = null;
  try { memMod = await import(pathToFileURL(MEMORY_MODULE).href); if (typeof memMod.createMemory !== 'function') { memMod = null; out.memoryNote = 'core/memory.mjs has no createMemory'; } }
  catch (e) { out.memoryNote = `core/memory.mjs unavailable: ${String(e?.message || e).slice(0, 200)}`; }
  const usage = { promptTokens: 0, completionTokens: 0, gatePromptTokens: 0, gateCompletionTokens: 0 };
  const addU = (u) => { usage.promptTokens += u?.prompt_tokens || 0; usage.completionTokens += u?.completion_tokens || 0; };
  const attack = async (roster, digest, ideas) => {
    if (!ideas.length) return { correct: 0, total: 0 };
    const nS = opts.llm ? opts.attackSamples : 1;
    let c = 0;
    for (let s = 0; s < nS; s++) {
      const g = opts.llm ? await llmAttack(roster, digest, ideas, { sample: s }) : { guesses: mockAttack(roster, digest, ideas) };
      addU(g.usage);
      c += attackAccuracy(g.guesses, ideas).correct;
    }
    return { correct: c / nS, total: ideas.length };
  };
  const outsider = async (roster, digest, ideas) => {
    const o = opts.llm ? await llmOutsider(digest, ideas) : mockOutsider(roster, digest);
    addU(o.usage);
    return scoreOutsider(roster, ideas, o);
  };

  for (const t of circles) {
    log(`  mosaic: ${t.id} → ${MOSAIC_SESSIONS} sessions`);
    const sessions = splitSessions(t, MOSAIC_SESSIONS);
    const circle = { circle: t.id, sessions: [], memory: null };
    const digests = [];
    for (const s of sessions) {
      const sub = { ...t, id: `${t.id}#s${s.idx + 1}`, lines: s.lines, gold: { ...t.gold, ideas: s.ideas } };
      try {
        const g = await runGate(sub, gateOpts([...ALL], opts));
        usage.gatePromptTokens += g?.meta?.promptTokens || 0; usage.gateCompletionTokens += g?.meta?.completionTokens || 0;
        const digest = String(g?.digest ?? '');
        digests.push(digest);
        const aAlone = await attack(t.roster, digest, s.ideas);
        circle.sessions.push({ session: s.idx + 1, lines: s.lines.length, ideas: s.ideas.length, claims: (g?.claims || []).length, alone: aAlone, claimsList: (g?.claims || []).map((c) => ({ text: c.text, kind: c.kind })) });
      } catch (e) {
        circle.sessions.push({ session: s.idx + 1, error: `runGate: ${e?.message || e}` });
      }
    }
    const okS = circle.sessions.filter((s) => !s.error);
    circle.aloneCorrect = okS.reduce((a, s) => a + s.alone.correct, 0);
    circle.aloneTotal = okS.reduce((a, s) => a + s.alone.total, 0);
    const okIdeas = sessions.filter((s, i) => !circle.sessions[i]?.error).flatMap((s) => s.ideas);
    if (digests.length) {
      const combined = digests.join('\n\n---\n\n');
      try {
        const c = await attack(t.roster, combined, okIdeas);
        circle.combinedCorrect = c.correct; circle.combinedTotal = c.total;
        const oA = [];
        for (const [i, d] of digests.entries()) oA.push(await outsider(t.roster, d, okS[i] ? sessions[okS[i].session - 1].ideas : []));
        circle.outsiderAloneMaxNamed = Math.max(0, ...oA.map((o) => o.exposed));
        circle.outsiderCombinedNamed = (await outsider(t.roster, combined, okIdeas)).exposed;
      } catch (e) { circle.combinedError = String(e?.message || e); }
    }
    // knowledge-store mosaic check (core/memory.mjs, if available)
    if (memMod) {
      try {
        const mem = memMod.createMemory({ circleId: `eval-${t.id}`, roster: t.roster, llm: opts.llm || null });
        let n = 0;
        okS.forEach((s) => { const added = mem.addRelease({ sid: `${t.id}-s${s.session}`, draftId: `d${s.session}`, approvals: 3, k: 3, items: s.claimsList }); n += added.length; });
        const queries = [t.title, ...okIdeas.map((i) => i.text)].filter(Boolean);
        const keptIds = new Map();
        let cand = 0, dropped = 0;
        for (const q of queries) {
          const items = await mem.recallForOutput(q, { limit: 5 });
          const fl = Array.isArray(items.flags) ? items.flags : [];
          cand += items.length + fl.length; dropped += fl.length;
          for (const it of items) keptIds.set(it.id, it.text);
        }
        const memDigest = [...keptIds.values()].map((x) => `- ${x}`).join('\n');
        const am = memDigest ? await attack(t.roster, memDigest, okIdeas) : { correct: 0, total: okIdeas.length };
        circle.memory = { stored: n, queries: queries.length, candidates: cand, dropped, keptUnique: keptIds.size, attackCorrect: am.correct, attackTotal: am.total };
      } catch (e) { circle.memory = { error: String(e?.message || e).slice(0, 300) }; }
    }
    for (const s of circle.sessions) delete s.claimsList;
    out.circles.push(circle);
  }
  out.usage = usage;
  return out;
}

// ---------------------------------------------------------------- formatting
const pct = (x) => (x == null ? '—' : (x * 100).toFixed(1));
const num = (x, d = 0) => (x == null ? '—' : Number(x).toFixed(d));
const frac = (a, b) => (b ? `${pct(a / b)} (${Number.isInteger(a) ? a : a.toFixed(1)}/${b})` : '—');
const COLS = ['config', 'directLeak%', 'affilLeak%', 'quasiLeak%', 'styleLeak%', 'attackAcc%', 'randomBaseline%', 'retention%', 'avgLatencyMs', 'tokens', 'est$'];
const V2COLS = ['config', 'publicFactRetention%', 'selfAuthorLeak (works)', 'publicNameLeak', 'toneLeak%', 'stancePreserved%', 'directLeak%', 'affilLeak%', 'attackAcc%', 'retention%', 'flags public-fact / tone'];

function aggCells(name, a) {
  return [name, pct(a.directLeak), pct(a.affilLeak), pct(a.quasiLeak), pct(a.styleLeak), pct(a.attackAcc), pct(a.randomBaseline), pct(a.retention), num(a.avgLatencyMs), String(a.tokens), a.usd.toFixed(5)];
}
function v2Cells(name, a, v) {
  return [name, frac(v.publicFactKept, v.publicFactTotal), v.selfAuthorWorks == null ? '—' : `${v.selfAuthorWorks}/${v.selfAuthorWorksTotal}`,
    v.publicNameLeak == null ? '—' : `${v.publicNameLeak}/${v.publicNameTotal}`,
    frac(v.toneLeaks, v.tonePresent), frac(v.stancePreservedN, v.toneTotal), pct(a.directLeak), pct(a.affilLeak), pct(a.attackAcc), pct(a.retention), `${v.publicFactFlags} / ${v.toneFlags} of ${v.claims}`];
}
function rowCells(r) {
  if (r.error) return [r.transcript, r.config, 'ERROR', '', '', '', '', '', '', '', '', ''];
  const lr = (c) => { const b = r.leaks.by[c]; return b.total ? `${pct(b.leaked / b.total)} (${b.leaked}/${b.total})` : '—'; };
  return [r.transcript, r.config, lr('direct'), lr('affil'), lr('quasi'), lr('style'), pct(r.attack?.acc), pct(r.attack?.baseline), pct(r.retention?.mean), num(r.ms), String(r.promptTokens + r.completionTokens), (((r.promptTokens * PRICE.inputPerM) + (r.completionTokens * PRICE.outputPerM)) / 1e6).toFixed(5)];
}
function v2RowCells(r) {
  if (r.error) return [r.transcript, r.config, 'ERROR', '', '', '', ''];
  const t = r.tone && !r.tone.error ? r.tone : null;
  return [r.transcript, r.config,
    r.publicFacts ? frac(r.publicFacts.kept, r.publicFacts.total) : '—',
    r.selfAuthor ? `${r.selfAuthor.works}/${r.selfAuthor.worksTotal} + ${r.selfAuthor.publicNames}/${r.selfAuthor.publicNamesTotal}` : '—',
    t ? frac(t.leaks, t.present) : (r.tone?.error ? 'ERROR' : '—'),
    t ? frac(t.preserved, t.total) : '—',
    `${r.claimFlags?.publicFact ?? 0} / ${r.claimFlags?.toneNeutralised ?? 0} of ${r.claimCount}`];
}
const KCOLS = ['config', '(a) fullRoster attack%', '(b) namesOnly attack%', '(c) outsider: roster members named', '(c) outsider: speaker hit%', 'random%'];
const FCOLS = ['transcript', 'flagged/claims', 'dropped', 'strict attack%', 'strict retention%'];
const ROW_COLS = ['transcript', 'config', 'directLeak%', 'affilLeak%', 'quasiLeak%', 'styleLeak%', 'attackAcc%', 'randomBaseline%', 'retention%', 'latencyMs', 'tokens', 'est$'];
const V2ROW_COLS = ['transcript', 'config', 'publicFactRetention', 'selfAuthor works + publicName', 'toneLeak', 'stancePreserved', 'flags public-fact / tone'];

const width = (s) => [...String(s)].reduce((w, ch) => w + (/[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(ch) ? 2 : 1), 0);
function textTable(head, rows) {
  const w = head.map((h, i) => Math.max(width(h), ...rows.map((r) => width(r[i] ?? ''))));
  const line = (r) => r.map((c, i) => String(c ?? '') + ' '.repeat(Math.max(0, w[i] - width(c ?? '')))).join('  ');
  return [line(head), w.map((n) => '-'.repeat(n)).join('  '), ...rows.map(line)].join('\n');
}
function mdTable(head, rows) {
  const esc = (c) => String(c ?? '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
  return [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...rows.map((r) => `| ${r.map(esc).join(' | ')} |`)].join('\n');
}

function knowledgeRows(configs, allRows) {
  const P = (a, b) => (b ? pct(a / b) : '—');
  const S = (rows, f) => rows.reduce((x, r) => x + (f(r) || 0), 0);
  return configs.filter((c) => KNOWLEDGE_CONFIGS.has(c.name)).map((c) => {
    const rs = allRows.filter((r) => r.config === c.name && !r.error);
    const o = rs.filter((r) => r.outsider && !r.outsider.error);
    return [c.name,
      P(S(rs, (r) => r.attack?.correct), S(rs, (r) => r.attack?.total)),
      P(S(rs, (r) => r.attackNames?.correct), S(rs, (r) => r.attackNames?.total)),
      c.empty ? '—' : `${S(o, (r) => r.outsider.exposed)}/${S(o, (r) => r.outsider.n)} (${S(o, (r) => r.outsider.people)} by name, ${S(o, (r) => r.outsider.orgs)} by org)`,
      c.empty ? '—' : P(S(o, (r) => r.outsider.speakerHits), S(o, (r) => r.outsider.ideas)),
      P(S(rs, (r) => r.attack?.baselineSum), S(rs, (r) => r.attack?.total))];
  });
}

async function loadPrototype() {
  try { return JSON.parse(await readFile(PROTO_RESULTS, 'utf8')); } catch { return null; }
}

// ---------------------------------------------------------------- main
async function main() {
  const t0all = performance.now();
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('usage: node server/anonym-agent/eval/run.mjs [--mock] [--layers L0,L1,L2,L3,L4] [--ablation] [--configs +L3,+L4] [--only id1,id2] [--threshold 0.5] [--flag-threshold 0.7] [--attack-samples 1] [--concurrency 4] [--mosaic] [--out results]');
    return;
  }
  const keyPresent = hasKey();
  const useLLM = keyPresent && !args.mock;
  let llm = null;
  if (useLLM) {
    const { createDeepSeekLLM } = await import(pathToFileURL(LLM_MODULE).href);
    llm = createDeepSeekLLM({ baseUrl: LLM_BASE_URL, key: process.env.LARES_AI_LLM_KEY, model: LLM_MODEL });
  }
  const modeLabel = useLLM ? `LLM (gate + judge model: ${LLM_MODEL})` : 'MOCK — offline heuristics, NOT LLM numbers';
  const outBase = args.out || (useLLM ? 'results' : 'results-mock');

  let runGate;
  try { ({ runGate } = await import(pathToFileURL(path.resolve(GATE_MODULE)).href)); }
  catch (e) { throw new Error(`cannot import core/gate/gate.mjs: ${e?.message || e}`); }
  if (typeof runGate !== 'function') throw new Error('core/gate/gate.mjs does not export runGate');

  const transcripts = await loadTranscripts(args.only);
  let configs = args.layers && !args.ablation && !args.configs
    ? [{ name: args.layers.length ? args.layers.join('+') : 'raw', layers: args.layers }]
    : ABLATION;
  if (args.configs) configs = ABLATION.filter((c) => args.configs.includes(c.name));

  console.log(`Anonym Gate v2 eval — ${new Date().toISOString()}`);
  console.log(`mode: ${modeLabel}; transcripts: ${transcripts.map((t) => t.id).join(', ')}; configs: ${configs.map((c) => c.name).join(', ')}; threshold=${args.threshold}; flagThreshold=${args.flagThreshold}; attack samples=${useLLM ? args.attackSamples : 1}; mosaic=${args.mosaic}`);
  if (!keyPresent && !args.mock) console.log('(LARES_AI_LLM_KEY not set → falling back to mock mode)');

  const opts = { llm, threshold: args.threshold, flagThreshold: args.flagThreshold, attackSamples: args.attackSamples };
  const allRows = [];
  const aggs = [];
  for (const cfg of configs) {
    const tc = performance.now();
    const rows = await pool(transcripts, args.concurrency, (t) => evalOne(runGate, t, cfg, opts));
    for (const r of rows) if (r.error) console.error(`  [${cfg.name}] ${r.transcript}: ${r.error}`);
    console.log(`  config ${cfg.name} done in ${((performance.now() - tc) / 1000).toFixed(1)}s`);
    allRows.push(...rows);
    aggs.push({ config: cfg.name, layers: cfg.layers, ...aggregate(rows, PRICE), v2: aggregateV2(rows) });
  }

  let mosaic = null;
  if (args.mosaic) {
    try { mosaic = await mosaicEval(runGate, transcripts, opts, (m) => console.log(m)); }
    catch (e) { mosaic = { error: String(e?.message || e) }; }
  }

  const v2Table = aggs.map((a) => v2Cells(a.config, a, a.v2));
  const aggTable = aggs.map((a) => aggCells(a.config, a));
  const kTable = knowledgeRows(configs, allRows);
  const P = (a, b) => (b ? pct(a / b) : '—');
  const S = (rows, f) => rows.reduce((x, r) => x + (f(r) || 0), 0);
  const fTable = configs.filter((c) => c.name === '+L4').flatMap((c) => {
    const rs = allRows.filter((r) => r.config === c.name && !r.error);
    const st = rs.filter((r) => r.strict && !r.strict.error);
    const per = rs.map((r) => [r.transcript, `${r.flagged}/${r.claimCount}`, String(r.meta?.dropped ?? 0), r.strict?.attack ? pct(r.strict.attack.acc) : '—', r.strict?.retention != null ? pct(r.strict.retention) : '—']);
    const sA = S(st, (r) => r.strict.attack.correct), sT = S(st, (r) => r.strict.attack.total);
    return [...per, ['ALL', `${S(rs, (r) => r.flagged)}/${S(rs, (r) => r.claimCount)}`, String(S(rs, (r) => r.meta?.dropped)), P(sA, sT), st.length ? pct(S(st, (r) => r.strict.retention) / st.length) : '—']];
  });
  const perRows = transcripts.flatMap((t) => allRows.filter((r) => r.transcript === t.id)).map(rowCells);
  const v2Datasets = transcripts.filter((t) => t.gold.publicFacts.length || t.gold.toneMarkers.length || t.gold.selfAuthor.length).map((t) => t.id);
  const v2PerRows = v2Datasets.flatMap((id) => allRows.filter((r) => r.transcript === id && !ABLATION.find((c) => c.name === r.config)?.empty)).map(v2RowCells);

  // targets: evaluated on the most complete Gate config run (+L4, else the last config)
  const tgtAgg = aggs.find((a) => a.config === '+L4') || aggs[aggs.length - 1];
  const tgtVals = tgtAgg ? { ...tgtAgg.v2, directLeak: tgtAgg.directLeak, affilLeak: tgtAgg.affilLeak, retention: tgtAgg.retention } : {};
  const tgtRows = TARGETS.map((t) => {
    const v = tgtVals[t.key];
    return [t.label, v == null ? '—' : t.fmt === 'pct' ? `${pct(v)}%` : String(v), v == null ? 'n/a' : t.ok(v) ? '✅' : '❌'];
  });

  // prototype comparison (same 7 old transcripts)
  const proto = await loadPrototype();
  let cmpRows = [];
  if (proto) {
    const pAgg = new Map(proto.configs.map((c) => [c.config, c]));
    const pOut = (name) => { const o = proto.rows.filter((r) => r.config === name && r.outsider && !r.outsider.error); return o.length ? `${S(o, (r) => r.outsider.exposed)}/${S(o, (r) => r.outsider.n)}` : '—'; };
    const pNames = (name) => { const o = proto.rows.filter((r) => r.config === name && r.attackNames); return o.length ? pct(S(o, (r) => r.attackNames.correct) / S(o, (r) => r.attackNames.total)) : '—'; };
    for (const c of configs) {
      const old = allRows.filter((r) => r.config === c.name && OLD_SET.includes(r.transcript));
      if (!old.length) continue;
      const a = aggregate(old, PRICE);
      const p = pAgg.get(c.name);
      const o = old.filter((r) => r.outsider && !r.outsider.error);
      const nm = old.filter((r) => r.attackNames && !r.attackNames.error);
      const pair = (x, y) => `${pct(x)} → ${pct(y)}`;
      cmpRows.push([c.name, `${old.length}/7`, pair(p?.directLeak, a.directLeak), pair(p?.affilLeak, a.affilLeak), pair(p?.quasiLeak, a.quasiLeak), pair(p?.styleLeak, a.styleLeak),
        pair(p?.attackAcc, a.attackAcc), KNOWLEDGE_CONFIGS.has(c.name) ? `${pNames(c.name)} → ${nm.length ? pct(S(nm, (r) => r.attackNames.correct) / S(nm, (r) => r.attackNames.total)) : '—'}` : '—',
        KNOWLEDGE_CONFIGS.has(c.name) && !c.empty ? `${pOut(c.name)} → ${o.length ? `${S(o, (r) => r.outsider.exposed)}/${S(o, (r) => r.outsider.n)}` : '—'}` : '—',
        pair(p?.retention, a.retention), `${p ? p.usd.toFixed(4) : '—'} → ${a.usd.toFixed(4)}`]);
    }
  }
  const CMP_COLS = ['config', 'old transcripts', 'directLeak% proto→v2', 'affilLeak%', 'quasiLeak%', 'styleLeak%', 'fullRoster attack%', 'namesOnly attack%', 'outsider named', 'retention%', 'gate est$ (total)'];

  // mosaic table
  const mRows = (mosaic?.circles || []).map((c) => [c.circle, String(c.sessions.length), c.sessions.map((s) => s.error ? 'ERR' : `${s.ideas}i/${s.claims}c`).join(', '),
    frac(c.aloneCorrect, c.aloneTotal), c.combinedTotal ? frac(c.combinedCorrect, c.combinedTotal) : (c.combinedError ? 'ERROR' : '—'),
    c.combinedTotal && c.aloneTotal ? `${((c.combinedCorrect / c.combinedTotal - c.aloneCorrect / c.aloneTotal) * 100).toFixed(1)} pts` : '—',
    c.outsiderAloneMaxNamed == null ? '—' : `${c.outsiderAloneMaxNamed} → ${c.outsiderCombinedNamed}`,
    c.memory ? (c.memory.error ? `ERROR: ${c.memory.error.slice(0, 80)}` : `${c.memory.dropped}/${c.memory.candidates} dropped; ${c.memory.keptUnique}/${c.memory.stored} unique items out; attack ${frac(c.memory.attackCorrect, c.memory.attackTotal)}`) : `skipped (${mosaic?.memoryNote || 'n/a'})`]);
  const M_COLS = ['circle', 'sessions', 'ideas/claims per session', 'attack: each digest alone', 'attack: all digests combined', 'mosaic gain', 'outsider named: max alone → combined', 'memory recallForOutput'];

  const totalEval = { p: S(allRows, (r) => r.evalUsage?.promptTokens) + (mosaic?.usage?.promptTokens || 0), c: S(allRows, (r) => r.evalUsage?.completionTokens) + (mosaic?.usage?.completionTokens || 0) };
  const totalGate = { p: S(allRows, (r) => r.promptTokens) + (mosaic?.usage?.gatePromptTokens || 0), c: S(allRows, (r) => r.completionTokens) + (mosaic?.usage?.gateCompletionTokens || 0) };
  const usd = (x) => ((x.p * PRICE.inputPerM + x.c * PRICE.outputPerM) / 1e6);
  const wallS = (performance.now() - t0all) / 1000;
  const costLine = `wall ${wallS.toFixed(0)}s; gate tokens ${totalGate.p + totalGate.c} (≈$${usd(totalGate).toFixed(4)}); judge/attacker tokens ${totalEval.p + totalEval.c} (≈$${usd(totalEval).toFixed(4)}); ${PRICE.note}`;

  console.log('\nGate v2 metrics (pooled)' + (useLLM ? '' : ' [MOCK]'));
  console.log(textTable(V2COLS, v2Table));
  console.log('\nTargets (config ' + (tgtAgg?.config ?? '—') + ')');
  console.log(textTable(['target', 'value', 'met'], tgtRows));
  console.log('\nAggregate (pooled over transcripts)' + (useLLM ? '' : ' [MOCK: attack/retention are heuristic, not LLM]'));
  console.log(textTable(COLS, aggTable));
  console.log('\nAttacker knowledge levels');
  console.log(textTable(KCOLS, kTable));
  if (fTable.length) { console.log('\nRole-revealing risk flags (L4 residual)'); console.log(textTable(FCOLS, fTable)); }
  if (v2PerRows.length) { console.log('\nGate v2 per transcript'); console.log(textTable(V2ROW_COLS, v2PerRows)); }
  console.log('\nPer transcript');
  console.log(textTable(ROW_COLS, perRows));
  if (cmpRows.length) { console.log('\nPrototype → Gate v2 (old 7 transcripts)'); console.log(textTable(CMP_COLS, cmpRows)); }
  if (mosaic) { console.log('\nMosaic'); console.log(mosaic.error ? `ERROR: ${mosaic.error}` : textTable(M_COLS, mRows)); if (mosaic.note) console.log(mosaic.note); }
  console.log(`\n${costLine}`);

  // ---------- results.md
  const ts = new Date().toISOString();
  const md = [];
  md.push('# Anonym Gate v2 — evaluation results', '');
  md.push(`- Run: ${ts}`);
  md.push(`- Mode: ${modeLabel}`);
  md.push(`- Configs: ${configs.map((c) => c.name).join(', ')}; threshold=${args.threshold}; flagThreshold=${args.flagThreshold}; attack samples=${useLLM ? args.attackSamples : 1}; mosaic=${args.mosaic}`);
  md.push(`- Transcripts: ${transcripts.map((t) => `${t.id} (${t.roster.length} speakers, ${t.gold.ideas.length} ideas, ${t.gold.identifiers.length} identifiers${t.gold.publicFacts.length ? `, ${t.gold.publicFacts.length} public facts, ${t.gold.toneMarkers.length} tone markers, ${t.gold.selfAuthor.length} self-authored works` : ''})`).join('; ')}`);
  md.push(`- Runtime / cost: ${costLine} — prices are an **assumption**.`);
  md.push('- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.');
  if (!useLLM) md.push('- **MOCK numbers**: gate L3/L4, attacker, tone and retention judges are deterministic heuristics, not an LLM. Do not quote as LLM results.');
  md.push('', '## Gate v2 metrics', '',
    'New in Gate v2 (only the bookclub / policy / faculty transcripts carry this gold):',
    '- **publicFactRetention** = public-world facts whose every `keep` string appears in the digest (normalised, case-insensitive, 《》/quotes stripped).',
    '- **selfAuthorLeak** = participant-authored works (`gold.selfAuthor` work/fuzzy ∪ `roster[].works`) found in the digest; **publicNameLeak** = roster `publicName` found. Both must be 0.',
    '- **toneLeak** = markers whose claim is present and the LLM judge still finds sarcasm / irony / backhanded praise / catchphrase / dialect / idiolect, OR any marker surface string appears verbatim (deterministic, OR\'d) ÷ markers whose claim is present.',
    '- **stancePreserved** = markers whose judged digest stance has the gold direction and |strength diff| ≤ 1 ÷ all markers (absent = not preserved).',
    '', mdTable(V2COLS, v2Table), '');
  md.push(`## Targets (config ${tgtAgg?.config ?? '—'}, pooled over the transcripts run)`, '', mdTable(['target', 'value', 'met'], tgtRows), '');
  md.push('## Aggregate (all metrics from the prototype)', '', mdTable(COLS, aggTable), '');
  md.push('## Attacker knowledge levels', '', '(a) full roster incl. org/title/works (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.', '', mdTable(KCOLS, kTable), '');
  if (fTable.length) md.push('## Role-revealing risk flags (L4 residual)', '', '"strict" = the digest with all flagged claims cut (full-roster attacker).', '', mdTable(FCOLS, fTable), '');
  if (cmpRows.length) md.push('## Prototype → Gate v2 (same 7 old transcripts)', '', `Prototype numbers from \`server/chatham/eval/results.json\` (${proto?.timestamp ?? '?'}, ${proto?.mode ?? '?'}). Gate v2 numbers restricted to the same 7 transcripts. Format: prototype → v2.`, '', mdTable(CMP_COLS, cmpRows), '');
  if (mosaic) {
    md.push('## Mosaic (cross-session linkage)', '',
      `For each circle the transcript is split into ${MOSAIC_SESSIONS} consecutive sessions (thirds of the lines; each gold idea assigned to the session whose raw text matches it best). The full Gate (+L4) runs per session. The full-roster attacker gets (a) each session digest alone, asked only about that session's ideas, and (b) all session digests concatenated, asked about all ideas. Mosaic gain = combined − alone. The knowledge store (core/memory.mjs) receives every session's claims as releases; recallForOutput is queried with the circle title and every gold idea (limit 5) and the union of returned items is attacked again.`, '');
    md.push(mosaic.error ? `ERROR: ${mosaic.error}` : mdTable(M_COLS, mRows), '');
    if (mosaic.note) md.push(`_${mosaic.note}_`, '');
    if (mosaic.memoryNote) md.push(`_memory: ${mosaic.memoryNote}_`, '');
  }
  if (v2PerRows.length) md.push('## Gate v2 per transcript', '', mdTable(V2ROW_COLS, v2PerRows), '');
  // details: missed public facts (public → not redacted), self-author leaks (redacted), tone items
  const det = [];
  for (const r of allRows.filter((x) => !x.error && v2Datasets.includes(x.transcript) && ['+L3', '+L4'].includes(x.config))) {
    for (const f of r.publicFacts?.items || []) if (!f.kept) det.push([r.transcript, r.config, 'publicFact missed', f.id, `missing: ${f.missing.join(', ')}`]);
    for (const s of r.selfAuthor?.items || []) if (s.leaked) det.push([r.transcript, r.config, `selfAuthor ${s.type}`, s.owner, redact(s.via)]);
    for (const t of r.tone?.items || []) if (t.leak || !t.preserved) det.push([r.transcript, r.config, t.leak ? 'tone leak' : 'stance', t.id, `present=${t.present} residual=${t.residual}${t.surface.length ? ` surface=${t.surface.map(redact).join(',')}` : ''}; judged ${t.judgedDirection}/${t.judgedStrength ?? '—'} vs gold ${t.gold?.direction}/${t.gold?.strength}`]);
  }
  for (const r of allRows.filter((x) => !x.error && ['+L3', '+L4'].includes(x.config) && x.outsider?.matched?.length)) {
    for (const m of r.outsider.matched) det.push([r.transcript, r.config, `outsider ${m.via} match`, m.id, `guess "${m.via === 'name' ? redact(m.guess) : m.guess}"`]);
  }
  if (det.length) md.push('### Gate v2 misses (+L3/+L4)', '', '_Self-author and surface tone strings redacted to 2 chars; public-fact keep strings are public and shown._', '', mdTable(['transcript', 'config', 'type', 'id', 'detail'], det), '');
  md.push('## How to read this', '',
    '- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. No de-identification that keeps the idea can push the full-roster attack much below that floor.',
    '- **(a) full roster with org/title** is an insider. **(c) outsider** is the outward threat: the digest must not reveal who attended.',
    '- Gate v2 deliberately keeps public-world facts (named authors, laws, public bodies). The gold `org`/`title` identifiers in all 10 transcripts are participant-owned (owner p1..p5), so affilLeak keeps its meaning: any of them in the digest is a real leak.',
    '- Attacker, gate and judges all use the same model family (deepseek-flash). n is small (10 synthetic transcripts; 15 tone markers, 21 public facts, 3 self-authored works): one marker ≈ 6.7 pts of toneLeak/stancePreserved. Judge noise matters.', '');
  md.push('## Per transcript', '', mdTable(ROW_COLS, perRows), '');
  md.push('## Leaked identifiers per config', '', '_Leaked strings are redacted to their first 2 characters._', '');
  for (const cfg of configs) {
    const rows = allRows.filter((r) => r.config === cfg.name && !r.error);
    const leaked = rows.flatMap((r) => r.leaks.items.filter((i) => i.leaked).map((i) => ({ ...i, transcript: r.transcript })));
    md.push(`### ${cfg.name} (${leaked.length} leaked)`, '');
    if (!leaked.length) { md.push('_none_', ''); continue; }
    md.push(mdTable(['transcript', 'category', 'kind', 'owner', 'identifier'], leaked.map((i) => [i.transcript, i.category, i.kind, i.owner, redact(i.text)])), '');
  }
  const errs = allRows.filter((r) => r.error || r.attack?.error || r.retention?.error || r.tone?.error);
  if (errs.length) {
    md.push('## Errors', '');
    for (const r of errs) md.push(`- ${r.transcript} / ${r.config}: ${r.error || r.attack?.error || r.retention?.error || r.tone?.error}`);
    md.push('');
  }
  await writeFile(path.join(OUT_DIR, `${outBase}.md`), md.join('\n'), 'utf8');
  await writeFile(path.join(OUT_DIR, `${outBase}.json`), JSON.stringify({
    timestamp: ts, mode: useLLM ? 'llm' : 'mock', judgeModel: useLLM ? LLM_MODEL : null, price: PRICE, wallSeconds: Math.round(wallS),
    tokens: { gate: totalGate, eval: totalEval },
    args: { ...args }, configs: aggs, mosaic, rows: allRows,
  }, null, 2), 'utf8');
  console.log(`\nwrote ${path.join(OUT_DIR, `${outBase}.md`)} and ${outBase}.json`);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main().catch((e) => { console.error(`eval failed: ${e?.message || e}`); process.exitCode = 1; });
