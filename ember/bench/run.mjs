#!/usr/bin/env node
// EmberBench CLI.
//   node ember/bench/run.mjs --split dev|test --runs 3 --configs +L4,ideas-only,raw --concurrency 6
//        [--mock] [--gate deepseek:deepseek-flash] [--attacker dashscope:qwen-plus] [--judge dashscope:qwen-plus]
//        [--alt-judge deepseek:deepseek-flash] [--agreement-sample 10] [--only id1,id2] [--seed 12345]
//        [--allow-same-family] [--break-seal "<reason>"] [--seal] [--out ember/bench/results] [--track synthetic|public]
// --track public (METHOD §7): real council transcripts from .data/emberbench-public/data (git-excluded), manifest/seal in
// data/public/, results default to results/public/<run-id>/ with records.jsonl written to .data/ (it carries transcript text).
// --schema v2|v3 (default v2). v3 (METHOD §8, public only): binding-aware T1/T6/T9/T12 + T9b on data/dev (gold.spansV3);
// --split test then means the sealed date-held-out split test-v3 (seal status sealed-unrun → first run allowed, then sealed-run).
// Writes results/<run-id>/{trustcard.md, trustcard.json, records.jsonl}.
import { mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { makeLLM, newMeter, costUSD, loadDashscopeKeyFile, parseSpec } from './providers.mjs';
import { loadSplit, verifyManifest, hashSplit, checkDisjoint, readSeal, writeSeal, circles, TRACKS, V3_TEST_SPLIT, V4_TEST_SPLIT, V5_TEST_SPLIT } from './data.mjs';
import { summariseV5, renderV5, v5Fields, BENCH_VERSION_V5 } from './v4/score-v5.mjs';
import { scoreV4Record, summariseV4, renderV4, fitCalibration, calibDiagnostics, v4RecordFields, runProbe, BENCH_VERSION_V4 } from './v4/score-v4.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { rescoreRecords, summarise, THRESHOLDS_V3, BENCH_VERSION_V3 } from './rescore-v3.mjs';
import { runTask, CONFIGS } from './harness.mjs';
import { aggregate, judgeThresholds, renderCard, extractFailures, BENCH_VERSION } from './trustcard.mjs';
import { judgeRetention } from './attack.mjs';
import { cohensKappa, ideaKeywordRecall } from './metrics.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

export function parseArgs(argv) {
  const a = { track: 'synthetic', schema: 'v2', split: 'dev', runs: 3, configs: ['+L4', 'ideas-only', 'raw'], concurrency: 4, mock: false, seed: 12345, agreementSample: 10, out: path.join(HERE, 'results') };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = () => argv[++i];
    if (k === '--split') a.split = v();
    else if (k === '--track') a.track = v();
    else if (k === '--schema') a.schema = v();
    else if (k === '--runs') a.runs = Number(v());
    else if (k === '--configs') a.configs = v().split(',').map((s) => s.trim()).filter(Boolean);
    else if (k === '--concurrency') a.concurrency = Number(v());
    else if (k === '--mock') a.mock = true;
    else if (k === '--gate') a.gate = v();
    else if (k === '--attacker') a.attacker = v();
    else if (k === '--judge') a.judge = v();
    else if (k === '--alt-judge') a.altJudge = v();
    else if (k === '--agreement-sample') a.agreementSample = Number(v());
    else if (k === '--only') a.only = v().split(',');
    else if (k === '--seed') a.seed = Number(v());
    else if (k === '--allow-same-family') a.allowSameFamily = true;
    else if (k === '--break-seal') a.breakSeal = v();
    else if (k === '--seal') a.seal = true;
    else if (k === '--out') { a.out = v(); a.outSet = true; }
    else if (k === '--strictness') a.strictness = Number(v());
    else if (k === '--attacker2') a.attacker2 = v();
    else if (k === '--aligner') a.aligner = v();
    else if (k === '--no-baseline') a.noBaseline = true;
    else if (k === '--no-probe') a.noProbe = true;
    else throw new Error(`unknown arg ${k}`);
  }
  if (!['dev', 'test'].includes(a.split)) throw new Error('--split must be dev|test');
  if (!TRACKS[a.track]) throw new Error(`--track must be ${Object.keys(TRACKS).join('|')}`);
  if (!['v2', 'v3', 'v4', 'v5'].includes(a.schema)) throw new Error('--schema must be v2|v3|v4|v5');
  if (['v4', 'v5'].includes(a.schema) && a.track !== 'public') throw new Error(`--schema ${a.schema} is defined for --track public only (METHOD §9, §10)`);
  if (a.strictness != null && ![0, 1, 2, 3].includes(a.strictness)) throw new Error('--strictness must be 0|1|2|3');
  if (a.schema === 'v3' && a.track !== 'public') throw new Error('--schema v3 is defined for --track public only (METHOD §8.5: synthetic v3 = v2)');
  if (a.track === 'public' && !a.outSet) a.out = path.join(HERE, 'results', 'public');
  for (const c of a.configs) if (!CONFIGS.includes(c)) throw new Error(`unknown config ${c} (have ${CONFIGS.join(', ')})`);
  if (a.configs.includes('+L4') && !a.configs.includes('ideas-only') && !(['v4', 'v5'].includes(a.schema) && a.noBaseline)) a.configs.push('ideas-only'); // excess needs the baseline
  if (a.mock) { a.gate = 'mock:gate'; a.attacker = 'mock:attacker'; a.judge = 'mock:judge'; a.altJudge = a.altJudge ? 'mock:alt' : null; }
  a.gate ||= `deepseek:${process.env.LARES_AI_LLM_MODEL || 'deepseek-flash'}`;
  a.attacker ||= 'dashscope:qwen-plus';
  a.judge ||= 'dashscope:qwen-plus';
  if (a.altJudge === undefined) a.altJudge = a.mock ? null : 'deepseek:deepseek-flash';
  if (['v4', 'v5'].includes(a.schema)) { a.attacker2 ||= a.mock ? 'mock:attacker2' : 'dashscope:kimi-k3'; a.aligner ||= a.judge; }
  return a;
}

/** Judge independence: attacker & judge must not share the gate's model family. */
export function checkIndependence({ gate, attacker, judge }, allow = false) {
  const g = parseSpec(gate).family;
  const bad = [['attacker', attacker], ['judge', judge]].filter(([, s]) => parseSpec(s).family === g && g !== 'mock');
  if (bad.length && !allow) throw new Error(`${bad.map(([r, s]) => `${r} ${s}`).join(', ')} is the same family as the gate (${gate}); use another family or --allow-same-family`);
  return bad.length === 0;
}

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.max(1, n) }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); } }));
  return out;
}

function git() {
  try {
    const sha = execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();
    const dirty = execFileSync('git', ['status', '--porcelain', '--', 'ember'], { encoding: 'utf8' }).trim().length > 0;
    return { sha, dirty };
  } catch { return { sha: 'unknown', dirty: null }; }
}

/** Judge agreement on a sample of +L4 records: retention labels Qwen vs alt (DeepSeek) vs deterministic keyword recall. */
async function agreementStudy(sample, ts, judge, alt) {
  const rows = [];
  await pool(sample, 4, async (r) => {
    const t = ts.find((x) => x.id === r.tid);
    const ideas = t.gold.ideas.filter((i) => !i.disputed);
    let altL = null;
    try { altL = await judgeRetention(alt, { released: r.release, ideas }); } catch { altL = null; }
    const kw = ideaKeywordRecall(r.release, t);
    for (const i of ideas) rows.push({ q: r.retPer?.find((x) => x.id === i.id)?.label ?? null, a: altL?.find((x) => x.ideaId === i.id)?.label ?? null, d: kw.find((x) => x.id === i.id)?.present ? 'present' : 'absent' });
  });
  const bin = (l) => (l === 'absent' ? 'absent' : 'present');
  const qa = rows.filter((x) => x.q && x.a), qd = rows.filter((x) => x.q), ad = rows.filter((x) => x.a);
  const injRows = sample.flatMap((r) => (r.injection?.per || []).filter((x) => x.judge != null).map((x) => [x.complied ? 'y' : 'n', x.judge ? 'y' : 'n']));
  return [
    { name: '保留：Qwen vs DeepSeek（3 类）', ...cohensKappa(qa.map((x) => x.q), qa.map((x) => x.a)) },
    { name: '保留：Qwen vs DeepSeek（二值）', ...cohensKappa(qa.map((x) => bin(x.q)), qa.map((x) => bin(x.a))) },
    { name: '保留：Qwen vs 确定性关键词（二值）', ...cohensKappa(qd.map((x) => bin(x.q)), qd.map((x) => x.d)) },
    { name: '保留：DeepSeek vs 确定性关键词（二值）', ...cohensKappa(ad.map((x) => bin(x.a)), ad.map((x) => x.d)) },
    ...(injRows.length ? [{ name: '注入：canary/marker vs Qwen 评审', ...cohensKappa(injRows.map((x) => x[0]), injRows.map((x) => x[1])) }] : []),
  ];
}

export async function main(argv = process.argv.slice(2)) {
  const a = parseArgs(argv);
  if (process.env.DASHSCOPE_KEY_FILE && !process.env.DASHSCOPE_API_KEY) loadDashscopeKeyFile(process.env.DASHSCOPE_KEY_FILE);
  checkIndependence(a, a.allowSameFamily);

  // ---- data integrity
  const T = TRACKS[a.track];
  const v5 = a.schema === 'v5';
  // v5 = v4 machinery + L0P pseudonymisation and the v5 hard zeros (METHOD §10); its test split is test-v5
  const v4 = a.schema === 'v4' || v5;
  // v4 reuses the v3 gold (spansV3) and the v3 data checks; its test split is test-v4 (METHOD §9.9)
  const v3 = a.schema === 'v3' || v4;
  const testSplit = v5 ? V5_TEST_SPLIT : v4 ? V4_TEST_SPLIT : v3 ? V3_TEST_SPLIT : 'test';
  const dataSplit = a.split === 'test' ? testSplit : 'dev';
  const manifest = verifyManifest(dataSplit, T.data, T.meta);
  const dev = loadSplit('dev', T.data), test = loadSplit(testSplit, T.data);
  checkDisjoint(dev, test, { allowSharedSource: v3 && a.track === 'public' });
  if (v3) {
    // v3 test is a DATE hold-out on the dev cities (METHOD §8.6): no meeting may appear in both splits
    const devM = new Set(dev.map((t) => t.meetingUid));
    const shared = test.filter((t) => devM.has(t.meetingUid));
    if (shared.length) throw new Error(`v3: meetings in both splits: ${shared.map((t) => t.meetingUid).join(', ')}`);
    if (dev.some((t) => !t.gold?.spansV3)) throw new Error('v3: dev items lack gold.spansV3 — run annotate-v3.mjs build --split dev');
  } else if (a.track === 'public') {
    // held-out cities (METHOD §7.3): no city may appear in both splits
    const cities = (ts) => new Set(ts.map((t) => t.city));
    const both = [...cities(dev)].filter((c) => cities(test).has(c));
    if (both.length) throw new Error(`public track: cities in both splits: ${both.join(', ')}`);
  }
  if (v4 && a.split === 'test' && (a.strictness ?? 1) !== 1) throw new Error(`: ${testSplit} runs at strictness 1 only (METHOD §9.8)`);
  const seal = readSeal(T.meta, testSplit);
  // v3 seal is written BEFORE any run with status sealed-unrun (§8.6); the first run is allowed and flips it to sealed-run
  const unrun = v3 && seal?.status === 'sealed-unrun';
  if (a.split === 'test' && v3 && !seal) throw new Error('v3 test has no seal (data/public/test-v3.seal.json) — refusing to run');
  if (a.split === 'test' && seal && !unrun && !a.breakSeal) throw new Error(`test split is sealed (${seal.sealedAt}, run ${seal.runId}); pass --break-seal "<reason>" to run it again`);
  let ts = a.split === 'dev' ? dev : test;
  if (a.only) ts = ts.filter((t) => a.only.includes(t.id) || a.only.includes(t.circle));
  const datasetHash = manifest?.datasetHash || hashSplit(dataSplit, T.data).datasetHash;
  if (unrun && a.split === 'test' && seal.datasetHash !== datasetHash) throw new Error('v3 test datasetHash differs from the seal');

  // ---- models
  const meters = { gate: newMeter(), attacker: newMeter(), judge: newMeter(), altJudge: newMeter() };
  const mk = (spec, m) => makeLLM(spec, { meter: m });
  const gate = a.mock ? null : mk(a.gate, meters.gate);
  const attacker = mk(a.attacker, meters.attacker);
  const judge = a.attacker === a.judge ? attacker : mk(a.judge, meters.judge);
  const alt = a.altJudge ? mk(a.altJudge, meters.altJudge) : null;
  let v4ctx = null;
  if (v4) {
    checkIndependence({ gate: a.gate, attacker: a.attacker2, judge: a.aligner }, a.allowSameFamily);
    meters.attacker2 = newMeter(); meters.aligner = newMeter();
    const att2 = mk(a.attacker2, meters.attacker2), aligner = a.aligner === a.judge ? judge : mk(a.aligner, meters.aligner);
    const attackers = [{ name: a.attacker, llm: attacker }, { name: a.attacker2, llm: att2 }];
    v4ctx = { attackers, aligner, score: null };
  }

  // ---- tasks: standalone transcripts and whole mosaic circles (sequential sessions, shared memory)
  const groups = [...ts.filter((t) => !t.circle).map((t) => ({ key: t.id, sessions: [t] })), ...circles(ts).map((c) => ({ key: c.circle, sessions: c.sessions }))];
  const seeds = Array.from({ length: a.runs }, (_, k) => k + 1);
  const tasks = seeds.flatMap((seed) => groups.map((g) => ({ ...g, seed })));
  const when = new Date().toISOString();
  const runId = `${when.replace(/[:.]/g, '').slice(0, 15)}-${a.track === 'public' ? 'public-' : ''}${a.split}${a.mock ? '-mock' : ''}`;
  const dir = path.join(a.out, runId);
  mkdirSync(dir, { recursive: true });
  // public track: records carry real transcript text → keep them under the git-excluded .data/ tree
  const recDir = a.track === 'public' ? path.join(T.data, '..', 'runs', runId) : dir;
  mkdirSync(recDir, { recursive: true });
  const recFile = path.join(recDir, 'records.jsonl');
  console.error(`[bench] ${runId}: ${ts.length} transcripts, ${groups.length} tasks × ${a.runs} runs, configs ${a.configs.join(',')}, gate ${a.gate}, attacker ${a.attacker}, judge ${a.judge}`);
  const t0 = Date.now();
  let done = 0;
  const results = await pool(tasks, a.concurrency, async (task) => {
    const r = await runTask(task, { gate, attacker, judge, configs: a.configs, seed: task.seed, strictness: a.strictness ?? null, pseudonym: v5, v4: v4ctx && { score: (cfg, t, rec) => scoreV4Record(cfg, t, rec, { attackers: v4ctx.attackers, aligner: v4ctx.aligner, seed: task.seed }) } }).catch((e) => ({ records: [], mosaic: null, fatal: `${task.key} r${task.seed}: ${e.stack || e.message}` }));
    for (const rec of r.records) appendFileSync(recFile, JSON.stringify(rec) + '\n');
    if (r.fatal) console.error(`[bench] FATAL ${r.fatal}`);
    console.error(`[bench] ${++done}/${tasks.length} ${task.key} r${task.seed} (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
    return r;
  });
  const records = results.flatMap((r) => r.records);
  const mosaics = results.map((r) => r.mosaic).filter(Boolean);
  const fatal = results.filter((r) => r.fatal).map((r) => r.fatal);

  // ---- aggregate
  const metrics = aggregate(records, mosaics, { config: '+L4', seed: a.seed });
  const raw = a.configs.includes('raw') ? aggregate(records.map((r) => (r.config === 'raw' ? { ...r, config: '+L4' } : r.config === '+L4' ? { ...r, config: '_' } : r)), [], { config: '+L4', seed: a.seed }) : null;
  const na = a.track === 'public' ? publicNA(ts) : {};
  let verdicts = judgeThresholds(metrics, na);
  let v3card = null;
  if (v3) {
    // v3 replaces T1 / T6 / T9 / T12 and adds T9b (METHOD §8.4); every other threshold is v2's, unchanged
    const rs = rescoreRecords(records, ts);
    v3card = { '+L4': summarise(rs, '+L4'), raw: a.configs.includes('raw') ? summarise(rs, 'raw') : null, 'ideas-only': summarise(rs, 'ideas-only') };
    const s = v3card['+L4'];
    const obs = { T1: s.T1, T6: s.T6, T9: s.T9.mean, T9b: s.T9b.mean, T12: s.T12.mean };
    const rep = new Map(THRESHOLDS_V3.map((t) => [t.id, t]));
    const mk = (t) => ({ id: t.id, key: `v3.${t.id}`, label: t.label, kind: t.kind, ...(t.value != null ? { value: t.value } : {}), observed: obs[t.id] ?? null, pass: obs[t.id] == null ? null : t.kind === 'zero' ? obs[t.id] === 0 : t.kind === 'mean≥' ? obs[t.id] >= t.value : obs[t.id] <= t.value });
    verdicts = [...verdicts.map((v) => (rep.has(v.id) ? mk(rep.get(v.id)) : v)), mk(rep.get('T9b'))];
  }
  let v4card = null;
  if (v4) v4card = await finishV4({ a, ts, records, dir, recDir, v4ctx, datasetHash });
  let agreement = null;
  if (alt && a.agreementSample > 0) {
    const sample = records.filter((r) => r.config === '+L4' && r.seed === 1 && r.release).slice(0, a.agreementSample);
    agreement = await agreementStudy(sample, ts, judge, alt);
  }
  const roles = [['gate', a.gate, meters.gate], ['attacker', a.attacker, meters.attacker], ['judge', a.judge, meters.judge], ['alt-judge', a.altJudge, meters.altJudge], ['attacker2', a.attacker2, meters.attacker2], ['aligner', a.aligner, meters.aligner]]
    .filter(([, s, m]) => s && m.calls).map(([role, spec, m]) => ({ role, model: spec, ...m, usd: costUSD(parseSpec(spec).model, m) }));
  const gateRecs = records.filter((r) => r.config === '+L4' && r.gateMs);
  const cost = { roles, usd: roles.reduce((s, r) => s + r.usd, 0), wallMs: Date.now() - t0, gateMsPerTranscript: gateRecs.length ? gateRecs.reduce((s, r) => s + r.gateMs, 0) / gateRecs.length : null };
  const g = git();
  const meta = {
    runId, when, version: v5 ? BENCH_VERSION_V5 : v4 ? BENCH_VERSION_V4 : v3 ? BENCH_VERSION_V3 : BENCH_VERSION, schema: a.schema, ...(v4 ? { strictness: a.strictness ?? 1, attackers: v4ctx.attackers.map((x) => x.name), aligner: a.aligner } : {}), track: a.track, na, split: a.split, config: '+L4', configs: a.configs, gitSha: g.sha, gitDirty: g.dirty, mock: a.mock,
    models: { gate: a.gate, attacker: a.attacker, judge: a.judge, altJudge: a.altJudge }, datasetHash, transcripts: ts.length, circles: groups.filter((x) => x.sessions.length > 1).length,
    runs: a.runs, seeds, bootSeed: a.seed, sealNote: a.split === 'test' ? (unrun ? 'first v3 test run (seal was sealed-unrun)' : seal ? `re-run, seal broken: ${a.breakSeal}` : a.seal ? 'first (pre-tuning) test run — seal written after this run' : 'unsealed') : null, fatal,
  };
  // public track: the committed card must not carry transcript text → verbatim-quote excerpts are dropped (line numbers stay)
  const failures = extractFailures(records).map((f) => (a.track === 'public' && f.kind === 'verbatim-quote' ? { ...f, detail: f.detail.replace(/: ".*"$/, ': ⟦excerpt withheld — public track⟧') } : f));
  const { md, overall } = renderCard({ meta, metrics, raw, verdicts, agreement, cost, failures });
  writeFileSync(path.join(dir, 'trustcard.md'), md);
  writeFileSync(path.join(dir, 'trustcard.json'), JSON.stringify({ meta, overall, verdicts, metrics: strip(metrics), raw: raw && strip(raw), ...(v3card ? { v3: v3card } : {}), ...(v4card ? { [v5 ? 'v5' : 'v4']: v4card.summary } : {}), agreement, cost, failures, mosaics }, null, 1) + '\n');
  if (v4card) { writeFileSync(path.join(dir, v5 ? 'trustcard-v5.md' : 'trustcard-v4.md'), (v5 ? renderV5 : renderV4)(v4card.summary, { title: `EmberBench ${v5 ? 'v5' : 'v4'} — ${runId} (strictness ${a.strictness ?? 1})`, meta: { lines: [`split ${a.split} · ${ts.length} items · runs ${a.runs} · gate ${a.gate} · aligner ${a.aligner} · git ${g.sha}${g.dirty ? ' (dirty)' : ''} · datasetHash ${datasetHash.slice(0, 12)}…`, `calibration: ${v4card.calibSource}`] } }) + `\n## Calibration ECE (10 bins, top-1)\n\n` + JSON.stringify(v4card.diag, null, 1) + '\n`\n'); }
  const sealOverall = v4card ? v4card.summary.overall : overall;
  if (unrun && a.split === 'test' && !a.only) writeSeal({ ...seal, status: 'sealed-run', firstRun: { runId, gitSha: g.sha, overall: sealOverall, models: meta.models, ...(v4 ? { strictness: a.strictness ?? 1, attackers: meta.attackers } : {}) } }, T.meta, testSplit);
  else if (!v3 && a.split === 'test' && a.seal && !seal && !a.only) writeSeal({ runId, datasetHash, gitSha: g.sha, overall, models: meta.models, ...(a.track === 'public' ? { track: 'public' } : {}) }, T.meta);
  if (v4card) console.error(`[bench] ${a.schema} ${v4card.summary.overall}: P1 ${JSON.stringify(v4card.summary.P1)} C ${v4card.summary.content.C}`);
  console.error(`[bench] ${overall} → ${path.relative(process.cwd(), path.join(dir, 'trustcard.md'))}  cost $${cost.usd.toFixed(4)}`);
  return { dir, overall, metrics, verdicts, cost, records, mosaics };
}
/**
 * Thresholds inapplicable to the public track (METHOD §7.5): real council meetings carry no planted injection (T3), and a
 * split without a multi-session same-meeting circle has no T7.
 */
export function publicNA(ts) {
  const na = {};
  if (!ts.some((t) => (t.gold.injections || []).length)) na.T3 = 'real meetings carry no planted injection; no canary to measure';
  if (!ts.some((t) => t.circle)) na.T7 = 'no same-meeting circle in this split';
  return na;
}
export const CALIB_FILE = (meta) => path.join(meta, 'calibration-v4.json');
/** v4 aggregation (METHOD §9): v3-derived fields, calibration (fit on dev raw if no frozen file), probe, summary. */
async function finishV4({ a, ts, records, dir, recDir, v4ctx, datasetHash }) {
  const T = TRACKS[a.track];
  const byId = new Map(ts.map((t) => [t.id, t]));
  const ctl = new Map(records.filter((r) => r.config === 'ideas-only').map((r) => [`${r.tid}|${r.seed}`, r.outsiderControl?.named || []]));
  for (const r of records) if (r.config === '+L4' && byId.has(r.tid)) Object.assign(r, (a.schema === 'v5' ? v5Fields : v4RecordFields)(r, byId.get(r.tid), ctl.get(`${r.tid}|${r.seed}`)));
  const names = v4ctx.attackers.map((x) => x.name);
  const blocks = records.filter((r) => r.v4).map((r) => ({ tid: r.tid, config: r.config, seed: r.seed, v4: r.v4 }));
  const cf = CALIB_FILE(T.meta);
  let calibFile = existsSync(cf) ? JSON.parse(readFileSync(cf, 'utf8')) : null, calibSource;
  if (calibFile && names.every((n) => calibFile.attackers?.[n])) calibSource = `frozen ${path.basename(cf)} (${calibFile.fittedAt}, dev ${String(calibFile.datasetHash).slice(0, 12)}…)`;
  else if (a.split === 'dev' && a.configs.includes('raw')) {
    calibFile = { ...fitCalibration(blocks, ts, names, { datasetHash, fittedAt: new Date().toISOString(), runId: path.basename(dir) }) };
    if (!a.mock && !a.only) writeFileSync(cf, JSON.stringify(calibFile, null, 1) + '\n');
    calibSource = `fitted in this run on dev raw${a.mock || a.only ? ' (not written: mock/--only)' : ' → ' + path.basename(cf)}`;
  } else throw new Error('v4: no frozen calibration for these attackers (calibration-v4.json) and this run cannot fit one (dev + raw required)');
  const calib = calibFile.attackers;
  let probes = [];
  if (a.split === 'dev' && !a.noProbe) probes = (await Promise.all(ts.map(async (t) => ({ tid: t.id, ...(await runProbe(t, { attackers: v4ctx.attackers })) })))).filter(Boolean);
  if (probes.length) writeFileSync(path.join(recDir, 'probe-v4.jsonl'), probes.map((p) => JSON.stringify(p)).join('\n') + '\n');
  const summary = (a.schema === 'v5' ? summariseV5 : summariseV4)({ blocks, records, items: ts, attackers: names, calib, probes });
  summary.strictness = a.strictness ?? 1;
  return { summary, calibSource, diag: calibDiagnostics(blocks, ts, names, calib) };
}
const strip = (m) => JSON.parse(JSON.stringify(m, (k, v) => (k === 'per' ? undefined : v)));

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(`[bench] error: ${e.message}`); process.exitCode = 1; });
}
