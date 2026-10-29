#!/usr/bin/env node
// EmberBench · apply the second-model consistency check to generated transcripts (deterministic, idempotent).
// Every gold item the checker flagged with severity "error" is moved out of scoring into gold.disputed[]
// (kept for audit). Roster aliases are never removed, so name-leak scanning is unaffected.
//   node ember/bench/gen/finalize.mjs [--split dev|test]
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from './validate.mjs';

const DATA = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'data');
const FIELDS = { ideas: 'id', stances: 'id', publicFacts: 'id', identifiers: 'text', thirdParties: 'name', quotes: 'text', mosaic: 'owner' };

export function applyCheck(t, issues) {
  if (t.gold.disputedApplied) return { moved: 0 };
  const disputed = [];
  for (const iss of issues.filter((x) => x.severity === 'error')) {
    const field = Object.keys(FIELDS).find((f) => String(iss.field || '').toLowerCase().startsWith(f.toLowerCase()));
    const ref = String(iss.ref ?? '').trim();
    if (field) {
      const key = FIELDS[field];
      const arr = t.gold[field] || [];
      const i = arr.findIndex((x) => String(x[key]) === ref || (ref && String(x[key]).includes(ref)) || (ref && ref.includes(String(x[key])) && String(x[key]).length >= 2));
      if (i >= 0) { disputed.push({ field, item: arr[i], problem: String(iss.problem).slice(0, 400) }); arr.splice(i, 1); continue; }
    }
    if (/^questions?/i.test(iss.field || '')) {
      const qs = t.questions || [];
      const i = qs.findIndex((q) => q.id === ref);
      if (i >= 0 && !qs[i].injection) { disputed.push({ field: 'questions', item: { ...qs[i] }, problem: String(iss.problem).slice(0, 400) }); qs[i].answer = ''; qs[i].disputed = true; continue; }
    }
    disputed.push({ field: iss.field, item: null, ref, problem: String(iss.problem).slice(0, 400), unmatched: true });
  }
  t.gold.disputed = disputed;
  t.gold.disputedApplied = true;
  return { moved: disputed.filter((d) => !d.unmatched).length, unmatched: disputed.filter((d) => d.unmatched).length };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const splits = process.argv.includes('--split') ? [process.argv[process.argv.indexOf('--split') + 1]] : ['dev', 'test'];
  for (const s of splits) {
    for (const f of readdirSync(path.join(DATA, s)).filter((x) => x.endsWith('.check.json'))) {
      const tf = path.join(DATA, s, f.replace('.check.json', '.json'));
      if (!existsSync(tf)) continue;
      const t = JSON.parse(readFileSync(tf, 'utf8'));
      const c = JSON.parse(readFileSync(path.join(DATA, s, f), 'utf8'));
      const r = applyCheck(t, c.check?.issues || c.issues || []);
      const v = validate(t);
      writeFileSync(tf, JSON.stringify(t, null, 2) + '\n');
      console.log(`${s}/${t.id}: moved ${r.moved}, unmatched ${r.unmatched ?? 0}; ideas ${t.gold.ideas.length}; still valid=${v.ok}${v.ok ? '' : ' ' + v.errors.slice(0, 2).join(' | ')}`);
    }
  }
}
