// Ember(炉灵)· 会话核心(AGENT-V2.md §4–§7)。与任何会议平台解耦(平台面见 ../PORT.md):
//   transport = { broadcast(obj), sendTo(id, obj), notifyHost(event) }   ← createEmber 由 port 构造
//     notifyHost 事件是平台中立的:{type:'active', on} / {type:'released', itemIds}(Lares 插件映射成 anon_* 信令)
//   asr       = ASR provider(open({identity,onOpen,onPartial,onFinal,onClose,onError}) → {send, finish, close})
//   llm       = { chat(messages, opts) } | null(null = 全确定性 mock 路径)
//   memory    = memory_iface.mjs 的统一接口
// 数据流:音频(只收已 ack)→ SpeakerAsr → IngestGate(L0–L2 + 假名 + L3 批)→ ledger
//        skill / LLM 只拿 ledger 访问器;出门稿 = minutes → 去假名 → L1/L2 → L4 → 审阅 → k-of-n 签名 → 放行 → 记忆
import { randomUUID } from 'node:crypto';
import { canonicalJSON, sha256hex, verifyEd25519, rawPublicKeyB64, approvalMessage } from '../core/crypto.mjs';
import { computeDraftHash, mockGeneralise } from '../core/index.mjs';
import { verifyClaims, NOTICE } from '../core/gate/gate.mjs';
import { redactPII } from '../core/gate/l1.mjs';
import { redactAffiliation } from '../core/gate/l2.mjs';
import { hasToneMarker } from '../core/gate/l3.mjs';
import { parseJSON } from '../core/gate/llm.mjs';
import { createIngestGate, stripPseudonyms } from './ingest_gate.mjs';
import { SpeakerAsr } from './asr.mjs';
import { ROUTER_PROMPT, heuristicRoute } from './skills.mjs';

export const AGENT_NAME = '炉灵'; // 炉火之灵;英文名 Ember
export const AGENT_NAME_EN = 'Ember';
const ACTIONS = new Set(['keep', 'generalise', 'cut']);
const KINDS = new Set(['idea', 'decision', 'todo', 'fact']);
const MAX_Q = 1000;
const anyId = (id) => typeof id === 'string' && id !== '';

export const ROLE_CHECK_PROMPT = `You review lines of an anonymised meeting digest before it leaves the meeting. You do NOT know who attended.
Flag a line (risk: true) if it would let a reader who knows the attendees attribute it to one person: self-revealing facts (career, life events, own team / budget / patients / books), ownership of a task by a role, a role / organisation / seniority hint, insider framing, a catchphrase, sarcasm or dialect.
Public world facts (a well-known book and its author, laws, public reports) are NOT a risk. Generic views are NOT a risk.
Output only JSON: {"results":[{"i":<line number>,"risk":true|false}]}`;
export const GENERALISE_PROMPT = 'Rewrite the given line of an anonymised meeting digest into a more general, neutral statement that keeps the idea but removes specifics (numbers, names, roles, organisations, places, dates, insider framing, distinctive wording). Keep its language. Output only JSON: {"text":"..."}';

function renderRelease(items, date) {
  const md = [NOTICE, '', `# 会议纪要 Minutes (${date})`];
  const order = ['decision', 'todo', 'idea', 'fact'];
  const label = { decision: '决定 Decisions', todo: '待办 To-dos', idea: '观点 Ideas', fact: '公共事实 Public facts' };
  const topics = [];
  const byTopic = new Map();
  for (const it of items) {
    if (!byTopic.has(it.topic)) { byTopic.set(it.topic, []); topics.push(it.topic); }
    byTopic.get(it.topic).push(it);
  }
  for (const t of topics) {
    md.push('', `## ${t}`);
    for (const k of order) {
      const xs = byTopic.get(t).filter((i) => i.kind === k);
      if (!xs.length) continue;
      md.push(`**${label[k]}**`, ...xs.map((c) => `- ${k === 'todo' ? '[ ] ' : ''}${String(c.text).replace(/\s*\n+\s*/g, ' ')}`));
    }
  }
  return md.join('\n') + '\n';
}
const isoDate = (ms) => new Date(ms).toISOString().slice(0, 10);

export class EmberSession {
  constructor({
    scopeId = null, selfId, transport, isHuman = () => true, asr = null, llm = null, memory, skills = new Map(), k = null, convenerId = null,
    clock = () => Date.now(), log = () => {}, emit = () => {}, ingestOpts = {}, onEnded = () => {}, asrOpts = {},
  }) {
    Object.assign(this, { scopeId, selfId, isHumanFn: isHuman, transport, asrProvider: asr, memory, skills, kOpt: Number.isInteger(k) && k >= 1 ? k : null, clock, log, emit, onEnded, asrOpts });
    this.sid = randomUUID();
    this.present = new Map(); // id → {name, joinedAt}
    this.acked = new Map(); // id → pubKey(原始 b64,会话内钉住,离房即忘)
    this.convenerId = convenerId;
    this.convenerFixed = Boolean(convenerId);
    this.speakers = new Map(); // id → SpeakerAsr
    this.drafts = new Map();
    this.nonces = new Set();
    this.releases = [];
    this.counts = { utterances: 0, drafts: 0, releases: 0, approvals: 0, answers: 0, droppedUnackedFrames: 0 };
    this.active = false;
    this.ended = false;
    this.receipt = null;
    this.rosterFn = () => [...this.present].map(([id, p]) => ({ id, name: p.name })).filter((p) => p.name);
    this.rawLlm = llm;
    this.llm = llm ? this._guardLlm(llm) : null;
    this.ingest = createIngestGate({ llm: this.llm, roster: this.rosterFn, clock, log, ...ingestOpts });
  }
  /// roster + orgs participants self-declared this session (lives in the ingest gate; wiped at end)
  gateRoster() { return this.ingest?.gateRoster?.() ?? this.rosterFn(); }

  // ── LLM 守卫:user 消息再过一次 L1/L2(名单名字永远进不了 LLM)──
  _guardLlm(llm) {
    const scrub = (s) => this._scrub(s);
    return Object.freeze({ chat: (messages, opts) => llm.chat(messages.map((m) => (m.role === 'system' ? m : { ...m, content: scrub(m.content) })), opts) });
  }
  _scrub(s) {
    const r = this.gateRoster();
    return redactAffiliation(redactPII(String(s ?? ''), r, { allowPublicFacts: true }), r, { allowPublicFacts: true });
  }

  isHumanId(id) { return anyId(id) && id !== this.selfId && this.isHumanFn(id) !== false; }

  // ── 生命周期 ──
  start() {
    this.active = true;
    this._host({ type: 'active', on: true });
    this.publishState();
    this.emit({ ev: 'session', sid: this.sid });
  }

  k() {
    if (this.kOpt) return this.kOpt;
    const n = Math.max(1, this.acked.size);
    return Math.min(n, Math.ceil(n / 2) + 1);
  }

  stateMsg() {
    return {
      t: 'state', sid: this.sid, k: this.k(),
      members: [...this.present].map(([id, p]) => ({ id, name: p.name ?? '', acked: this.acked.has(id) })),
      convenerId: this.convenerId, active: this.active && !this.ended,
    };
  }
  publishState() { if (!this.ended) this._bc(this.stateMsg()); }
  _bc(obj) { try { void Promise.resolve(this.transport.broadcast(obj)).catch((e) => this.log(`广播失败: ${e.message}`)); } catch (e) { this.log(`广播失败: ${e.message}`); } }
  _to(id, obj) { try { void Promise.resolve(this.transport.sendTo(id, obj)).catch(() => {}); } catch { /* */ } }
  _host(ev) { try { void Promise.resolve(this.transport.notifyHost?.(ev)).catch(() => {}); } catch (e) { this.log(`notifyHost 失败: ${e.message}`); } }
  _err(id, op, code) { this._to(id, { t: 'error', op, code }); }

  // ── 房间事件 ──
  participantJoined(id, name) {
    if (!this.isHumanId(id) || this.ended) return;
    const p = this.present.get(id);
    if (p) { if (name) p.name = name; } else this.present.set(id, { name: name ?? '', joinedAt: this.clock() });
    if (!this.convenerId) this.convenerId = id;
    this.publishState();
  }
  setName(id, name) { if (this.present.has(id) && name) { this.present.get(id).name = String(name); this.publishState(); } }

  participantLeft(id) {
    if (!this.present.has(id)) return;
    this.present.delete(id);
    this.acked.delete(id); // 钉住的公钥随离房遗忘
    this.speakers.get(id)?.close();
    this.speakers.delete(id);
    if (this.convenerId === id && !this.convenerFixed) this.convenerId = [...this.present.keys()][0] ?? null;
    if (this.present.size === 0) { void this.end('empty'); return; }
    this.publishState();
  }

  /// 音频帧:未 ack 的直接丢(不进 VAD、不送 ASR)
  onAudio(id, data, sampleRate, channels) {
    if (this.ended || !this.acked.has(id) || !this.asrProvider) { if (!this.acked.has(id)) this.counts.droppedUnackedFrames += 1; return; }
    let s = this.speakers.get(id);
    if (!s) {
      s = new SpeakerAsr({ asr: this.asrProvider, identity: id, log: this.log, onFinal: (who, text) => this.onTranscript(who, text), ...this.asrOpts });
      this.speakers.set(id, s);
    }
    s.pushFrame(data, sampleRate, channels);
  }

  /// ASR 定稿(原话)→ 立刻进 IngestGate;本函数之外没有原话的引用
  onTranscript(id, text) {
    if (this.ended || !this.acked.has(id)) return;
    if (this.ingest.utterance(id, text) > 0) this.counts.utterances += 1;
  }

  // ── 会话消息协议(Lares 上走 lares.anon data topic;见 INTERFACE.md / PORT.md)──
  async onMessage(from, msg) {
    if (this.ended || !this.isHumanId(from) || !msg || typeof msg.t !== 'string') return;
    if (!this.present.has(from)) this.participantJoined(from, '');
    const t = msg.t;
    try {
      switch (t) {
        case 'ack': return this._ack(from, msg);
        case 'ask': return await this._ask(from, msg);
        case 'skill': return await this._skill(from, msg);
        case 'review': return await this._review(from, msg);
        case 'approve': return await this._approve(from, msg);
        case 'mem_list': return await this._memList(from);
        case 'mem_retract': return await this._memRetract(from, msg);
        case 'end':
          if (from !== this.convenerId) return this._err(from, t, 'not_convener');
          return await this.end('convener');
        default: return this._err(from, t, 'unknown_op');
      }
    } catch (e) {
      this.log(`处理 ${t} 出错: ${e?.message ?? e}`);
      this._err(from, t, e?.code ?? 'internal');
    }
  }

  _needAcked(from, op) { if (!this.acked.has(from)) { this._err(from, op, 'not_acked'); return false; } return true; }

  _ack(from, msg) {
    let raw;
    try { raw = rawPublicKeyB64(msg.pubKey); } catch { return this._err(from, 'ack', 'bad_key'); }
    const known = this.acked.get(from);
    if (known && known !== raw) return this._err(from, 'ack', 'key_mismatch');
    this.acked.set(from, raw);
    this.publishState();
  }

  async _ask(from, msg) {
    if (!this._needAcked(from, 'ask')) return;
    const qRaw = String(msg.q ?? '').trim().slice(0, MAX_Q);
    if (!qRaw) return this._err(from, 'ask', 'bad_request');
    const q = this._scrub(qRaw);
    const name = await this._route(q);
    if (name === 'minutes') return this._runRelease(from, 'minutes', { q });
    return this._runRoom(from, name ?? 'answer', q, { q });
  }

  async _route(q) {
    const h = heuristicRoute(q, this.skills);
    if (!this.llm || this.skills.size < 2) return h;
    try {
      const r = await this.llm.chat([{ role: 'system', content: ROUTER_PROMPT(this.skills) }, { role: 'user', content: `REQUEST: ${q}` }], { json: true, temperature: 0, maxTokens: 60 });
      const s = String(parseJSON(r.text)?.skill ?? '');
      return this.skills.has(s) ? s : h;
    } catch { return h; }
  }

  async _skill(from, msg) {
    if (!this._needAcked(from, 'skill')) return;
    const name = String(msg.name ?? '');
    const sk = this.skills.get(name);
    if (!sk) return this._err(from, 'skill', 'unknown_skill');
    const args = msg.args && typeof msg.args === 'object' ? msg.args : {};
    const q = this._scrub(String(args.q ?? '').slice(0, MAX_Q));
    if (sk.outputs === 'release') return this._runRelease(from, name, { ...args, q });
    return this._runRoom(from, name, q, { ...args, q });
  }

  /// skill 唯一的上下文:ledger 访问器 + 只读记忆 + 守卫过的 LLM。没有原话、名单、假名映射。
  _ctx(q, args) {
    const memory = this.memory;
    return Object.freeze({
      q, args: Object.freeze({ ...args }), ledger: this.ingest.ledgerView(),
      memory: Object.freeze({ recall: (qq, o) => memory.recall(qq, o) }),
      llm: this.llm, parseJSON,
    });
  }

  async _runRoom(from, name, q, args) {
    const sk = this.skills.get(name);
    if (!sk) return this._err(from, 'ask', 'unknown_skill');
    await this.ingest.flush('skill');
    const res = await sk.run(this._ctx(q, args));
    const a = this._scrub(String(res?.text ?? '')) // 房内:允许假名;名字由 _scrub 兜底;
    this.counts.answers += 1;
    this._bc({ t: 'answer', qid: randomUUID(), q, a });
  }

  async _runRelease(from, name, args) {
    const sk = this.skills.get(name);
    if (!sk) return this._err(from, 'skill', 'unknown_skill');
    await this.ingest.flush('skill');
    const res = await sk.run(this._ctx(args.q ?? '', args));
    const draft = await this._buildDraft(Array.isArray(res?.items) ? res.items : []);
    if (!draft) return this._err(from, 'skill', 'empty');
    this._bc({ t: 'draft', draft: this._draftView(draft) });
    this._bc({ t: 'approvals', draftId: draft.draftId, count: 0, k: draft.k });
  }

  // ── 出门稿:去假名 → L1/L2 → L4(本地名单扫描 + 无名单的 LLM 角色检查 + 语气)──
  async _buildDraft(rawItems) {
    const r = this.gateRoster();
    let items = rawItems.map((x) => ({
      topic: this._scrub(stripPseudonyms(String(x?.topic ?? '').trim() || '讨论')).slice(0, 80),
      kind: KINDS.has(x?.kind) ? x.kind : 'idea',
      text: this._scrub(stripPseudonyms(String(x?.text ?? '').trim())),
      flags: Array.isArray(x?.flags) ? x.flags.filter((f) => f === 'public-fact') : [],
    })).filter((x) => x.text.replace(/[\s\p{P}]/gu, ''));
    if (!items.length) return null;
    // L4a:确定性名单扫描(本地,名单不出进程)
    const v = await verifyClaims(items.map((i) => i.text), r, { llm: null });
    items = items.map((it, j) => {
      const res = v.items[j];
      if (res === 'DROP' || !res?.text) return null;
      return { ...it, text: res.text, roleRisk: Boolean(res.risk) };
    }).filter(Boolean);
    // L4b:语气残留 → roleRisk
    for (const it of items) if (hasToneMarker(it.text)) it.roleRisk = true;
    // L4c:LLM 角色 / 自曝检查(只给条目,不给名单)
    if (this.llm && items.length) {
      try {
        const list = items.map((it, j) => `${j + 1}. ${it.text}`).join('\n');
        const out = await this.llm.chat([{ role: 'system', content: ROLE_CHECK_PROMPT }, { role: 'user', content: `LINES:\n${list}` }], { json: true, temperature: 0.1, maxTokens: 1500 });
        for (const row of parseJSON(out.text)?.results ?? []) {
          const it = items[Number(row?.i) - 1];
          if (it && (row.risk === true || row.risk === 'true')) it.roleRisk = true;
        }
      } catch (e) { this.log(`L4 角色检查失败,全部标 roleRisk: ${e.message}`); for (const it of items) it.roleRisk = true; }
    }
    const draftId = randomUUID();
    const draft = {
      draftId, sid: this.sid, createdAt: this.clock(), k: this.k(),
      items: items.map((it) => ({ id: randomUUID(), topic: it.topic, kind: it.kind, text: it.text, roleRisk: !!it.roleRisk, flags: [...new Set([...it.flags, ...(it.roleRisk ? ['role-revealing'] : [])])] })),
      approvals: new Map(), releasedAt: null,
    };
    draft.draftHash = computeDraftHash(this.sid, draftId, draft.items);
    this.drafts.set(draftId, draft);
    this.counts.drafts += 1;
    return draft;
  }

  _draftView(d) {
    return {
      draftId: d.draftId, sid: d.sid, draftHash: d.draftHash, k: d.k, notice: NOTICE,
      items: d.items.map((i) => ({ id: i.id, topic: i.topic, kind: i.kind, text: i.text, roleRisk: i.roleRisk, flags: [...i.flags] })),
    };
  }

  async _review(from, msg) {
    if (!this._needAcked(from, 'review')) return;
    const d = this.drafts.get(String(msg.draftId));
    if (!d) return this._err(from, 'review', 'unknown_draft');
    if (d.releasedAt) return this._err(from, 'review', 'already_released');
    if (!ACTIONS.has(msg.action)) return this._err(from, 'review', 'bad_action');
    const idx = d.items.findIndex((i) => i.id === msg.itemId);
    if (idx < 0) return this._err(from, 'review', 'unknown_item');
    const it = d.items[idx];
    if (msg.action === 'cut') d.items.splice(idx, 1);
    else if (msg.action === 'keep') {
      if (!it.roleRisk) return; // 签名覆盖的内容没变
      it.roleRisk = false;
      it.flags = [...it.flags.filter((f) => f !== 'role-revealing'), 'reviewed-keep'];
    } else {
      let text = null;
      if (this.llm) {
        try {
          const out = await this.llm.chat([{ role: 'system', content: GENERALISE_PROMPT }, { role: 'user', content: it.text }], { json: true, temperature: 0.3, maxTokens: 400 });
          const tt = String(parseJSON(out.text)?.text ?? '').trim();
          if (tt) text = this._scrub(stripPseudonyms(tt));
        } catch { text = null; }
      }
      it.text = text || mockGeneralise(it.text, this.gateRoster());
      it.roleRisk = false;
      it.flags = [...it.flags.filter((f) => f !== 'role-revealing'), 'generalised'];
    }
    d.draftHash = computeDraftHash(this.sid, d.draftId, d.items);
    d.approvals.clear(); // 内容变了:之前的签名作废
    this._bc({ t: 'draft', draft: this._draftView(d) });
    this._bc({ t: 'approvals', draftId: d.draftId, count: 0, k: d.k });
  }

  async _approve(from, msg) {
    if (!this._needAcked(from, 'approve')) return;
    const d = this.drafts.get(String(msg.draftId));
    if (!d) return this._err(from, 'approve', 'unknown_draft');
    if (String(msg.draftHash) !== d.draftHash) return this._err(from, 'approve', 'hash_mismatch');
    const nonce = msg.nonce;
    if (typeof nonce !== 'string' || !nonce || nonce.length > 256) return this._err(from, 'approve', 'bad_nonce');
    const pub = this.acked.get(from);
    const m = approvalMessage({ sid: this.sid, draftId: d.draftId, draftHash: d.draftHash, nonce });
    if (!verifyEd25519(pub, m, msg.sig)) return this._err(from, 'approve', 'bad_sig');
    if (this.nonces.has(nonce)) return this._err(from, 'approve', 'replay');
    this.nonces.add(nonce);
    if (d.releasedAt) return;
    if (!d.approvals.has(from)) { d.approvals.set(from, true); this.counts.approvals += 1; }
    this._bc({ t: 'approvals', draftId: d.draftId, count: d.approvals.size, k: d.k });
    if (d.approvals.size >= d.k) await this._release(d);
  }

  async _release(d) {
    const out = d.items.filter((i) => !i.roleRisk); // fail closed:没人 keep / generalise 的风险条目不出门
    const text = renderRelease(out, isoDate(d.createdAt));
    d.releasedAt = this.clock();
    this.counts.releases += 1;
    this.releases.push({ draftId: d.draftId, sha256: sha256hex(text) });
    this._bc({ t: 'released', draftId: d.draftId, text });
    let saved = [];
    try {
      saved = await this.memory.remember(out.map((i) => ({ text: i.text, kind: i.kind })), {
        sid: this.sid, draftId: d.draftId, approvals: d.approvals.size, k: d.k, approverIds: [...d.approvals.keys()],
      });
    } catch (e) { this.log(`写记忆失败: ${e.message}`); }
    const ids = (saved || []).map((x) => x?.id).filter((x) => typeof x === 'string');
    if (ids.length) this._host({ type: 'released', itemIds: ids });
    this.emit({ ev: 'released', draftId: d.draftId, items: out.length });
  }

  async _memList(from) {
    if (!this._needAcked(from, 'mem_list')) return;
    const items = (await this.memory.list()).filter((x) => !x.retracted).map((x) => ({ id: x.id, text: x.text, kind: x.kind, releasedAt: x.releasedAt }));
    this._bc({ t: 'mem', items });
  }

  async _memRetract(from, msg) {
    if (!this._needAcked(from, 'mem_retract')) return;
    const ok = await this.memory.retract(String(msg.itemId ?? ''), from);
    if (!ok) return this._err(from, 'mem_retract', 'not_allowed');
    try { await this.memory.consolidate(); } catch { /* */ }
    this._bc({ t: 'mem_retracted', itemId: String(msg.itemId) });
  }

  /// 散会:回执 → 广播 ended → 清空一切 → 关强制开关
  async end(why = 'end') {
    if (this.ended) return this.receipt;
    this.ended = true;
    for (const s of this.speakers.values()) s.close();
    this.speakers.clear();
    const counts = { utterances: this.counts.utterances, ledger: this.ingest.ledgerView().size, drafts: this.counts.drafts, releases: this.counts.releases, approvals: this.counts.approvals };
    const releases = [...this.releases];
    this.receipt = { sid: this.sid, endedAt: new Date(this.clock()).toISOString(), reason: why, counts, releases, sha256: sha256hex(canonicalJSON({ sid: this.sid, counts, releases })) };
    this.ingest.wipe();
    for (const d of this.drafts.values()) { for (const i of d.items) i.text = ''; d.items.length = 0; d.approvals.clear(); }
    this.drafts.clear();
    this.nonces.clear();
    this.acked.clear();
    this.active = false;
    this._bc({ t: 'ended', receipt: this.receipt });
    this._host({ type: 'active', on: false });
    this.emit({ ev: 'ended', reason: why });
    try { await this.onEnded(this.receipt); } catch { /* */ }
    return this.receipt;
  }
}

/// 把会话挂到平台 port 的事件面(真 Lares 房间与测试 FakePort 同一套;事件名见 ../PORT.md)
export function wirePort(session, port) {
  port.on('audio', (id, data, rate, ch) => session.onAudio(id, data, rate, ch));
  port.on('name', (id, name) => { if (session.present.has(id)) session.setName(id, name); else session.participantJoined(id, name); });
  port.on('joined', (id, name) => session.participantJoined(id, name ?? port.nameOf?.(id) ?? ''));
  port.on('left', (id) => session.participantLeft(id));
  port.on('message', (id, msg) => { void session.onMessage(id, msg); });
  // 可选的文字入口:平台自己出带说话人的定稿转写(如 Zoom RTMS)时,port.transcripts === true。
  // 与 ASR onFinal 走同一个 onTranscript:未 ack 的丢、过 IngestGate(L0–L3 + 假名)进 ledger,原话不留。
  if (port.transcripts === true) port.on('transcript', (id, text) => session.onTranscript(id, String(text ?? '')));
}