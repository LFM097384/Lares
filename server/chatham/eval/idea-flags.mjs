import { readFileSync } from 'node:fs';
import { bigramOverlap } from './metrics.mjs';
const r = JSON.parse(readFileSync(new URL('./results.json', import.meta.url), 'utf8'));
let flagged = 0, total = 0; const per = [];
for (const z of r.rows.filter((z) => z.config === '+L4' && !z.error)) {
  const t = JSON.parse(readFileSync(new URL(`./data/${z.transcript}.json`, import.meta.url), 'utf8'));
  let f = 0;
  for (const i of t.gold.ideas) {
    const best = (z.claims || []).map((c) => ({ c, s: bigramOverlap(i.text, c.text) })).sort((a, b) => b.s - a.s).slice(0, 2);
    if (best.some((b) => b.c.risk && b.s > 0.05)) f++;
  }
  per.push(`${z.transcript} ${f}/${t.gold.ideas.length}`); flagged += f; total += t.gold.ideas.length;
}
console.log(per.join(', '), `ALL ${flagged}/${total}`);
