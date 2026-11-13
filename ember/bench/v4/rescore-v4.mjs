#!/usr/bin/env node
// EmberBench v4 · rescore stored records (METHOD §9). No gate calls. Two modes:
//   --run <records dir>                         recompute the v4 summary from records that carry r.v4 (from --schema v4)
//   --run <dir> --attack                        (dev only) add v4 attacker distributions + alignment to v3 records that lack them
//   --fit-calibration                           (dev only) fit τ on dev raw and write data/public/calibration-v4.json (refuses to overwrite)
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { loadSplit, verifyManifest, PUBLIC_DATA_DIR, PUBLIC_META_DIR } from '../data.mjs';
import { makeLLM, newMeter, costUSD, parseSpec, loadDashscopeKeyFile } from '../providers.mjs';
import { scoreV4Record, summariseV4, renderV4, fitCalibration, calibDiagnostics, v4RecordFields, runProbe } from './score-v4.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CALIB = path.join(PUBLIC_META_DIR, 'calibration-v4.json');

async function pool(items, n, fn) { let i = 0; await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) { const k = i++; await fn(items[k], k); } })); }

export async function main(argv = process.argv.slice(2)) {
  const a = {}; for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) a[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  if (!a.run) throw new Error('--run <records dir> required');
  const split = a.split || 'dev';
  if (split !== 'dev' && (a.attack || a['fit-calibration'])) throw new Error('attack / calibration fitting are dev-only (METHOD §9.2)');
  if (process.env.DASHSCOPE_KEY_FILE && !process.env.DASHSCOPE_API_KEY) loadDashscopeKeyFile(process.env.DASHSCOPE_KEY_FILE);
  const manifest = verifyManifest(split, PUBLIC_DATA_DIR, PUBLIC_META_DIR);
  const items = loadSplit(split, PUBLIC_DATA_DIR);
  const byId = new Map(items.map((t) => [t.id, t]));
  const recFile = path.join(a.run, a.in || 'records.jsonl');
  const records = readFileSync(recFile, 'utf8').trim().split('\n').map(JSON.parse);
  const names = [a.attacker || 'dashscope:qwen-plus', a.attacker2 || 'dashscope:kimi-k3'];
  const meters = Object.fromEntries([...names, 'aligner'].map((n) => [n, newMeter()]));
  if (a.attack) {
    const attackers = names.map((n) => ({ name: n, llm: makeLLM(n, { meter: meters[n] }) }));
    const aligner = makeLLM(a.aligner || 'dashscope:qwen-plus', { meter: meters.aligner });
    const todo = records.filter((r) => !r.v4 && byId.has(r.tid) && (!a.configs || String(a.configs).split(',').includes(r.config)));
    let done = 0;
    await pool(todo, Number(a.concurrency) || 6, async (r) => { r.v4 = await scoreV4Record(r.config, byId.get(r.tid), r, { attackers, aligner, seed: r.seed }).catch((e) => { console.error(`[v4] ${r.tid} ${r.config}: ${e.message}`); return null; }); console.error(`[v4] ${++done}/${todo.length}`); });
    writeFileSync(path.join(a.run, 'records-v4.jsonl'), records.map((r) => JSON.stringify(r)).join('\n') + '\n');
    if (a.probe) {
      const probes = []; await pool(items, 6, async (t) => probes.push({ tid: t.id, ...(await runProbe(t, { attackers })) }));
      writeFileSync(path.join(a.run, 'probe-v4.jsonl'), probes.map((p) => JSON.stringify(p)).join('\n') + '\n');
    }
  }
  const ctl = new Map(records.filter((r) => r.config === 'ideas-only').map((r) => [`${r.tid}|${r.seed}`, r.outsiderControl?.named || []]));
  for (const r of records) if (r.config === '+L4' && byId.has(r.tid)) Object.assign(r, v4RecordFields(r, byId.get(r.tid), ctl.get(`${r.tid}|${r.seed}`)));
  const blocks = records.filter((r) => r.v4).map((r) => ({ tid: r.tid, config: r.config, seed: r.seed, v4: r.v4 }));
  let calib;
  if (a['fit-calibration']) {
    if (existsSync(CALIB) && !a.force) throw new Error(`${CALIB} exists (frozen) — refusing to overwrite`);
    const c = fitCalibration(blocks, items, names, { gitSha: (() => { try { return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim(); } catch { return null; } })(), datasetHash: manifest.datasetHash, fittedAt: new Date().toISOString(), runId: path.basename(path.resolve(a.run)) });
    writeFileSync(CALIB, JSON.stringify(c, null, 1) + '\n');
    console.error(`[v4] calibration written → ${CALIB}`);
  }
  if (!existsSync(CALIB)) throw new Error('no calibration-v4.json — run with --fit-calibration on dev first');
  calib = JSON.parse(readFileSync(CALIB, 'utf8')).attackers;
  const probeF = path.join(a.run, 'probe-v4.jsonl');
  const probes = split === 'dev' && existsSync(probeF) ? readFileSync(probeF, 'utf8').trim().split('\n').map(JSON.parse) : [];
  const s = summariseV4({ blocks, records, items, attackers: names, calib, probes });
  const diag = calibDiagnostics(blocks, items, names, calib);
  const runId = path.basename(path.resolve(a.run));
  const cost = Object.fromEntries(Object.entries(meters).filter(([, m]) => m.calls).map(([n, m]) => [n, { calls: m.calls, usd: costUSD(parseSpec(n === 'aligner' ? (a.aligner || 'dashscope:qwen-plus') : n).model, m) }]));
  const out = path.join(a.out || path.join(HERE, '..', 'results', 'public-v4'), runId + (a.tag ? `-${a.tag}` : ''));
  mkdirSync(out, { recursive: true });
  const md = renderV4(s, { title: `EmberBench v4 rescore — ${runId}${a.tag ? ` (${a.tag})` : ''}`, meta: { lines: [`split ${split} · ${items.length} items · records ${records.length} · datasetHash ${manifest.datasetHash.slice(0, 12)}… · no gate calls`] } });
  writeFileSync(path.join(out, 'rescore-v4.md'), md + '\n## Calibration ECE (10 bins, top-1)\n\n```\n' + JSON.stringify(diag, null, 1) + '\n```\n');
  writeFileSync(path.join(out, 'rescore-v4.json'), JSON.stringify({ runId, split, datasetHash: manifest.datasetHash, summary: s, diag, cost }, null, 1) + '\n');
  console.log(md);
  if (Object.keys(cost).length) console.log('cost', JSON.stringify(cost));
  return s;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.stack || e.message); process.exitCode = 1; });
