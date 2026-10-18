// Dev helper: show which gold identifiers survive deterministic L0+L1+L2 (no LLM).
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runGate } from '../lib/gate.mjs';
const dir = join(dirname(fileURLToPath(import.meta.url)), 'data');
const show = process.argv.includes('--show');
for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
  const t = JSON.parse(readFileSync(join(dir, f), 'utf8'));
  const { digest } = await runGate(t, { layers: ['L0', 'L1', 'L2'], mock: true });
  const surv = t.gold.identifiers.filter((g) => !['style', 'quasi'].includes(g.kind) && digest.toLowerCase().includes(g.text.toLowerCase()));
  const toks = t.roster.flatMap((p) => [p.name, ...(p.aliases || [])]).filter((x) => x.length >= 2 && (/[\u4e00-\u9fff]/.test(x) ? digest.includes(x) : new RegExp(`\\b${x.replace(/[.]/g, '\\.')}\\b`).test(digest)));
  console.log(`${t.id}: survived=${surv.map((g) => `[${g.kind}]${g.text}`).join(' | ')} rosterTok=${toks.join(',')}`);
  if (show) console.log(digest);
}
