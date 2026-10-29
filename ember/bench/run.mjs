#!/usr/bin/env node
// EmberBench CLI.
//   node ember/bench/run.mjs --split dev|test --runs 3 --configs +L4,ideas-only,raw --concurrency 6
//        [--mock] [--gate deepseek:deepseek-flash] [--attacker dashscope:qwen-plus] [--judge dashscope:qwen-plus]
//        [--alt-judge deepseek:deepseek-flash] [--agreement-sample 10] [--only id1,id2] [--seed 12345]
//        [--allow-same-family] [--break-seal "<reason>"] [--seal] [--out ember/bench/results]
// Writes results/<run-id>/{trustcard.md, trustcard.json, records.jsonl}.
import { mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { makeLLM, newMeter, costUSD, loadDashscopeKeyFile, parseSpec } from './providers.mjs';
import { loadSplit, verifyManifest, hashSplit, checkDisjoint, readSeal, writeSeal, circles } from './data.mjs';
import { runTask, CONFIGS } from './harness.mjs';
import { aggregate, judgeThresholds, renderCard, extractFailures, BENCH_VERSION } from './trustcard.mjs';
import { judgeRetention } from './attack.mjs';
import { cohensKappa, ideaKeywordRecall } from './metrics.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

export function parseArgs(argv) {
  const a = { split: 'dev', runs: 3, configs: ['+L4', 'ideas-only', 'raw'], concurrency: 4, mock: false, seed: 12345, agreementSample: 10, out: path.join(HERE, 'results') };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = () => argv[++i];
    if (k === '--split') a.split = v();
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
    else if (k === '--out') a.out = v();
    else throw new Error(`unknown arg ${k}`);
  }
  if (!['dev', 'test'].includes(a.split)) throw new Error('--split must be dev|test');
  for (const c of a.configs) if (!CONFIGS.includes(c)) throw new Error(`unknown config ${c} (have ${CONFIGS.join(', ')})`);
  if (a.configs.includes('+L4') && !a.configs.includes('ideas-only')) a.configs.push('ideas-only'); // excess needs the baseline
  if (a.mock) { a.gate = 'mock:gate'; a.attacker = 'mock:attacker'; a.judge = 'mock:judge'; a.altJudge = a.altJudge ? 'mock:alt' : null; }
  a.gate ||= `deepseek:${process.env.LARES_AI_LLM_MODEL || 'deepseek-flash'}`;
  a.attacker ||= 'dashscope:qwen-plus';
  a.judge ||= 'dashscope:qwen-plus';
  if (a.altJudge === undefined) a.altJudge = a.mock ? null : 'deepseek:deepseek-flash';
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
  const manifest = verifyManifest(a.split);
  const dev = loadSplit('dev'), test = loadSplit('test');
  checkDisjoint(dev, test);
  const seal = readSeal();
  if (a.split === 'test' && seal && !a.breakSeal) throw new Error(`test split is sealed (${seal.sealedAt}, run ${seal.runId}); pass --break-seal "<reason>" to run it again`);
  let ts = a.split === 'dev' ? dev : test;
  if (a.only) ts = ts.filter((t) => a.only.includes(t.id) || a.only.includes(t.circle));
  const datasetHash = manifest?.datasetHash || hashSplit(a.split).datasetHash;

  // ---- models
  const meters = { gate: newMeter(), attacker: newMeter(), judge: newMeter(), altJudge: newMeter() };
  const mk = (spec, m) => makeLLM(spec, { meter: m });
  const gate = a.mock ? null : mk(a.gate, meters.gate);
  const attacker = mk(a.attacker, meters.attacker);
  const judge = a.attacker === a.judge ? attacker : mk(a.judge, meters.judge);
  const alt = a.altJudge ? mk(a.altJudge, meters.altJudge) : null;

  // ---- tasks: standalone transcripts and whole mosaic circles (sequential sessions, shared memory)
  const groups = [...ts.filter((t) => !t.circle).map((t) => ({ key: t.id, sessions: [t] })), ...circles(ts).map((c) => ({ key: c.circle, sessions: c.sessions }))];
  const seeds = Array.from({ length: a.runs }, (_, k) => k + 1);
  const tasks = seeds.flatMap((seed) => groups.map((g) => ({ ...g, seed })));
  const when = new Date().toISOString();
  const runId = `${when.replace(/[:.]/g, '').slice(0, 15)}-${a.split}${a.mock ? '-mock' : ''}`;
  const dir = path.join(a.out, runId);
  mkdirSync(dir, { recursive: true });
  const recFile = path.join(dir, 'records.jsonl');
  console.error(`[bench] ${runId}: ${ts.length} transcripts, ${groups.length} tasks × ${a.runs} runs, configs ${a.configs.join(',')}, gate ${a.gate}, attacker ${a.attacker}, judge ${a.judge}`);
  const t0 = Date.now();
  let done = 0;
  const results = await pool(tasks, a.concurrency, async (task) => {
    const r = await runTask(task, { gate, attacker, judge, configs: a.configs, seed: task.seed }).catch((e) => ({ records: [], mosaic: null, fatal: `${task.key} r${task.seed}: ${e.stack || e.message}` }));
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
  const verdicts = judgeThresholds(metrics);
  let agreement = null;
  if (alt && a.agreementSample > 0) {
    const sample = records.filter((r) => r.config === '+L4' && r.seed === 1 && r.release).slice(0, a.agreementSample);
    agreement = await agreementStudy(sample, ts, judge, alt);
  }
  const roles = [['gate', a.gate, meters.gate], ['attacker', a.attacker, meters.attacker], ['judge', a.judge, meters.judge], ['alt-judge', a.altJudge, meters.altJudge]]
    .filter(([, s, m]) => s && m.calls).map(([role, spec, m]) => ({ role, model: spec, ...m, usd: costUSD(parseSpec(spec).model, m) }));
  const gateRecs = records.filter((r) => r.config === '+L4' && r.gateMs);
  const cost = { roles, usd: roles.reduce((s, r) => s + r.usd, 0), wallMs: Date.now() - t0, gateMsPerTranscript: gateRecs.length ? gateRecs.reduce((s, r) => s + r.gateMs, 0) / gateRecs.length : null };
  const g = git();
  const meta = {
    runId, when, version: BENCH_VERSION, split: a.split, config: '+L4', configs: a.configs, gitSha: g.sha, gitDirty: g.dirty, mock: a.mock,
    models: { gate: a.gate, attacker: a.attacker, judge: a.judge, altJudge: a.altJudge }, datasetHash, transcripts: ts.length, circles: groups.filter((x) => x.sessions.length > 1).length,
    runs: a.runs, seeds, bootSeed: a.seed, sealNote: a.split === 'test' ? (seal ? `re-run, seal broken: ${a.breakSeal}` : a.seal ? 'first (pre-tuning) test run — seal written after this run' : 'unsealed') : null, fatal,
  };
  const failures = extractFailures(records);
  const { md, overall } = renderCard({ meta, metrics, raw, verdicts, agreement, cost, failures });
  writeFileSync(path.join(dir, 'trustcard.md'), md);
  writeFileSync(path.join(dir, 'trustcard.json'), JSON.stringify({ meta, overall, verdicts, metrics: strip(metrics), raw: raw && strip(raw), agreement, cost, failures, mosaics }, null, 1) + '\n');
  if (a.split === 'test' && a.seal && !seal && !a.only) writeSeal({ runId, datasetHash, gitSha: g.sha, overall, models: meta.models });
  console.error(`[bench] ${overall} → ${path.relative(process.cwd(), path.join(dir, 'trustcard.md'))}  cost $${cost.usd.toFixed(4)}`);
  return { dir, overall, metrics, verdicts, cost, records, mosaics };
}
const strip = (m) => JSON.parse(JSON.stringify(m, (k, v) => (k === 'per' ? undefined : v)));

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(`[bench] error: ${e.message}`); process.exitCode = 1; });
}
