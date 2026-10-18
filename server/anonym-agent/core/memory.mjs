// Persistent de-identified knowledge store ("knowledge plane", INTERFACE.md v1 愿景).
// Only k-of-n released, de-identified items ever enter here. No speaker field, no names,
// no raw utterances, no review reasons. Approvers are kept only as salted hashes, and only to
// authorise retraction.
import { randomUUID, randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { dirname } from 'node:path';
import { sha256hex } from './crypto.mjs';
import * as gateModule from './gate/gate.mjs';

export const KINDS = ['idea', 'decision', 'todo', 'fact'];
const err = (code) => Object.assign(new Error(code), { code });

// ---------------- storage adapters ----------------
// Contract: { load() -> state|null, save(state) }. Both synchronous; state is plain JSON.
export function memoryStorage(initial = null) {
  let snap = initial ? JSON.stringify(initial) : null;
  return {
    load: () => (snap ? JSON.parse(snap) : null),
    save: (state) => { snap = JSON.stringify(state); },
    // test helper: the exact bytes that would be persisted
    dump: () => snap,
  };
}

// Whole-file JSON; atomic replace (write tmp in same dir, then rename over target).
export function jsonFileStorage(filePath) {
  return {
    filePath,
    load() {
      if (!existsSync(filePath)) return null;
      const s = readFileSync(filePath, 'utf8');
      return s.trim() ? JSON.parse(s) : null;
    },
    save(state) {
      mkdirSync(dirname(filePath), { recursive: true });
      const tmp = `${filePath}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
      try {
        writeFileSync(tmp, JSON.stringify(state, null, 1), 'utf8');
        renameSync(tmp, filePath);
      } catch (e) {
        try { unlinkSync(tmp); } catch { /* ignore */ }
        throw err('storage_failed');
      }
    },
  };
}

// ---------------- similarity (char-bigram + latin keyword) ----------------
const STOP = new Set('the a an and or of to in on for is are was were be it that this with as at by we i you they our my not but so if do does have has had can will would should could from there their them what which about just also than then very really like did last time 的 了 是 在 我 我们 你 他 她 就 都 也 和 这 那 个 一 有 不 说 上 次 什么 吗 呢'.split(' '));

export function features(s) {
  const f = new Set();
  const lower = String(s || '').toLowerCase();
  for (const w of lower.match(/[a-z][a-z0-9'-]{1,}/g) || []) if (!STOP.has(w)) f.add('w:' + w.replace(/(ing|ed|es|s)$/, ''));
  for (const run of lower.match(/[\u3400-\u9fff]+/g) || []) {
    if (run.length === 1) { if (!STOP.has(run)) f.add('c:' + run); continue; }
    for (let i = 0; i + 1 < run.length; i++) { const bg = run.slice(i, i + 2); if (!STOP.has(bg) && !(STOP.has(bg[0]) && STOP.has(bg[1]))) f.add('c:' + bg); }
  }
  for (const n of lower.match(/\d+(?:\.\d+)?%?/g) || []) f.add('n:' + n);
  return f;
}

export function similarity(a, b) {
  const fa = a instanceof Set ? a : features(a), fb = b instanceof Set ? b : features(b);
  if (!fa.size || !fb.size) return 0;
  let inter = 0;
  for (const x of fa) if (fb.has(x)) inter++;
  return inter / Math.sqrt(fa.size * fb.size);
}

// ---------------- mosaic heuristic (deterministic, offline) ----------------
// Quasi-identifier cues per roster member = their org / title / works / publicName, those strings'
// separator parts, latin words (>=4 chars) and whole CJK runs (>=2 chars). Names and aliases are NOT
// cues here (knowledge items never contain them; L4 handles direct hits). Cues shared by 2+ members
// are not distinguishing and are discarded.
const CUE_STOP = new Set('head lead senior junior chief deputy manager director member staff team group department office of and the for with from'.split(' '));
function memberCues(p) {
  const out = new Set();
  for (const v of [p.org, p.title, p.publicName, ...(p.works || [])]) {
    if (!v) continue;
    const s = String(v).trim().toLowerCase();
    if (s.length >= 2) out.add(s);
    for (const part of s.split(/\s*[\/／,，、&]\s*|\s+(?:and|兼)\s+|兼/)) if (part.trim().length >= 2) out.add(part.trim());
    for (const w of s.match(/[a-z][a-z0-9-]{3,}/g) || []) if (!CUE_STOP.has(w)) out.add(w);
    for (const r of s.match(/[\u3400-\u9fff]{2,}/g) || []) out.add(r);
  }
  return out;
}
const cueHit = (text, cue) => (/^[\x00-\x7f]+$/.test(cue)
  ? new RegExp(`\\b${cue.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'i').test(text)
  : text.includes(cue));

// Returns Map(index -> confidence) of items to drop. Rule: for one member, if the result set's items
// together carry >= 2 distinct cues, keep only the best-ranked cue-bearing item and drop the rest
// (a single item carrying >= 2 cues on its own is dropped too).
export function mosaicHeuristic(texts, roster = []) {
  const cues = roster.map((p) => memberCues(p));
  const count = new Map();
  for (const set of cues) for (const c of set) count.set(c, (count.get(c) || 0) + 1);
  const drop = new Map();
  cues.forEach((set) => {
    const own = [...set].filter((c) => count.get(c) === 1);
    if (!own.length) return;
    const hits = texts.map((t) => new Set(own.filter((c) => cueHit(String(t).toLowerCase(), c))));
    const union = new Set(hits.flatMap((h) => [...h]));
    if (union.size < 2) return;
    const conf = Math.min(1, 0.5 + 0.2 * union.size);
    const bearing = hits.map((h, i) => [i, h]).filter(([, h]) => h.size);
    bearing.forEach(([i, h], rank) => {
      if (rank === 0 && h.size < 2) return; // keep the best-ranked single-cue item
      drop.set(i, Math.max(drop.get(i) || 0, conf));
    });
  });
  return drop;
}

// ---------------- the store (one per circle) ----------------
// createMemory({ circleId, data?, storage?, roster?, llm?, gate?, clock? }) -> mem
//   data:    snapshot from mem.toJSON() to restore (ignored when storage.load() returns a snapshot).
//   storage: optional adapter { load(), save(snapshot) }; loaded on create, saved after each mutation.
//   roster:  default roster (array or () => array) for recallForOutput.
export function createMemory({ circleId, data = null, storage = null, roster = null, llm = null, gate = null, clock = () => Date.now() } = {}) {
  if (circleId == null || String(circleId) === '') throw err('bad_circle');
  circleId = String(circleId);
  const g = gate || gateModule;
  const loaded = (storage && storage.load()) || data || null;
  let state = { version: 1, circleId, items: [], releases: [] };
  if (loaded) {
    if (loaded.circleId != null && String(loaded.circleId) !== circleId) throw err('circle_mismatch');
    state.items = Array.isArray(loaded.items) ? structuredClone(loaded.items) : [];
    state.releases = Array.isArray(loaded.releases) ? structuredClone(loaded.releases) : [];
  }
  const persist = () => { if (storage) storage.save(snapshot()); };
  const snapshot = () => structuredClone(state);
  const approverHash = (memberId) => sha256hex(`anonym-approver:${circleId}:${memberId}`);
  const live = () => state.items.filter((it) => !it.retracted);
  const pub = (it) => ({ id: it.id, circleId: it.circleId, text: it.text, kind: it.kind, sid: it.sid, releasedAt: it.releasedAt, approvals: it.approvals });
  const tombView = (it) => ({ id: it.id, retracted: true, sid: it.sid, retractedAt: it.retractedAt });

  // addRelease({ sid, draftId, approvals, k, items:[{id?, text, kind?}], approverIds?, releasedAt? }) -> added items
  function addRelease({ sid, draftId, approvals, k, items, approverIds = [], releasedAt } = {}) {
    if (sid == null) throw err('bad_release');
    const at = releasedAt ?? clock();
    const made = [];
    for (const x of items || []) {
      const text = String(x?.text ?? '').trim();
      if (!text) continue;
      const kind = KINDS.includes(x?.kind) ? x.kind : 'idea';
      // Explicit field whitelist: speaker / reason / guess / flags on the input are never stored.
      made.push({ id: randomUUID(), circleId, text, kind, sid: String(sid), releasedAt: at, approvals: Number(approvals) || 0 });
    }
    state.items.push(...made);
    state.releases.push({
      releaseId: randomUUID(), sid: String(sid), draftId: String(draftId ?? ''), releasedAt: at,
      k: Number(k) || null, approvals: Number(approvals) || 0, itemIds: made.map((m) => m.id),
      approverHashes: [...new Set((approverIds || []).map(String))].map(approverHash),
    });
    persist();
    return made.map(pub);
  }

  // recall(q, { limit=5 }) -> live items ranked by char-bigram + latin-keyword overlap (score attached).
  function recall(query, { limit = 5 } = {}) {
    const q = features(query);
    return live()
      .map((it) => ({ it, s: similarity(q, features(it.text)) }))
      .filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s || b.it.releasedAt - a.it.releasedAt)
      .slice(0, Math.max(0, limit))
      .map((x) => ({ ...pub(x.it), score: Number(x.s.toFixed(4)) }));
  }

  // ALWAYS async. Outward recall: the combined result set is mosaic-checked (deterministic heuristic)
  // and then passed through Gate L4 (verifyClaims) against the roster. Attributable items are DROPPED
  // (no merging). Returned array carries a non-enumerable `.flags` = [{itemId, reason:'mosaic',
  // confidence}] for dropped items; kept items carry `flags: []` (or flags of L4 risk under threshold).
  // reason/guess from the attacker are never returned (may name an attendee).
  async function recallForOutput(query, { limit = 5, roster: r = null, llm: l = llm, flagThreshold = 0.7, threshold = 0.5 } = {}) {
    const rost = r || (typeof roster === 'function' ? roster() : roster) || [];
    const cand = recall(query, { limit });
    const dropped = new Map();
    for (const [i, confidence] of mosaicHeuristic(cand.map((c) => c.text), rost)) dropped.set(i, confidence);
    const survivors = cand.map((c, i) => i).filter((i) => !dropped.has(i));
    const kept = new Map();
    if (survivors.length) {
      const v = await runVerify(survivors.map((i) => cand[i].text), rost, { llm: l, threshold, flagThreshold });
      survivors.forEach((ci, j) => {
        const res = v[j];
        if (res == null || res === 'DROP' || res.text === 'DROP' || !String(res.text ?? '').trim()) { dropped.set(ci, 1); return; }
        const conf = Number(res.confidence);
        if (res.risk && (!Number.isFinite(conf) || conf >= flagThreshold)) { dropped.set(ci, Number.isFinite(conf) ? conf : 1); return; }
        kept.set(ci, { text: String(res.text), flags: res.risk ? [{ itemId: cand[ci].id, reason: 'mosaic', confidence: Number(conf.toFixed(3)) }] : [] });
      });
    }
    const flags = [...dropped].sort((a, b) => a[0] - b[0]).map(([i, c]) => ({ itemId: cand[i].id, reason: 'mosaic', confidence: Number(Number(c).toFixed(3)) }));
    const items = cand.map((c, i) => [c, i]).filter(([, i]) => kept.has(i)).map(([c, i]) => ({ ...c, text: kept.get(i).text, flags: kept.get(i).flags }));
    Object.defineProperty(items, 'flags', { value: flags, enumerable: false });
    return items;
  }

  async function runVerify(texts, rost, opts) {
    if (typeof g.verifyClaims === 'function') {
      const out = await g.verifyClaims(texts, rost, { ...opts, mock: !opts.llm });
      const arr = Array.isArray(out) ? out : out?.items;
      if (!Array.isArray(arr) || arr.length !== texts.length) throw err('gate_failed'); // fail closed
      return arr.map((x) => (typeof x === 'string' ? (x === 'DROP' ? 'DROP' : { text: x }) : x));
    }
    // Fallback until Gate v2 exports verifyClaims: L4 verify with one section per claim (topic = index).
    const { verify } = await import('./gate/l4.mjs');
    const sections = texts.map((t, i) => ({ topic: String(i), claims: [t] }));
    const v = await verify(sections, rost, { mock: !opts.llm, llm: opts.llm, stats: { calls: 0, promptTokens: 0, completionTokens: 0 }, threshold: opts.threshold, flagThreshold: opts.flagThreshold });
    const byTopic = new Map(v.sections.map((s) => [s.topic, s.claims[0]]));
    return texts.map((t, i) => { const c = byTopic.get(String(i)); return !c ? 'DROP' : typeof c === 'string' ? { text: c } : c; });
  }

  // retract(itemId, by?) -> bool. false if unknown / already retracted / `by` given but not an approver
  // of that release (when approver hashes are recorded). `by` omitted = caller already authorised.
  function retract(itemId, by) {
    const idx = state.items.findIndex((x) => x.id === itemId);
    if (idx < 0) return false;
    const it = state.items[idx];
    if (it.retracted) return false;
    if (by != null) {
      const rel = state.releases.find((r) => r.itemIds.includes(itemId));
      if (rel && rel.approverHashes.length && !rel.approverHashes.includes(approverHash(String(by)))) return false;
    }
    state.items[idx] = { id: it.id, circleId, retracted: true, sid: it.sid, retractedAt: clock() }; // text gone
    persist();
    return true;
  }

  const list = () => state.items.map((it) => (it.retracted ? tombView(it) : pub(it)));
  return { circleId, addRelease, recall, recallForOutput, retract, list, toJSON: snapshot };
}
