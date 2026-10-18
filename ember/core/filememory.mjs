// File-based, non-vector circle memory (docs/plans/chatham/05-memory-research.md §3).
// Source of truth: items/YYYY-MM.jsonl + releases.jsonl. Everything else (topics/, meetings/,
// links.json, MEMORY.md) is derived and can be deleted and rebuilt from the items at any time.
// Rules: released text is never rewritten; derived lines cite [i:<id>]; log.jsonl carries no text and
// no retractor identity; no speaker/member fields anywhere (only opaque approver hashes in releases.jsonl).
// All writes are tmp + rename. Mutations are serialised through one in-process promise queue.
import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, existsSync, mkdirSync, unlinkSync, readdirSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { sha256hex } from './crypto.mjs';
import { features, similarity, mosaicHeuristic, KINDS } from './memory.mjs';
import { chatJSON } from './gate/llm.mjs';
import * as gateModule from './gate/gate.mjs';

export const MAX_TEXT = 300;
export const MAX_LIVE = 5000;
const MAX_TOPICS = 40;
const FULL_TOKENS = 30000;
const BM25_CANDIDATES = 40;
const MEMORY_MAX_LINES = 150;
const MEMORY_MAX_BYTES = 8 * 1024;
const KIND_TITLE = { decision: '决定', todo: '待办', idea: '想法', fact: '事实' };
const KIND_SLUG = { decision: 'decisions', todo: 'todos', idea: 'ideas', fact: 'facts' };
const err = (code) => Object.assign(new Error(code), { code });
// Citation ids in text: tolerates [i:a][i:b], [i:a, b], [i:a，i:b].
const citedIds = (s) => [...String(s).matchAll(/\[i:([^\]]+)\]/g)].flatMap((m) => m[1].split(/[,，;；\s]+/).map((x) => x.replace(/^i:/, '').trim()).filter(Boolean));

// ---------------- fs helpers ----------------
function writeAtomic(p, data) {
  mkdirSync(dirname(p), { recursive: true });
  const tmp = `${p}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try { writeFileSync(tmp, data, 'utf8'); renameSync(tmp, p); } catch (e) {
    try { unlinkSync(tmp); } catch { /* ignore */ }
    throw err('storage_failed');
  }
}
const readText = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };
function readJsonl(p) {
  const out = [];
  for (const line of readText(p).split(/\r?\n/)) { if (!line.trim()) continue; try { out.push(JSON.parse(line)); } catch { /* skip corrupt line */ } }
  return out;
}
const toJsonl = (rows) => rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : '');
const appendJsonlAtomic = (p, rows) => writeAtomic(p, readText(p) + toJsonl(rows));
const listFiles = (d) => { try { return readdirSync(d).filter((f) => !f.endsWith('.tmp')); } catch { return []; } };
const monthOf = (t) => new Date(Number(t) || 0).toISOString().slice(0, 7);
const dayOf = (t) => new Date(Number(t) || 0).toISOString().slice(0, 10);
const safeName = (s) => String(s).replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 80) || '_';
const estTokens = (s) => { const t = String(s); const cjk = (t.match(/[\u3400-\u9fff]/g) || []).length; return cjk + Math.ceil((t.length - cjk) / 4); };

// Loads items/*.jsonl -> Map(id -> record) in file order (live records and tombstones).
function loadItems(dir) {
  const map = new Map();
  for (const f of listFiles(join(dir, 'items')).filter((f) => f.endsWith('.jsonl')).sort()) {
    for (const r of readJsonl(join(dir, 'items', f))) if (r && r.id) map.set(r.id, { ...r, _shard: f });
  }
  return map;
}

// ---------------- BM25 over features() (CJK bigrams + latin word stems + numbers) ----------------
function buildIndex(items) {
  const docs = items.map((it) => ({ it, f: features(it.text) }));
  const df = new Map();
  for (const d of docs) for (const t of d.f) df.set(t, (df.get(t) || 0) + 1);
  const avgdl = docs.reduce((s, d) => s + d.f.size, 0) / (docs.length || 1) || 1;
  return { docs, df, avgdl, N: docs.length };
}
function bm25(index, query, { k1 = 1.2, b = 0.75, boost = null } = {}) {
  const qf = features(query);
  if (!qf.size) return [];
  const out = [];
  for (const d of index.docs) {
    let s = 0;
    for (const t of qf) {
      if (!d.f.has(t)) continue;
      const n = index.df.get(t) || 0;
      const idf = Math.log(1 + (index.N - n + 0.5) / (n + 0.5));
      s += idf * (1 * (k1 + 1)) / (1 + k1 * (1 - b + b * d.f.size / index.avgdl));
    }
    if (s > 0) out.push({ it: d.it, s: boost ? s * boost(d.it) : s });
  }
  return out.sort((x, y) => y.s - x.s || (y.it.releasedAt || 0) - (x.it.releasedAt || 0));
}
function kindBoost(q) {
  const s = String(q || '').toLowerCase();
  const wantTodo = /待办|谁负责|要做|任务|跟进|todo|action item|follow.?up/.test(s);
  const wantDecision = /决定|定了|决议|结论|拍板|decid|decision|agreed/.test(s);
  return (it) => ((wantTodo && it.kind === 'todo') || (wantDecision && it.kind === 'decision') ? 1.2 : 1);
}

// readReleasedKnowledge(dir, q, {limit}) — sync, read-only, no LLM. q='' -> all live items, newest first.
export function readReleasedKnowledge(dir, q = '', { limit = 5 } = {}) {
  if (!dir || !existsSync(dir)) return [];
  const live = [...loadItems(dir).values()].filter((r) => !r.retracted && typeof r.text === 'string');
  const view = (r) => ({ id: r.id, text: r.text, kind: r.kind, sid: r.sid, draftId: r.draftId ?? '', releasedAt: r.releasedAt, approvals: r.approvals });
  if (!String(q ?? '').trim()) return live.sort((a, b) => (b.releasedAt || 0) - (a.releasedAt || 0)).map(view);
  return bm25(buildIndex(live), q, { boost: kindBoost(q) }).slice(0, Math.max(0, limit)).map((x) => view(x.it));
}

// ---------------- residue helpers (retraction) ----------------
const windows = (t, n = 8) => { const s = String(t); if (s.length <= n) return [s]; const w = []; for (let i = 0; i + n <= s.length; i++) w.push(s.slice(i, i + n)); return w; };
const distinctiveNumbers = (t) => (String(t).match(/\d+(?:\.\d+)?%?/g) || []).filter((n) => n.replace(/\D/g, '').length >= 2 || n.includes('%'));
// Dates, epoch timestamps and ids are structural (not derived from T) and are ignored by the number check.
export const scrubStructural = (s) => String(s).replace(/\d{4}-\d{2}-\d{2}(?:T[\d:.]+Z)?/g, ' ').replace(/"\w+":\d{9,}/g, ' ').replace(/i_[0-9a-f]+/g, ' ');
function residueHits(content, T, { allow = '' } = {}) {
  const c = String(content);
  const cn = scrubStructural(c);
  const hits = [];
  if (T && c.includes(T)) hits.push('text');
  for (const w of windows(T)) if (w.trim().length >= 4 && c.includes(w) && !allow.includes(w)) { hits.push('substr'); break; }
  for (const n of distinctiveNumbers(T)) if (new RegExp(`(^|[^\\d.])${n.replace(/[.%]/g, '\\$&')}(?![\\d])`).test(cn) && !allow.includes(n)) { hits.push('number'); break; }
  return hits;
}

// ---------------- the store ----------------
export function createFileMemory({ dir, circleId, roster = null, llm = null, clock = () => Date.now(), gate = null, maxItems = MAX_LIVE } = {}) {
  if (!dir) throw err('bad_dir');
  if (circleId == null || String(circleId) === '') throw err('bad_circle');
  const cid = String(circleId);
  const g = gate || gateModule;
  mkdirSync(join(dir, 'items'), { recursive: true });
  const P = {
    releases: join(dir, 'releases.jsonl'), links: join(dir, 'links.json'), log: join(dir, 'log.jsonl'),
    memory: join(dir, 'MEMORY.md'), topics: join(dir, 'topics'), meetings: join(dir, 'meetings'), staging: join(dir, '.staging'),
  };
  const items = loadItems(dir);
  const releases = readJsonl(P.releases);
  let links = (() => { try { return JSON.parse(readText(P.links)); } catch { return null; } })() || {};
  const normLinks = () => {
    links = { topics: links.topics || {}, assign: links.assign || {}, dupOf: links.dupOf || {}, supersedes: links.supersedes || {}, closedBy: links.closedBy || {}, flagged: links.flagged || [], lastConsolidated: links.lastConsolidated || null };
  };
  normLinks();
  let index = null;
  let queue = Promise.resolve();
  const serial = (fn) => { const p = queue.then(fn); queue = p.catch(() => {}); return p; };

  const rosterOf = (r) => r || (typeof roster === 'function' ? roster() : roster) || [];
  const approverHash = (memberId) => sha256hex(`anonym-approver:${cid}:${memberId}`);
  const live = () => [...items.values()].filter((r) => !r.retracted);
  const liveById = (id) => { const r = items.get(id); return r && !r.retracted ? r : null; };
  const pub = (r) => ({ id: r.id, circleId: cid, text: r.text, kind: r.kind, sid: r.sid, releasedAt: r.releasedAt, approvals: r.approvals });
  const tomb = (r) => ({ id: r.id, retracted: true, sid: r.sid, retractedAt: r.retractedAt });
  const disk = (r) => (r.retracted ? tomb(r) : { id: r.id, kind: r.kind, text: r.text, sid: r.sid, draftId: r.draftId ?? '', releasedAt: r.releasedAt, approvals: r.approvals });
  const log = (row) => appendJsonlAtomic(P.log, [{ t: clock(), ...row }]);
  const saveLinks = (path = P.links) => writeAtomic(path, JSON.stringify(links, null, 1));
  const writeShard = (shard) => writeAtomic(join(dir, 'items', shard), toJsonl([...items.values()].filter((r) => r._shard === shard).map(disk)));
  const getIndex = () => (index ||= buildIndex(live()));
  const names = (rost) => rost.flatMap((p) => [p.name, ...(p.aliases || [])]).filter((s) => s && String(s).length >= 2).map(String);
  const mentionsName = (text, rost) => { const t = String(text).toLowerCase(); return names(rost).some((n) => t.includes(n.toLowerCase())); };

  // ---------- derived renderers ----------
  function renderMeeting(sid) {
    const its = live().filter((r) => r.sid === sid).sort((a, b) => a.releasedAt - b.releasedAt);
    if (!its.length) return null;
    const date = dayOf(its[0].releasedAt);
    const out = ['---', `sid: ${JSON.stringify(sid)}`, `date: ${date}`, `sources: [${its.map((r) => r.id).join(', ')}]`, `generatedAt: ${new Date(clock()).toISOString()}`, '---',
      `# ${date} 会议纪要(去名 · 经放行)`];
    for (const k of KINDS) {
      const ks = its.filter((r) => r.kind === k);
      if (!ks.length) continue;
      out.push(`## ${KIND_TITLE[k]}`, ...ks.map((r) => `- ${r.text} [i:${r.id}]`));
    }
    return out.join('\n') + '\n';
  }
  const meetingPath = (sid) => join(P.meetings, `${safeName(sid)}.md`);
  function writeMeeting(sid) {
    const md = renderMeeting(sid);
    if (md) writeAtomic(meetingPath(sid), md); else rmSync(meetingPath(sid), { force: true });
  }

  const topicItems = (slug) => live().filter((r) => links.assign[r.id] === slug).sort((a, b) => a.releasedAt - b.releasedAt);
  const annotate = (r) => [links.dupOf[r.id] && `(dup of ${links.dupOf[r.id]})`, links.supersedes[r.id] && `(supersedes ${links.supersedes[r.id]})`, links.closedBy[r.id] && `(closed by ${links.closedBy[r.id]})`].filter(Boolean).join(' ');

  // Summary is generated from scratch from the topic's current items only (never the old summary).
  async function genSummary(slug, its, { avoid = null, rost, l = llm } = {}) {
    if (!l || !its.length) return { text: null, gate: 'skip' };
    const ids = new Set(its.map((r) => r.id));
    let s;
    try {
      const { data } = await chatJSON(l, [
        { role: 'system', content: '你为一个匿名圈子的记忆库写主题摘要。只能使用给出的条目，不得猜测或提及任何人、身份、单位、职务。摘要不超过120字，中文，每一句末尾用 [i:<id>] 引用来源条目。输出 JSON：{"summary":"..."}' },
        { role: 'user', content: `主题：${links.topics[slug]?.title || slug}\n条目：\n${its.map((r) => `[i:${r.id}] (${r.kind}, ${dayOf(r.releasedAt)}) ${r.text}`).join('\n')}` },
      ], { temperature: 0.2, maxTokens: 1024 });
      s = String(data?.summary ?? '').replace(/\r/g, '').trim();
    } catch { return { text: null, gate: 'llm-fail' }; }
    if (!s || s.length > 240) return { text: null, gate: 'invalid' };
    const cited = citedIds(s);
    const lines = s.split('\n').filter((x) => x.trim());
    if (!cited.length || cited.some((id) => !ids.has(id)) || lines.some((x) => !/\[i:[^\]]+\]/.test(x))) return { text: null, gate: 'invalid' };
    const sentences = s.split(/(?<=[。！？!?；;])|\n/).map((x) => x.trim()).filter(Boolean);
    if (mentionsName(s, rost) || mosaicHeuristic(sentences, rost).size || mosaicHeuristic([s], rost).size) return { text: null, gate: 'mosaic-fail' };
    if (avoid && (residueHits(s, avoid).length || similarity(s, avoid) >= 0.35)) return { text: null, gate: 'residue-fail' };
    return { text: lines.join('\n'), gate: 'pass' };
  }
  function renderTopic(slug, summary, gateStatus) {
    const its = topicItems(slug);
    const title = links.topics[slug]?.title || slug;
    return ['---', `topic: ${slug}`, `title: ${JSON.stringify(title)}`, `sources: [${its.map((r) => r.id).join(', ')}]`, `generatedAt: ${new Date(clock()).toISOString()}`, `gate: {mosaic: ${gateStatus}}`, '---',
      '## 摘要', ...(summary ? [summary] : []), '', '## 条目',
      ...its.map((r) => `- (${r.kind}, ${dayOf(r.releasedAt)}) ${r.text} [i:${r.id}]${annotate(r) ? ' ' + annotate(r) : ''}`)].join('\n') + '\n';
  }

  function renderIndex() {
    const lv = live();
    const sids = new Map();
    for (const r of lv) { const m = sids.get(r.sid) || { n: 0, t: 0 }; m.n++; m.t = Math.max(m.t, r.releasedAt); sids.set(r.sid, m); }
    const topics = Object.keys(links.topics).map((slug) => [slug, topicItems(slug).length]).filter(([, n]) => n).slice(0, MAX_TOPICS);
    const todos = lv.filter((r) => r.kind === 'todo' && !links.closedBy[r.id]).sort((a, b) => b.releasedAt - a.releasedAt).slice(0, 15);
    const lines = ['# 圈子记忆索引(自动生成，勿手改)',
      `条目 ${lv.length} 条 · 会议 ${sids.size} 场 · 上次整理 ${links.lastConsolidated ? dayOf(links.lastConsolidated) : '从未'}`,
      '## 主题', ...topics.map(([slug, n]) => `- ${slug} ${links.topics[slug]?.title || slug}(${n})`),
      '## 最近会议', ...[...sids].sort((a, b) => b[1].t - a[1].t).slice(0, 10).map(([sid, m]) => `- ${dayOf(m.t)} ${sid}(${m.n} 条)`),
      '## 未结待办', ...todos.map((r) => `- [i:${r.id}] ${r.text.slice(0, 30)}${r.text.length > 30 ? '…' : ''}`)];
    let out = lines.slice(0, MEMORY_MAX_LINES);
    while (Buffer.byteLength(out.join('\n') + '\n') > MEMORY_MAX_BYTES) out.pop();
    return out.join('\n') + '\n';
  }
  const writeIndex = () => writeAtomic(P.memory, renderIndex());

  // ---------- remember ----------
  function remember(list, { sid, draftId, approvals, k, approverHashes = [], approverIds = [] } = {}) {
    return serial(() => {
      if (sid == null) throw err('bad_release');
      const at = clock();
      let rejected = 0;
      let room = maxItems - live().length;
      const made = [];
      const recent = live().sort((a, b) => b.releasedAt - a.releasedAt).slice(0, 500);
      for (const x of list || []) {
        const text = String(x?.text ?? '').trim();
        if (!text) continue;
        if (text.length > MAX_TEXT || room <= 0) { rejected++; continue; }
        room--;
        const kind = KINDS.includes(x?.kind) ? x.kind : 'idea';
        // Explicit whitelist: speaker / reason / anything else on the input is never stored.
        const r = { id: `i_${randomBytes(6).toString('hex')}`, kind, text, sid: String(sid), draftId: String(draftId ?? ''), releasedAt: at, approvals: Number(approvals) || 0, _shard: `${monthOf(at)}.jsonl` };
        const f = features(text);
        const dup = [...made, ...recent].find((o) => o.kind === kind && similarity(f, features(o.text)) >= 0.85);
        if (dup) links.dupOf[r.id] = dup.id; // still stored: an independent release, text never merged
        made.push(r);
      }
      if (made.length) {
        for (const r of made) items.set(r.id, r);
        index = null;
        writeShard(made[0]._shard);
        const hashes = [...new Set([...(approverHashes || []).map(String), ...[...new Set((approverIds || []).map(String))].map(approverHash)])];
        appendJsonlAtomic(P.releases, [{ draftId: String(draftId ?? ''), sid: String(sid), releasedAt: at, approvals: Number(approvals) || 0, k: Number(k) || null, approverHashes: hashes, itemIds: made.map((r) => r.id) }]);
        releases.push({ draftId: String(draftId ?? ''), sid: String(sid), releasedAt: at, approvals: Number(approvals) || 0, k: Number(k) || null, approverHashes: hashes, itemIds: made.map((r) => r.id) });
        // write-time mosaic check (weak: flag only, the Gate already released these)
        const same = live().filter((r) => r.sid === String(sid));
        const flagged = new Set(links.flagged);
        for (const i of mosaicHeuristic(same.map((r) => r.text), rosterOf()).keys()) flagged.add(same[i].id);
        links.flagged = [...flagged];
        saveLinks();
        writeMeeting(String(sid));
        writeIndex();
        log({ op: 'remember', ids: made.map((r) => r.id), sid: String(sid), rejected });
      } else if (rejected) log({ op: 'remember', ids: [], sid: String(sid), rejected });
      const out = made.map(pub);
      Object.defineProperty(out, 'rejected', { value: rejected, enumerable: false });
      return out;
    });
  }

  // ---------- recall ----------
  function recall(q, { limit = 5 } = {}) {
    const kb = kindBoost(q);
    return bm25(getIndex(), q, { boost: (it) => kb(it) * (Object.values(links.supersedes).includes(it.id) ? 0.5 : 1) })
      .slice(0, Math.max(0, limit)).map((x) => ({ ...pub(x.it), score: Number(x.s.toFixed(4)) }));
  }

  async function runVerify(texts, rost, opts) {
    if (typeof g.verifyClaims === 'function') {
      const out = await g.verifyClaims(texts, rost, { ...opts, mock: !opts.llm });
      const arr = Array.isArray(out) ? out : out?.items;
      if (!Array.isArray(arr) || arr.length !== texts.length) throw err('gate_failed');
      return arr.map((x) => (typeof x === 'string' ? (x === 'DROP' ? 'DROP' : { text: x }) : x));
    }
    throw err('gate_failed');
  }

  // Output-time check over a candidate set: mosaicHeuristic, then L4 verifyClaims. Attributable items are dropped.
  async function checkOutput(cand, { rost, l, verify = true, flagThreshold = 0.7, threshold = 0.5 }) {
    const dropped = new Map();
    for (const [i, c] of mosaicHeuristic(cand.map((c) => c.text), rost)) dropped.set(i, c);
    const survivors = cand.map((_, i) => i).filter((i) => !dropped.has(i));
    const kept = new Map();
    if (survivors.length && verify) {
      const v = await runVerify(survivors.map((i) => cand[i].text), rost, { llm: l, threshold, flagThreshold });
      survivors.forEach((ci, j) => {
        const res = v[j];
        if (res == null || res === 'DROP' || res.text === 'DROP' || !String(res.text ?? '').trim()) { dropped.set(ci, 1); return; }
        const conf = Number(res.confidence);
        if (res.risk && (!Number.isFinite(conf) || conf >= flagThreshold)) { dropped.set(ci, Number.isFinite(conf) ? conf : 1); return; }
        kept.set(ci, { text: String(res.text), flags: res.risk ? [{ itemId: cand[ci].id, reason: 'mosaic', confidence: Number(conf.toFixed(3)) }] : [] });
      });
    } else for (const i of survivors) kept.set(i, { text: cand[i].text, flags: [] });
    const flags = [...dropped].sort((a, b) => a[0] - b[0]).map(([i, c]) => ({ itemId: cand[i].id, reason: 'mosaic', confidence: Number(Number(c).toFixed(3)) }));
    const out = cand.map((c, i) => [c, i]).filter(([, i]) => kept.has(i)).map(([c, i]) => ({ ...c, text: kept.get(i).text, flags: kept.get(i).flags }));
    return { items: out, flags };
  }

  async function recallForOutput(q, { limit = 5, roster: r = null, llm: l = llm, flagThreshold = 0.7, threshold = 0.5 } = {}) {
    const { items: out, flags } = await checkOutput(recall(q, { limit }), { rost: rosterOf(r), l, flagThreshold, threshold });
    Object.defineProperty(out, 'flags', { value: flags, enumerable: false });
    return out;
  }

  // ---------- answer ----------
  const memoryIndexText = () => readText(P.memory) || renderIndex();
  async function answer(q, { ledgerContext = '', roster: r = null, verify = true, llm: l = llm, limit = 5 } = {}) {
    const rost = rosterOf(r);
    const lv = live();
    const total = lv.reduce((s, x) => s + estTokens(x.text) + 12, 0);
    const mode = total < FULL_TOKENS ? 'full' : 'bm25';
    const cands = mode === 'full' ? lv.sort((a, b) => a.releasedAt - b.releasedAt).map(pub) : recall(q, { limit: BM25_CANDIDATES });
    const candIds = new Set(cands.map((c) => c.id));
    let text = '', use = [], insufficient = false, lastError = null;
    if (l && cands.length) {
      try {
        const { data } = await chatJSON(l, [
          { role: 'system', content: '你是匿名圈子的记忆助手。只能根据给出的记忆条目回答，不得猜测或提及任何人的身份、姓名、单位、职务，也不得说明谁说过什么。先为相关条目逐条写简短 note，再作答；答案里每个事实后用 [i:<id>] 引用条目。记忆不足以回答时，明确说记忆里没有相关内容，并设 insufficient=true。输出 JSON：{"notes":[{"id":"...","note":"..."}],"use":["<id>",...],"answer":"...","insufficient":false}' },
          { role: 'user', content: `# MEMORY.md\n${memoryIndexText()}\n${ledgerContext ? `# 本场上下文\n${String(ledgerContext).slice(0, 4000)}\n` : ''}# 记忆条目\n${cands.map((c) => `[i:${c.id}] (${c.kind}, ${dayOf(c.releasedAt)}) ${c.text}`).join('\n')}\n\n# 问题\n${q}` },
        ], { temperature: 0.2, maxTokens: 2048 });
        const canon = (id) => { const s = String(id).trim().replace(/^i:/, ''); return candIds.has(s) ? s : candIds.has('i_' + s) ? 'i_' + s : s; };
        // normalise citations (the model sometimes drops the i_ prefix or groups ids) to [i:<canonical id>]
        text = String(data?.answer ?? '').trim().replace(/\[i:([^\]]+)\]/g, (_, g) => g.split(/[,，;；\s]+/).filter(Boolean).map((x) => `[i:${canon(x)}]`).join(''));
        use = [...new Set([...(Array.isArray(data?.use) ? data.use.map(canon) : []), ...citedIds(text)])].filter((id) => candIds.has(id));
        insufficient = !!data?.insufficient;
      } catch (e) { text = ''; use = []; insufficient = true; lastError = String(e?.message || e).slice(0, 200); }
    } else {
      const top = recall(q, { limit });
      use = top.map((x) => x.id);
      insufficient = !use.length;
      text = insufficient ? '记忆里没有相关内容。' : top.map((x) => `${x.text} [i:${x.id}]`).join('\n');
    }
    const byId = new Map(cands.map((c) => [c.id, c]));
    const selected = use.map((id) => byId.get(id)).filter(Boolean);
    const { items: kept, flags } = await checkOutput(selected, { rost, l, verify });
    const keptIds = new Set(kept.map((x) => x.id));
    // Remove every sentence that cites a dropped / unknown id; uncited sentences survive.
    const parts = text.split(/(?<=[。！？!?\n])/);
    let removed = false;
    const cleaned = parts.filter((s) => {
      const ids = citedIds(s);
      if (ids.some((id) => !keptIds.has(id))) { removed = ids.filter((id) => !keptIds.has(id)); return false; }
      return true;
    }).join('').trim();
    let finalText = cleaned;
    if (removed && !/\[i:/.test(cleaned)) finalText = flags.length ? '这个我不能说。' : '记忆里没有相关内容。';
    if (!finalText) { finalText = '记忆里没有相关内容。'; insufficient = true; }
    if (mentionsName(finalText, rost)) { finalText = '这个我不能说。'; }
    const res = { answer: finalText, items: kept, flags, insufficient: insufficient || (!kept.length && !!use.length), mode };
    if (lastError) Object.defineProperty(res, 'error', { value: lastError, enumerable: false });
    if (removed) Object.defineProperty(res, 'removedSentences', { value: removed, enumerable: false }); // ids only, never dropped text
    return res;
  }

  // ---------- consolidate ----------
  function validateOps(ops) {
    const applied = [], rejected = [];
    const topics = new Set(Object.keys(links.topics));
    for (const op of Array.isArray(ops) ? ops : []) {
      const o = op && typeof op === 'object' ? op : {};
      const ok = (() => {
        switch (o.op) {
          case 'new_topic': {
            const slug = String(o.topic ?? '');
            if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(slug) || topics.has(slug) || topics.size >= MAX_TOPICS) return false;
            const title = String(o.title ?? slug).trim().slice(0, 40);
            topics.add(slug); links.topics[slug] = { title: title || slug };
            return { op: 'new_topic', topic: slug, title: title || slug };
          }
          case 'assign': {
            const it = liveById(String(o.id)); const t = String(o.topic ?? '');
            if (!it || !topics.has(t)) return false;
            links.assign[it.id] = t; return { op: 'assign', id: it.id, topic: t };
          }
          case 'dup': {
            const a = liveById(String(o.id)), b = liveById(String(o.of));
            if (!a || !b || a.id === b.id || links.dupOf[b.id] === a.id) return false;
            links.dupOf[a.id] = b.id; return { op: 'dup', id: a.id, of: b.id };
          }
          case 'supersede': {
            const n = liveById(String(o.id)), old = liveById(String(o.old));
            if (!n || !old || n.id === old.id || n.kind !== old.kind || n.releasedAt < old.releasedAt) return false;
            links.supersedes[n.id] = old.id; return { op: 'supersede', id: n.id, old: old.id };
          }
          case 'close_todo': {
            const t = liveById(String(o.todo ?? o.id)), by = liveById(String(o.by));
            if (!t || !by || t.kind !== 'todo' || by.id === t.id || !(by.releasedAt > t.releasedAt)) return false;
            links.closedBy[t.id] = by.id; return { op: 'close_todo', todo: t.id, by: by.id };
          }
          default: return false;
        }
      })();
      (ok ? applied : rejected).push(ok || o);
    }
    return { applied, rejected };
  }

  async function regenerate(slugs, { avoid = null, l = llm, rost = rosterOf() } = {}) {
    // Build everything in .staging/, then rename into place.
    rmSync(P.staging, { recursive: true, force: true });
    const staged = [], removed = [];
    let summaryDropped = false;
    for (const slug of slugs) {
      const its = topicItems(slug);
      const rel = `topics/${safeName(slug)}.md`;
      if (!its.length) { removed.push(rel); continue; }
      const s = await genSummary(slug, its, { avoid, rost, l });
      if (s.gate === 'residue-fail') summaryDropped = true;
      writeAtomic(join(P.staging, rel), renderTopic(slug, s.text, s.gate));
      staged.push(rel);
    }
    writeAtomic(join(P.staging, 'links.json'), JSON.stringify(links, null, 1));
    for (const rel of staged) { mkdirSync(dirname(join(dir, rel)), { recursive: true }); renameSync(join(P.staging, rel), join(dir, rel)); }
    renameSync(join(P.staging, 'links.json'), P.links);
    for (const rel of removed) rmSync(join(dir, rel), { force: true });
    rmSync(P.staging, { recursive: true, force: true });
    return { regenerated: [...staged, ...removed], summaryDropped };
  }

  function consolidate({ force = false, llm: l = llm } = {}) {
    return serial(async () => {
      const lv = live();
      const unassigned = lv.filter((r) => !links.assign[r.id] || !links.topics[links.assign[r.id]]);
      if (!force && !unassigned.length) return { applied: [], rejected: [], regenerated: [] };
      const before = JSON.stringify(links.assign) + JSON.stringify(links.dupOf) + JSON.stringify(links.supersedes) + JSON.stringify(links.closedBy);
      let ops = [];
      if (l) {
        const total = lv.reduce((s, x) => s + estTokens(x.text), 0);
        const ctx = total < FULL_TOKENS ? lv : [...new Map([...unassigned, ...lv.sort((a, b) => b.releasedAt - a.releasedAt).slice(0, 200)].map((r) => [r.id, r])).values()];
        try {
          const { data } = await chatJSON(l, [
            { role: 'system', content: `你整理一个匿名圈子的记忆库。不得改写任何条目文本，只输出结构化 delta 操作。可用操作：{"op":"new_topic","topic":"<小写英文slug>","title":"<中文短标题>"}；{"op":"assign","id":"<条目id>","topic":"<slug>"}；{"op":"dup","id":"<条目id>","of":"<更早的同义条目id>"}；{"op":"supersede","id":"<新条目id>","old":"<被取代的同类条目id>"}；{"op":"close_todo","todo":"<待办id>","by":"<后发的、表明已完成的条目id>"}。每个未归类条目都要 assign 到一个主题，主题总数不超过 ${MAX_TOPICS}。标题不得包含人名、单位或身份信息。输出 JSON：{"ops":[...]}` },
            { role: 'user', content: `现有主题：\n${Object.entries(links.topics).map(([s, t]) => `- ${s} ${t.title}(${topicItems(s).length})`).join('\n') || '(无)'}\n\n未归类条目 id：${unassigned.map((r) => r.id).join(', ') || '(无)'}\n\n条目：\n${ctx.map((r) => `[${r.id}] (${r.kind}, ${dayOf(r.releasedAt)}${links.assign[r.id] ? ', topic=' + links.assign[r.id] : ''}) ${r.text}`).join('\n')}` },
          ], { temperature: 0.2, maxTokens: 8192 });
          ops = Array.isArray(data?.ops) ? data.ops : [];
        } catch { ops = []; }
      }
      const { applied, rejected } = validateOps(ops);
      // Deterministic fallback for anything still unassigned (or no LLM): kind-based grouping.
      for (const r of live()) {
        if (links.assign[r.id] && links.topics[links.assign[r.id]]) continue;
        const slug = KIND_SLUG[r.kind] || 'ideas';
        if (!links.topics[slug]) { if (Object.keys(links.topics).length >= MAX_TOPICS && !links.topics.misc) { links.topics.misc = { title: '其他' }; } links.topics[slug] ||= { title: KIND_TITLE[r.kind] || '想法' }; applied.push({ op: 'new_topic', topic: slug, title: links.topics[slug].title }); }
        links.assign[r.id] = slug; applied.push({ op: 'assign', id: r.id, topic: slug });
      }
      links.lastConsolidated = clock();
      const changed = before !== JSON.stringify(links.assign) + JSON.stringify(links.dupOf) + JSON.stringify(links.supersedes) + JSON.stringify(links.closedBy);
      const existing = new Set(listFiles(P.topics).map((f) => f.replace(/\.md$/, '')));
      const slugs = Object.keys(links.topics).filter((s) => force || changed || !existing.has(safeName(s)));
      const { regenerated } = await regenerate(slugs, { l });
      writeIndex(); regenerated.push('MEMORY.md');
      log({ op: 'consolidate', ops: applied.length, rejected: rejected.length, regenerated });
      return { applied, rejected, regenerated };
    });
  }

  // ---------- retract ----------
  const derivedFiles = () => [
    ...listFiles(P.topics).filter((f) => f.endsWith('.md')).map((f) => `topics/${f}`),
    ...listFiles(P.meetings).filter((f) => f.endsWith('.md')).map((f) => `meetings/${f}`),
    ...(existsSync(P.memory) ? ['MEMORY.md'] : []), ...(existsSync(P.links) ? ['links.json'] : []),
  ];
  function retract(itemId, { byHash = null, by = null } = {}) {
    return serial(async () => {
      const it = items.get(String(itemId));
      if (!it) return { ok: false, code: 'unknown' };
      if (it.retracted) return { ok: false, code: 'already_retracted' };
      const h = byHash != null ? String(byHash) : by != null ? approverHash(String(by)) : null;
      if (h != null) {
        const rel = releases.find((r) => (r.itemIds || []).includes(it.id));
        if (rel && (rel.approverHashes || []).length && !rel.approverHashes.includes(h)) return { ok: false, code: 'forbidden' };
      }
      let T = it.text; // held in memory only for the residue check
      // 1. physical removal: rewrite the shard with a text-free tombstone
      items.set(it.id, { id: it.id, retracted: true, sid: it.sid, retractedAt: clock(), _shard: it._shard });
      index = null;
      writeShard(it._shard);
      // links touching the item go away (anything it superseded becomes current again)
      const topicOf = links.assign[it.id];
      delete links.assign[it.id];
      for (const key of ['dupOf', 'supersedes', 'closedBy']) for (const [a, b] of Object.entries(links[key])) if (a === it.id || b === it.id) delete links[key][a];
      links.flagged = links.flagged.filter((x) => x !== it.id);
      // 2. every derived file citing it is deleted first (fail-closed), then rebuilt from remaining items
      const needle = `i:${it.id}`;
      const affected = new Set(derivedFiles().filter((rel) => rel === 'links.json' || readText(join(dir, rel)).includes(needle) || readText(join(dir, rel)).includes(it.id)));
      affected.add(`meetings/${safeName(it.sid)}.md`); affected.add('MEMORY.md');
      for (const rel of affected) rmSync(join(dir, rel), { force: true });
      saveLinks();
      const slugs = new Set(Object.keys(links.topics).filter((s) => affected.has(`topics/${safeName(s)}.md`)));
      if (topicOf && links.topics[topicOf]) slugs.add(topicOf);
      const { regenerated, summaryDropped } = await regenerate([...slugs]);
      for (const s of slugs) if (!topicItems(s).length) delete links.topics[s];
      for (const rel of affected) if (rel.startsWith('meetings/')) {
        const sid = live().find((r) => `meetings/${safeName(r.sid)}.md` === rel)?.sid;
        if (sid != null) writeMeeting(sid);
        regenerated.push(rel);
      }
      // 3. residue check over every derived file; summaries that fail are dropped
      const liveCorpus = live().map((r) => r.text).join('\n');
      let residueCheck = summaryDropped ? 'summary_dropped' : 'pass';
      saveLinks();
      for (const rel of derivedFiles()) {
        if (rel === 'MEMORY.md') continue;
        const content = readText(join(dir, rel));
        if (!residueHits(content, T, { allow: liveCorpus }).length) continue;
        if (rel.startsWith('topics/')) {
          const slug = Object.keys(links.topics).find((s) => `topics/${safeName(s)}.md` === rel);
          if (slug) {
            if (residueHits(links.topics[slug].title, T, { allow: liveCorpus }).length) links.topics[slug].title = slug;
            writeAtomic(join(dir, rel), renderTopic(slug, null, 'residue-fail'));
            saveLinks();
          } else rmSync(join(dir, rel), { force: true });
          residueCheck = 'summary_dropped';
          if (!regenerated.includes(rel)) regenerated.push(rel);
        } else if (rel === 'links.json') {
          for (const s of Object.keys(links.topics)) if (residueHits(links.topics[s].title, T, { allow: liveCorpus }).length) links.topics[s].title = s;
          saveLinks();
        } else residueCheck = 'residue_shared_with_live';
      }
      // 4. rebuild MEMORY.md
      writeIndex(); regenerated.push('MEMORY.md');
      T = null;
      const regen = [...new Set(regenerated)];
      log({ op: 'retract', id: it.id, regenerated: regen });
      return { ok: true, regenerated: regen, residueCheck };
    });
  }

  const list = () => [...items.values()].map((r) => (r.retracted ? tomb(r) : pub(r)))
    .sort((a, b) => (b.releasedAt ?? b.retractedAt ?? 0) - (a.releasedAt ?? a.retractedAt ?? 0));
  const toJSON = () => ({ version: 2, circleId: cid, items: [...items.values()].map((r) => (r.retracted ? { ...tomb(r), circleId: cid } : pub(r))), releases: structuredClone(releases) });

  return { circleId: cid, dir, remember, recall, recallForOutput, answer, consolidate, retract, list, toJSON, approverHash };
}
