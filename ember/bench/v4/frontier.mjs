#!/usr/bin/env node
// EmberBench v4 · privacy/utility frontier over gate strictness levels on dev (METHOD §9.8). Reads v4 summaries
// (trustcard.json .v4 of run.mjs --schema v4, or rescore-v4.json .summary) given as level=path pairs.
//   node ember/bench/v4/frontier.mjs --level 0=<dir> --level 1=<dir> ... [--out ember/bench/results/public-v4/frontier-dev]
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ci, P1_MAX, C_MIN } from './score-v4.mjs';

export function loadSummary(p) {
  for (const f of [path.join(p, 'trustcard.json'), path.join(p, 'rescore-v4.json'), p]) if (existsSync(f) && f.endsWith('.json')) { const j = JSON.parse(readFileSync(f, 'utf8')); return { s: j.v4 || j.summary, cost: j.cost?.usd ?? null, runId: j.meta?.runId || j.runId }; }
  throw new Error(`no v4 summary in ${p}`);
}
export function renderFrontier(rows) {
  const f2 = (x) => (x == null ? '—' : x.toFixed(2));
  const L = ['# EmberBench v4 — dev privacy / utility frontier', '', `P1 PASS iff CI upper ≤ ${P1_MAX} bits/claim; C PASS iff ≥ ${C_MIN}. Dev is a tuning split: these numbers select nothing on test (test-v4 runs level 1 only).`, '',
    '| level | run | P1 excess [CI] | +L4 bits/claim | ideas-only | raw | C | T8 | T9 | T11 | T1v4 | T2 | T6 | selfTraits | unattr. | overall |', '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'];
  for (const { level, runId, s } of rows) L.push(`| ${level} | ${runId} | ${ci(s.P1)} | ${ci(s.abs['+L4'])} | ${ci(s.abs['ideas-only'])} | ${ci(s.abs.raw)} | ${f2(s.content.C)} | ${f2(s.content.T8.mean)} | ${f2(s.content.T9.mean)} | ${f2(s.content.T11.mean)} | ${s.hard.T1v4} | ${s.hard.T2} | ${s.hard.T6} | ${s.hard.selfTraitsReported} | ${s.attribution.rate == null ? '—' : (100 * s.attribution.rate).toFixed(1) + '%'} | ${s.overall} |`);
  // ASCII scatter: x = P1 excess, y = C
  const W = 56, H = 14, xs = rows.map((r) => r.s.P1?.mean ?? 0), ys = rows.map((r) => r.s.content.C ?? 0);
  const x0 = Math.min(-0.3, ...xs), x1 = Math.max(0.5, ...xs), y0 = Math.min(0.6, ...ys), y1 = Math.max(1, ...ys);
  const g = Array.from({ length: H + 1 }, () => Array(W + 1).fill(' '));
  const X = (x) => Math.round(((x - x0) / (x1 - x0)) * W), Y = (y) => H - Math.round(((y - y0) / (y1 - y0)) * H);
  for (let r = 0; r <= H; r++) g[r][X(P1_MAX)] = '¦';
  for (let c = 0; c <= W; c++) if (g[Y(C_MIN)][c] === ' ') g[Y(C_MIN)][c] = '-';
  rows.forEach((r, i) => { g[Y(ys[i])][X(xs[i])] = String(r.level); });
  L.push('', '```', `C ↑ (${f2(y1)})`, ...g.map((row) => '  |' + row.join('')), `  +${'-'.repeat(W + 1)}→ P1 excess bits/claim (${f2(x0)} … ${f2(x1)})`, `  ¦ = P1 limit ${P1_MAX}; --- = C limit ${C_MIN}; digits = strictness level; pass region = left of ¦, above ---`, '```');
  return L.join('\n') + '\n';
}
export async function main(argv = process.argv.slice(2)) {
  const levels = []; let out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'results', 'public-v4', 'frontier-dev');
  for (let i = 0; i < argv.length; i++) { if (argv[i] === '--level') { const [l, p] = argv[++i].split('='); levels.push({ level: Number(l), p }); } else if (argv[i] === '--out') out = argv[++i]; }
  const rows = levels.map(({ level, p }) => ({ level, ...loadSummary(p) })).sort((a, b) => a.level - b.level);
  mkdirSync(out, { recursive: true });
  const md = renderFrontier(rows);
  writeFileSync(path.join(out, 'frontier.md'), md);
  writeFileSync(path.join(out, 'frontier.json'), JSON.stringify(rows.map(({ level, runId, cost, s }) => ({ level, runId, cost, P1: s.P1, abs: s.abs, content: { C: s.content.C, T8: s.content.T8.mean, T9: s.content.T9.mean, T11: s.content.T11.mean }, hard: s.hard, attribution: { rate: s.attribution.rate }, overall: s.overall })), null, 1) + '\n');
  console.log(md);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.stack || e.message); process.exitCode = 1; });
