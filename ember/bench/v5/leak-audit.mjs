// EmberBench v5 · leak audit (METHOD P13). Offline, deterministic, no LLM: lists every T1 v5 / T2 v5 / T6 v5 hit of a stored
// run with item, seed, outward sentence, source name / variant and a root-cause class, plus whether the P13 post-hoc
// offline replay (replay-p13.mjs) removes it. Metric code is unchanged (metrics-v5.mjs).
//   node ember/bench/v5/leak-audit.mjs [--run <dir>] [--data <dir>] [--md <out.md>] [--redact]
// Causes:
//   a  masker variant miss       the name is in the transcript but the pseudonymiser did not learn / match that variant
//   b  bound position missed     a token / granted name sat in an attributive position the post-check did not recognise
//   c  model rewrote / introduced the outward name does not occur in the transcript (the model respelled or invented it)
//   d  seat / org / title pattern a bound district, organisation or staff title passed in a construction the gate missed
//   e  sensitive long quote      a ≥ 12-word run shared with a transcript line that carries a bound referent
//   f  metric artefact / FP      noted only: the metric flags a non-person (a place, a title word used generically)
import fs from 'node:fs';
import path from 'node:path';
import { bindingLeaksV5, sensitiveQuoteLeaks, v5RecordFields, personVariants } from '../metrics-v5.mjs';
import { buildPseudonyms } from '../../core/gate/pseudonym.mjs';
import { expandPublicContext } from '../../core/gate/l2.mjs';
import { replayRecord } from './replay-p13.mjs';

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const RUN = arg('--run', '.data/emberbench-public/runs/2026-11-17T0037-public-test');
const DATA = arg('--data', '.data/emberbench-public/data/test-v5');
const MD = arg('--md', null);
const REDACT = process.argv.includes('--redact');

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const has = (txt, v) => new RegExp(`(?<![\\p{L}])${esc(v).replace(/\s+/g, '\\s+')}(?![\\p{L}])`, 'iu').test(txt);
export const initials = (s) => String(s).replace(/\b([A-Z])[\p{L}'’-]+/gu, '$1.');
function sentenceOf(text, v) {
  const m = new RegExp(`(?<![\\p{L}])${esc(v).replace(/\s+/g, '\\s+')}(?![\\p{L}])`, 'iu').exec(text);
  if (!m) return '';
  let a = m.index; while (a > 0 && !/[.!?\n]/.test(text[a - 1])) a--;
  let b = m.index; while (b < text.length && !/[.!?\n]/.test(text[b])) b++;
  return text.slice(a, b + 1).trim().slice(0, 260);
}

/** root cause of one T1 v5 item (see header). */
export function classify(item, { raw, learnedLow, granted }) {
  if (item.cat === 'seats' || item.cat === 'orgs') return 'd';
  if (item.rule === 'gold') return 'd';
  if (item.rule === 'public-name-bound') {
    if (granted.some((g) => has(g, item.text) || has(item.text, g))) return 'b';
    // a variant that is a generic title word or contains a lower-case common noun is not a person's name
    if (/^(?:mayor|president|chair|governor|council)$/i.test(item.text) || /\s[a-z]/.test(item.text)) return 'f';
    if (!has(raw, item.text)) return 'c';
    return 'a'; // in the transcript, not granted: the stored run never tokenised it
  }
  return has(raw, item.text) ? 'a' : 'c';
}

export function audit({ run = RUN, data = DATA } = {}) {
  const recs = fs.readFileSync(path.join(run, 'records.jsonl'), 'utf8').split('\n').filter(Boolean).map(JSON.parse);
  const items = new Map();
  const T = (tid) => { if (!items.has(tid)) items.set(tid, JSON.parse(fs.readFileSync(path.join(data, `${tid}.json`), 'utf8'))); return items.get(tid); };
  const ctl = new Map(recs.filter((r) => r.config === 'ideas-only').map((r) => [`${r.tid}|${r.seed}`, r.outsider?.named || null]));
  const rows = [];
  for (const r of recs.filter((x) => x.config === '+L4')) {
    const t = T(r.tid), outward = [r.release || '', r.memoryText || ''].filter(Boolean).join('\n');
    const raw = (t.lines || []).map((l) => l.text).join('\n');
    // what the CURRENT pseudonymiser learns (P13 rules) vs what the stored run's log shows was tokenised
    const P = buildPseudonyms({ roster: t.roster, lines: t.lines }, { seed: r.seed ?? 1, lang: t.lang || 'en', shared: expandPublicContext(t.publicContext || []) });
    const learnedLow = new Set(P.entries.flatMap((e) => (e.names || []).map((n) => n.toLowerCase())));
    const granted = (r.pseudonym?.log || []).filter((x) => x.decision === 'granted' && x.display).map((x) => String(x.display));
    const ctx = { raw, learnedLow, granted };
    const rr = replayRecord(r, t), after = [rr.release || '', rr.memoryText || ''].filter(Boolean).join('\n');
    const afterBind = bindingLeaksV5(after, t).items, afterQ = sensitiveQuoteLeaks(after, t);
    const base = { tid: r.tid, seed: r.seed };
    const bind = bindingLeaksV5(outward, t).items;
    for (const it of bind) rows.push({ ...base, metric: 'T1v5', cat: it.cat, rule: it.rule || '', variant: it.text, sentence: sentenceOf(outward, it.text), cause: classify(it, ctx), inTranscript: has(raw, it.text), fixedByReplay: !afterBind.some((x) => x.cat === it.cat && x.text === it.text) });
    for (const q of sensitiveQuoteLeaks(outward, t)) rows.push({ ...base, metric: 'T2v5', cat: q.why, rule: '', variant: `line ${q.line} (${q.words} words)`, sentence: String(t.lines[q.line]?.text || '').slice(0, 200), cause: 'e', inTranscript: true, fixedByReplay: !afterQ.some((x) => x.line === q.line) });
    const f = v5RecordFields(r, t, ctl.get(`${r.tid}|${r.seed}`));
    if (f.v5out6) {
      const fa = v5RecordFields(rr, t, ctl.get(`${r.tid}|${r.seed}`));
      // T6 needs outward evidence; its cause is the cause of the T1 item that carried the evidence in the same record
      const { priv, pub } = personVariants(t);
      const named = (r.outsider?.named || []).join('\n');
      const ev = bind.find((it) => [...priv, ...pub].some((v) => v.variant === it.text && has(named, v.variant)));
      rows.push({ ...base, metric: 'T6v5', cat: 'outsider', rule: '', variant: ev ? ev.text : `${f.v5out6} named`, sentence: ev ? sentenceOf(outward, ev.text) : '', cause: ev ? classify(ev, ctx) : '?', inTranscript: true, fixedByReplay: !fa.v5out6 });
    }
  }
  return rows;
}

export function summarise(rows) {
  const by = {};
  for (const r of rows) { const k = `${r.metric}|${r.cause}`; by[k] = by[k] || { metric: r.metric, cause: r.cause, hits: 0, fixedByReplay: 0, items: new Set() }; by[k].hits++; if (r.fixedByReplay) by[k].fixedByReplay++; by[k].items.add(r.tid); }
  return Object.values(by).map((x) => ({ ...x, items: x.items.size })).sort((a, b) => a.metric.localeCompare(b.metric) || a.cause.localeCompare(b.cause));
}

function main() {
  const rows = audit();
  const R = (s) => (REDACT ? initials(s) : s);
  const L = ['# EmberBench v5 leak audit', '', `run: \`${RUN}\` (+L4 records only; offline, no LLM)`, '',
    '`fixedByReplay` = removed by the P13 post-hoc offline replay on the spent test-v5 outputs — not a fresh confirmation, optimistic by construction.', '',
    '| metric | cause | hits | distinct items | fixed by replay |', '|---|---|---|---|---|',
    ...summarise(rows).map((s) => `| ${s.metric} | ${s.cause} | ${s.hits} | ${s.items} | ${s.fixedByReplay} |`), '',
    '| item | seed | metric | cat / rule | variant | cause | fixed | outward sentence |', '|---|---|---|---|---|---|---|---|',
    ...rows.map((r) => `| ${r.tid.replace(/^pub-/, '')} | ${r.seed} | ${r.metric} | ${r.cat}${r.rule ? ' / ' + r.rule : ''} | ${R(r.variant)} | ${r.cause} | ${r.fixedByReplay ? 'yes' : 'no'} | ${R(r.sentence).replace(/\|/g, '\\|')} |`), ''];
  if (MD) fs.writeFileSync(MD, L.join('\n'));
  console.log(L.join('\n'));
}
if (process.argv[1]?.replace(/\\/g, '/').endsWith('v5/leak-audit.mjs')) main();
