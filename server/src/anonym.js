// 隐名之约(anonym)—— 服务器托管的隐名会话 agent,Lares 集成层。
// 规格:server/anonym-agent/INTERFACE.md「Lares 集成协议」+「v1 愿景」。核心在 anonym-agent/core/。
//
// 纪律(不可松动):
//   - 原话 / 问题 / 回答 / 草稿 / 放行文本**一律不写日志**(含 LARES_AI_LOG_TEXT 也不认);日志只记 code。
//   - 会话状态只在内存:Map circleId → st。服务器重启即焚(等同 end)。
//   - 知识面(去名、k-of-n 放行的条目)按圈持久化:DATA_DIR/anonym_memory/<cid>.json;解散圈即删。
//   - 只有注册的 v2 圈子可用;一个圈同时只有一场;圈主召集。
//
// index.js 只通过 deps 把需要的能力递进来,本模块不碰 WS 内部状态。

import path from 'node:path';
import { unlinkSync } from 'node:fs';
import { randomUUID, createHash } from 'node:crypto';
import { TokenBuckets } from './ratelimit.js';

const CORE_URL = new URL('../anonym-agent/core/index.mjs', import.meta.url);
const MEMORY_URL = new URL('../anonym-agent/core/memory.mjs', import.meta.url);

export const UTT_MAX = 2000;
export const QUESTION_MAX = 500;
const RELEASED_KEEP = 50; // 每圈内存里留最近 N 份放行文本(给 bot API /released)
const CID_FILE_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ACTIONS = new Set(['keep', 'generalise', 'cut']);
// 核心抛出的、可以原样回给客户端的错误码;其它一律 'failed'(不泄露内部信息)
const CORE_CODES = new Set([
  'ended', 'not_member', 'empty', 'empty_question', 'unknown_draft', 'already_released', 'bad_action',
  'unknown_item', 'hash_mismatch', 'bad_nonce', 'bad_key', 'key_mismatch', 'bad_sig', 'replay',
]);

const DASHSCOPE_DEFAULT = 'https://dashscope.aliyuncs.com';
const hostOf = (u) => { try { return new URL(u).hostname.toLowerCase(); } catch { return ''; } };

/**
 * 非流式 OpenAI 兼容 chat(),形状同核心注入约定:chat(messages,{json,temperature,maxTokens}) -> {text,usage,finish}。
 * 错误只带 code(llm_http_<status> / llm_timeout / llm_network),绝不带请求或响应正文。
 */
function compatChat({ baseUrl, key, model, timeoutMs, fetchImpl = fetch }) {
  const base = String(baseUrl).replace(/\/+$/, '');
  const isDashscope = /dashscope/i.test(base);
  const isDeepseek = hostOf(base) === 'api.deepseek.com';
  const m = model || (isDeepseek ? 'deepseek-flash' : 'qwen-flash');
  return async function chat(messages, { json = false, temperature = 0.3, maxTokens = 4096 } = {}) {
    const body = { model: m, messages, temperature, max_tokens: maxTokens, stream: false };
    if (json) body.response_format = { type: 'json_object' };
    if (isDashscope && /^qwen/i.test(m)) body.enable_thinking = false;
    if (isDeepseek) body.thinking = { type: 'disabled' };
    let res;
    try {
      res = await fetchImpl(`${base}/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      throw Object.assign(new Error(e?.name === 'TimeoutError' ? 'llm_timeout' : 'llm_network'), { code: 'llm_failed' });
    }
    if (!res.ok) {
      try { await res.body?.cancel?.(); } catch { /* ignore */ }
      throw Object.assign(new Error(`llm_http_${res.status}`), { code: 'llm_failed' });
    }
    let j;
    try { j = await res.json(); } catch { throw Object.assign(new Error('llm_bad_json'), { code: 'llm_failed' }); }
    const c = j?.choices?.[0];
    return { text: String(c?.message?.content ?? ''), usage: j?.usage || {}, finish: c?.finish_reason };
  };
}

/**
 * 从 env 组 LLM(复用 AI 语音助手的那组变量):
 *   LARES_AI_LLM_BASE_URL(默认 DashScope compatible-mode)/ LARES_AI_LLM_API_KEY | LARES_AI_LLM_KEY | LARES_DASHSCOPE_API_KEY
 *   LARES_AI_LLM_MODEL;主 LLM 不是 DashScope 且有 DashScope key 时,失败回退 DashScope qwen-flash。
 *   LARES_ANONYM_LLM=off → null(核心走确定性 mock)。没有任何 key → null。
 */
export function createAnonymLlm(env = process.env, { fetchImpl } = {}) {
  if (String(env.LARES_ANONYM_LLM ?? '').trim().toLowerCase() === 'off') return null;
  const dsKey = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  const dsBase = String(env.LARES_DASHSCOPE_BASE ?? DASHSCOPE_DEFAULT).replace(/\/+$/, '');
  const dsCompat = `${dsBase}/compatible-mode/v1`;
  const baseUrl = String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || dsCompat;
  const key = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim() || dsKey;
  if (!key) return null;
  const timeoutMs = Number(env.LARES_ANONYM_LLM_TIMEOUT_MS ?? 60_000);
  const primary = compatChat({ baseUrl, key, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || null, timeoutMs, fetchImpl });
  const primaryIsDashscope = /dashscope/i.test(baseUrl);
  if (primaryIsDashscope || !dsKey) return { chat: primary, name: 'primary' };
  const fallback = compatChat({ baseUrl: dsCompat, key: dsKey, model: 'qwen-flash', timeoutMs, fetchImpl });
  return {
    name: 'primary+dashscope',
    async chat(messages, opts) {
      try { return await primary(messages, opts); } catch { return fallback(messages, opts); }
    },
  };
}

/**
 * @param {object} d
 *   dataDir, env, log
 *   send(ws,msg)
 *   roomOf(cid) -> Map<userId,{name,devices:Map}>|undefined   该圈房间(不新建)
 *   isHuman(userId) -> bool                                    不算 AI 助手 / 机器人
 *   registeredCircle(cid), isOwnerFor(session,cid,ownerKey), circleAllowed(session,cid)
 *   onActiveChange(cid, active)                                会话开/关(index.js:AI 语音 reconcile 等)
 *   fanout(cid, type, data)                                    插件 webhook(直接走 plugins.fanout,绕过会话期闸门)
 *   llm?                                                        测试注入;缺省按 env 组
 */
export function createAnonym(d) {
  const log = d.log ?? console;
  const env = d.env ?? process.env;
  const llm = d.llm !== undefined ? d.llm : createAnonymLlm(env);
  const memDir = path.join(d.dataDir, 'anonym_memory');

  /** @type {Map<string, object>} circleId → 会话 */
  const sessions = new Map();
  /** @type {Map<string, object>} circleId → 知识库实例(懒加载) */
  const memories = new Map();
  /** @type {Map<string, Array<{sid,draftId,text,releasedAt}>>} 放行文本(只在内存) */
  const released = new Map();

  const rate = {
    ctl: new TokenBuckets({ capacity: 10, perSec: 0.5 }),     // start/ack/end
    utt: new TokenBuckets({ capacity: 30, perSec: 5 }),
    ask: new TokenBuckets({ capacity: 3, perSec: 0.2 }),
    draft: new TokenBuckets({ capacity: 3, perSec: 0.1 }),
    review: new TokenBuckets({ capacity: 30, perSec: 2 }),
    mem: new TokenBuckets({ capacity: 20, perSec: 1 }),
  };
  const sweeper = setInterval(() => { for (const b of Object.values(rate)) b.sweep(); }, 60_000);
  sweeper.unref?.();

  let coreMod = null, memMod = null, loadErr = null;
  const ready = Promise.all([import(CORE_URL.href), import(MEMORY_URL.href)])
    .then(([c, m]) => { coreMod = c; memMod = m; })
    .catch((e) => { loadErr = e; log.error?.(`[anonym] 核心加载失败,功能不可用: ${e?.code ?? 'load_failed'}`); });
  if (!llm) log.log?.('[anonym] 未配置 LLM key(或 LARES_ANONYM_LLM=off):核心走确定性 mock');

  const tag = (cid) => `[anonym ${String(cid).slice(0, 8)}]`;
  const isActive = (cid) => sessions.has(cid);

  // ── 房间工具 ──
  const roomOf = (cid) => d.roomOf(cid) ?? new Map();
  const humansInRoom = (cid) => [...roomOf(cid).values()].filter((m) => d.isHuman(m.userId));
  const inRoom = (session, cid) => Boolean(session.userId && session.circleId === cid && roomOf(cid).get(session.userId)?.devices?.has(session.deviceId));
  const sendMember = (member, msg) => { for (const ws of member.devices.values()) d.send(ws, msg); };
  /// 内容类广播:只发给在房且已 ack 的成员
  function toAcked(st, msg) {
    for (const m of roomOf(st.circleId).values()) if (st.acked.has(m.userId)) sendMember(m, msg);
  }
  /// 状态类广播(不含内容):发给房里所有真人,好让没 ack 的人知道有会话、要先确认
  function toRoom(cid, msg) {
    for (const m of roomOf(cid).values()) if (d.isHuman(m.userId)) sendMember(m, msg);
  }
  function stateMsg(st) {
    return {
      t: 'anon_state', circleId: st.circleId, active: true, sid: st.sid, k: st.k, convenerId: st.convenerId,
      members: humansInRoom(st.circleId).map((m) => ({ id: m.userId, name: m.name, acked: st.acked.has(m.userId) })),
    };
  }

  // ── 知识库 ──
  function memFor(cid) {
    if (!memMod || !CID_FILE_RE.test(cid)) return null;
    let mem = memories.get(cid);
    if (!mem) {
      mem = memMod.createMemory({
        circleId: cid,
        storage: memMod.jsonFileStorage(path.join(memDir, `${cid}.json`)),
        // 马赛克检查用:当前房里真人的名字(服务器只知道名字)
        roster: () => humansInRoom(cid).map((m) => ({ id: m.userId, name: m.name })),
        llm,
      });
      memories.set(cid, mem);
    }
    return mem;
  }
  const MEM_LIST_MAX = 200;
  const approverHash = (cid, uid) => createHash('sha256').update(`anonym-approver:${cid}:${uid}`, 'utf8').digest('hex');
  /// 给某个请求者看的列表:新的在前、最多 200 条;每条带按本人算好的 canRetract(不下发放行人名单)
  function listFor(mem, session, cid, ownerKey) {
    const owner = d.isOwnerFor(session, cid, ownerKey);
    const mine = approverHash(cid, session.userId);
    const byItem = new Map(); // itemId → 该放行是否记录了签名人且含本人
    for (const r of mem.toJSON().releases ?? []) {
      const has = Array.isArray(r.approverHashes) && r.approverHashes.length > 0;
      const me = has && r.approverHashes.includes(mine);
      for (const id of r.itemIds ?? []) byItem.set(id, { has, me });
    }
    const time = (it) => Number(it.releasedAt ?? it.retractedAt ?? 0) || 0;
    return mem.list()
      .map((it, i) => ({ it, i }))
      .sort((a, b) => time(b.it) - time(a.it) || b.i - a.i)
      .slice(0, MEM_LIST_MAX)
      .map(({ it }) => {
        if (it.retracted) return { id: it.id, circleId: cid, retracted: true, sid: it.sid ?? null, retractedAt: it.retractedAt ?? null };
        const rel = byItem.get(it.id);
        // 与 memory.retract 同一规则:圈主 / 该放行的签名人;放行没记签名人时任何成员都可撤
        const canRetract = owner || !rel || !rel.has || rel.me;
        return { id: it.id, circleId: cid, text: it.text, kind: it.kind, sid: it.sid, releasedAt: it.releasedAt, approvals: it.approvals, canRetract };
      });
  }

  // ── 会话生命周期 ──
  function endSession(cid, why) {
    const st = sessions.get(cid);
    if (!st) return null;
    sessions.delete(cid);
    let receipt = null;
    try { receipt = st.core.end(); } catch { /* 已结束 */ }
    st.acked.clear();
    toRoom(cid, { t: 'anon_ended', circleId: cid, receipt: receipt ? { counts: receipt.counts, sha256: receipt.sha256 } : null });
    toRoom(cid, { t: 'anon_state', circleId: cid, active: false, sid: st.sid, k: st.k, members: [], convenerId: st.convenerId });
    log.log?.(`${tag(cid)} 结束(${why})`);
    try { d.onActiveChange?.(cid, false); } catch (e) { log.error?.(`${tag(cid)} onActiveChange 出错: ${e?.code ?? 'error'}`); }
    return receipt;
  }

  function recordRelease(st, draftId, text, added) {
    const list = released.get(st.circleId) ?? [];
    list.push({ sid: st.sid, draftId, text, releasedAt: Date.now() });
    while (list.length > RELEASED_KEEP) list.shift();
    released.set(st.circleId, list);
    // 插件 webhook:只给去名的知识条目(不含说话人、不含签名人)
    if (added?.length) {
      try {
        d.fanout?.(st.circleId, 'knowledge.released', {
          circleId: st.circleId, sid: st.sid, draftId,
          items: added.map((it) => ({ id: it.id, text: it.text, kind: it.kind, sid: it.sid, releasedAt: it.releasedAt, approvals: it.approvals })),
        });
      } catch (e) { log.error?.(`${tag(st.circleId)} knowledge.released 扇出失败: ${e?.code ?? 'error'}`); }
    }
  }

  // ── WS ──
  async function handle(ws, session, msg) {
    const t = msg?.t;
    if (typeof t !== 'string' || !t.startsWith('anon_')) return false;
    const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
    const fail = (code) => { d.send(ws, { t: 'anon_error', circleId, op: t, code }); return true; };
    if (!session.userId || !session.authed) return fail('say_hello_first');
    // AI 语音助手 / 机器人身份不参与隐名之约(不能 ack、不能看知识面)
    if (!d.isHuman(session.userId)) return fail('not_allowed');
    await ready;
    if (loadErr || !coreMod) return fail('unavailable');

    switch (t) {
      // 圈子记忆:任何鉴权过的圈成员可读(不要求在房);新的在前,最多 200 条,暂不分页
      case 'anon_mem_list': {
        if (!circleId) return fail('bad_request');
        if (!d.registeredCircle(circleId)) return fail('not_registered');
        if (!d.circleAllowed(session, circleId)) return fail('not_member');
        if (rate.mem.take(session.userId) > 0) return fail('rate_limited');
        const mem = memFor(circleId);
        if (!mem) return fail('unavailable');
        d.send(ws, { t: 'anon_mem', circleId, items: listFor(mem, session, circleId, msg.ownerKey) });
        return true;
      }
      case 'anon_mem_retract': {
        if (!circleId) return fail('bad_request');
        if (!d.registeredCircle(circleId)) return fail('not_registered');
        if (!d.circleAllowed(session, circleId)) return fail('not_member');
        if (typeof msg.itemId !== 'string' || !msg.itemId || msg.itemId.length > 100) return fail('bad_request');
        if (rate.mem.take(session.userId) > 0) return fail('rate_limited');
        const mem = memFor(circleId);
        if (!mem) return fail('unavailable');
        const cur = mem.list().find((it) => it.id === msg.itemId);
        if (!cur) return fail('no_such_item');
        if (cur.retracted) return fail('already_retracted');
        // 圈主可撤任何条目;其他成员只能撤自己签过的那份放行里的(核心按签名人哈希校验)
        const owner = d.isOwnerFor(session, circleId, msg.ownerKey);
        let ok;
        try { ok = owner ? mem.retract(msg.itemId) : mem.retract(msg.itemId, session.userId); } catch (e) { log.error?.(`${tag(circleId)} retract 写盘失败: ${e?.code ?? 'error'}`); return fail('save_failed'); }
        if (!ok) return fail('not_approver');
        // 确认:发给该圈所有在线成员(房里 + 被钉在该圈的大厅连接),各自就地变墓碑 / 再拉一次
        const out = { t: 'anon_mem_retracted', circleId, itemId: msg.itemId };
        const seen = new Set();
        for (const w of d.sessionsOfCircle?.(circleId) ?? []) { seen.add(w); d.send(w, out); }
        if (!seen.has(ws)) d.send(ws, out);
        return true;
      }
      case 'anon_start': {
        if (!circleId) return fail('bad_request');
        if (!d.registeredCircle(circleId)) return fail('not_registered');
        if (!d.isOwnerFor(session, circleId, msg.ownerKey)) return fail('not_owner');
        // 加密圈的原话不该以明文到服务器 —— 托管档不支持
        if (d.isE2ee?.(circleId) === true) return fail('e2ee_circle');
        if (!inRoom(session, circleId)) return fail('not_in_room');
        if (sessions.has(circleId)) return fail('already_active');
        if (rate.ctl.take(session.userId) > 0) return fail('rate_limited');
        const n = humansInRoom(circleId).length;
        if (n < 2) return fail('too_few');
        let k = Math.min(Math.ceil(n / 2) + 1, n);
        if (msg.k !== undefined && msg.k !== null) {
          if (!Number.isInteger(msg.k) || msg.k < 2 || msg.k > n) return fail('bad_k');
          k = msg.k;
        }
        const sid = randomUUID();
        const mem = memFor(circleId);
        const st = { circleId, sid, k, convenerId: session.userId, acked: new Map(), drafting: false, lastAdded: null, core: null };
        // 包一层 memory:核心放行时自己调 addRelease,这里截下新增条目给 webhook 用
        const memProxy = mem ? {
          addRelease: (rel) => { const added = mem.addRelease(rel); st.lastAdded = added; return added; },
          recall: (...a) => mem.recall(...a),
          recallForOutput: (...a) => mem.recallForOutput(...a),
          list: (...a) => mem.list(...a),
          retract: (...a) => mem.retract(...a),
        } : null;
        // 名册 = 在房的全部真人(不论 ack 与否):他们的名字都要被 gate 去掉。是否能发言 / 审阅 / 签名由 acked 管
        const roster = humansInRoom(circleId).map((m) => ({ id: m.userId, name: m.name }));
        st.core = coreMod.createSession({ sid, roster, policy: { k }, llm, memory: memProxy });
        sessions.set(circleId, st);
        log.log?.(`${tag(circleId)} 开始 n=${n} k=${k}`);
        try { d.onActiveChange?.(circleId, true); } catch (e) { log.error?.(`${tag(circleId)} onActiveChange 出错: ${e?.code ?? 'error'}`); }
        toRoom(circleId, stateMsg(st));
        return true;
      }
      case 'anon_end': {
        const st = sessions.get(circleId);
        if (!st) return fail('no_session');
        if (!d.isOwnerFor(session, circleId, msg.ownerKey)) return fail('not_owner');
        endSession(circleId, 'owner');
        return true;
      }
    }

    // 以下都要求:有会话、本人在房
    const st = sessions.get(circleId);
    if (!st) return fail('no_session');
    if (!inRoom(session, circleId)) return fail('not_in_room');
    const uid = session.userId;
    const still = () => sessions.get(circleId) === st;

    if (t === 'anon_ack') {
      if (rate.ctl.take(uid) > 0) return fail('rate_limited');
      if (typeof msg.pubKey !== 'string' || !msg.pubKey || msg.pubKey.length > 200) return fail('bad_key');
      try {
        st.core.join({ id: uid, name: session.name ?? uid, pubKey: msg.pubKey });
      } catch (e) {
        return fail(CORE_CODES.has(e?.code) ? e.code : 'failed');
      }
      st.acked.set(uid, { name: session.name ?? uid });
      toRoom(circleId, stateMsg(st));
      return true;
    }

    // 未 ack 的人说的话不进 agent:静默丢弃(不回错,不泄露会话细节)
    if (t === 'anon_utt') {
      if (!st.acked.has(uid)) return true;
      if (msg.final !== true) return true;
      if (typeof msg.text !== 'string' || !msg.text.trim() || msg.text.length > UTT_MAX) return fail('bad_text');
      if (rate.utt.take(uid) > 0) return fail('rate_limited');
      try {
        st.core.ingest({ speakerId: uid, text: msg.text, ts: Number.isFinite(msg.ts) ? msg.ts : Date.now(), final: true });
      } catch (e) { return fail(CORE_CODES.has(e?.code) ? e.code : 'failed'); }
      return true;
    }

    if (!st.acked.has(uid)) return fail('not_acked');

    try {
      switch (t) {
        case 'anon_ask': {
          if (typeof msg.question !== 'string' || !msg.question.trim() || msg.question.length > QUESTION_MAX) return fail('bad_question');
          if (rate.ask.take(uid) > 0) return fail('rate_limited');
          const { answer } = await st.core.ask({ askerId: uid, question: msg.question });
          if (!still()) return true;
          toAcked(st, { t: 'anon_answer', circleId, askerName: session.name ?? uid, question: msg.question, answer });
          return true;
        }
        case 'anon_draft': {
          if (st.drafting) return fail('busy');
          if (rate.draft.take(uid) > 0) return fail('rate_limited');
          st.drafting = true;
          let draft;
          try { draft = await st.core.draft({}); } finally { st.drafting = false; }
          if (!still()) return true;
          toAcked(st, { t: 'anon_draft', circleId, draft });
          return true;
        }
        case 'anon_review': {
          if (typeof msg.draftId !== 'string' || typeof msg.itemId !== 'string' || !ACTIONS.has(msg.action)) return fail('bad_request');
          if (rate.review.take(uid) > 0) return fail('rate_limited');
          const draft = await st.core.review({ draftId: msg.draftId, memberId: uid, itemId: msg.itemId, action: msg.action });
          if (!still()) return true;
          toAcked(st, { t: 'anon_draft', circleId, draft });
          return true;
        }
        case 'anon_approve': {
          for (const f of ['draftId', 'draftHash', 'nonce', 'sig']) {
            if (typeof msg[f] !== 'string' || !msg[f] || msg[f].length > 512) return fail('bad_request');
          }
          if (rate.review.take(uid) > 0) return fail('rate_limited');
          st.lastAdded = null;
          const r = st.core.approve({ draftId: msg.draftId, draftHash: msg.draftHash, memberId: uid, nonce: msg.nonce, sig: msg.sig });
          toAcked(st, { t: 'anon_approvals', circleId, draftId: msg.draftId, count: r.approvals, k: r.k });
          if (r.released) {
            const rel = st.core.released(msg.draftId);
            if (rel && !(released.get(circleId) ?? []).some((x) => x.draftId === msg.draftId)) {
              recordRelease(st, msg.draftId, rel.text, st.lastAdded);
              toAcked(st, { t: 'anon_released', circleId, draftId: msg.draftId, text: rel.text });
              log.log?.(`${tag(circleId)} 放行 items=${rel.items.length}`);
            }
          }
          st.lastAdded = null;
          return true;
        }
        default:
          return fail('unknown_op');
      }
    } catch (e) {
      const code = CORE_CODES.has(e?.code) ? e.code : (e?.code === 'llm_failed' ? 'llm_failed' : 'failed');
      if (code === 'failed' || code === 'llm_failed') log.error?.(`${tag(circleId)} ${t} 失败: ${e?.code ?? 'error'}`); // 只记 code
      return fail(code);
    }
  }

  // ── 房间钩子 ──
  /// 有人进房(index.js joinCircle 之后调):补推会话状态;ack 过的人重新标记在场
  function onJoin(ws, session, circleId) {
    const st = sessions.get(circleId);
    if (!st || !d.isHuman(session.userId)) return;
    // 后进房的人也进名册(名字要被去掉);ack 过的人重新标记在场
    try { st.core.join({ id: session.userId, name: session.name ?? session.userId }); } catch { /* ignore */ }
    toRoom(circleId, stateMsg(st));
  }
  /// 某人整个出房(所有设备都走了)之后调:房里没真人了 → 自动结束
  function onLeave(circleId, userId) {
    const st = sessions.get(circleId);
    if (!st) return;
    // 整个出房 = 退出本场:客户端离房即焚钥匙,回来要重新同意并登记新公钥;
    // 不解绑旧钥匙的话重新 ack 会 key_mismatch,且服务器仍当他已 ack(收他的话却签不了名)
    try { st.core.leave(userId, { forgetKey: true }); } catch { /* ignore */ }
    st.acked.delete(userId);
    if (humansInRoom(circleId).length === 0) { endSession(circleId, 'empty'); return; }
    toRoom(circleId, stateMsg(st));
  }
  /// 圈子解散:结束会话、删知识库文件、清放行文本
  function onCircleDeleted(circleId) {
    endSession(circleId, 'circle_deleted');
    memories.delete(circleId);
    released.delete(circleId);
    if (CID_FILE_RE.test(circleId)) {
      try { unlinkSync(path.join(memDir, `${circleId}.json`)); } catch (e) { if (e?.code !== 'ENOENT') log.error?.(`${tag(circleId)} 删除知识库失败: ${e?.code ?? 'error'}`); }
    }
  }

  // ── bot API 用 ──
  const releasedOf = (circleId) => (released.get(circleId) ?? []).map((x) => ({ ...x }));
  async function knowledgeOf(circleId, q, { limit = 5 } = {}) {
    await ready;
    const mem = memFor(circleId);
    if (!mem) return [];
    const items = await mem.recallForOutput(q, { limit });
    return items.map((it) => ({ id: it.id, text: it.text, kind: it.kind, sid: it.sid, releasedAt: it.releasedAt, approvals: it.approvals }));
  }

  function stopAll() { for (const cid of [...sessions.keys()]) endSession(cid, 'shutdown'); }

  return { handle, isActive, onJoin, onLeave, onCircleDeleted, releasedOf, knowledgeOf, stopAll, ready, _sessions: sessions };
}
