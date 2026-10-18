// 隐名之约 v2 —— 信令服务器这一侧只管**元数据**(规格 server/anonym-agent/AGENT-V2.md §1-§3)。
//
// v2 里 agent 是独立进程,以 u_ai_anon_* 成员身份进房,自己听音频、自己转写、自己维护文件记忆。
// 服务器**不处理任何会话内容**:没有原话、问题、回答、草稿经过这里。本模块只做:
//   - 圈主邀请 / 请离 agent(托管模式由 anonym_supervisor.js 按圈拉起子进程);
//   - E2EE 密封密钥中继:agent 的 anon_agent_hello → 在房圈主收 anon_agent_keyreq;
//     圈主的 anon_agent_key → 只交给该圈的 agent 连接。只转发不透明密文,不解析、不落盘、不进日志;
//   - anon_active {on}:只认该圈鉴权过的 agent 连接,据此开关强制关闭(转写 / 机器人 / webhook / 语音助手 / 推送);
//   - anon_agent_state 广播给圈内在线成员;
//   - anon_released_notice → 从 agent 的记忆文件读已放行条目 → 插件 webhook knowledge.released;
//   - bot API 知识检索(读文件,只读已放行部分);解散圈删记忆目录。
//
// 记忆格式由 agent 一侧设计;这里只依赖 server/anonym-agent/core/filememory.mjs 的 readReleasedKnowledge(dir, q)。
// 日志只记 code,绝不记密文 / 条目文本。

import { existsSync, rmSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { TokenBuckets } from './ratelimit.js';
import { memoryDirFor } from './anonym_supervisor.js';

const FILEMEMORY_URL = new URL('../anonym-agent/core/filememory.mjs', import.meta.url);
export const PUB_MAX = 256; // X25519 公钥(b64 / hex),留余量
export const SEALED_MAX = 4096; // 密封后的媒体密钥(hex 64 字节 + 封装开销)
const K_MIN = 2, K_MAX = 20;
const ITEM_IDS_MAX = 200;
const ITEM_FIELDS = ['id', 'text', 'kind', 'sid', 'draftId', 'releasedAt', 'approvals'];
const OPAQUE_RE = /^[A-Za-z0-9+/=_.:-]+$/; // 公钥 / 密文:只收 base64 / base64url / hex 及分隔符

const isStr = (v, max) => typeof v === 'string' && v.length > 0 && v.length <= max;
const pickItem = (it) => {
  const o = {};
  for (const k of ITEM_FIELDS) if (it?.[k] !== undefined) o[k] = it[k];
  return o;
};

/**
 * @param {object} d
 *   dataDir, send, sessionsOfCircle(cid) -> ws[], roomOf(cid) -> Map|undefined,
 *   registeredCircle(cid), isOwnerFor(session, cid, ownerKey), circleAllowed(session, cid),
 *   userIdFor(cid) -> 'u_ai_anon_…', supervisor (createAnonymSupervisor 的返回;无 RTC 时为 null),
 *   onActiveChange?(cid), onPresenceChange?(cid), fanout(cid, type, data), log?, fileMemoryModule?
 */
export function createAnonym(d) {
  const log = d.log ?? console;
  const tag = (cid) => `[anonym ${String(cid).slice(0, 8)}]`;
  const active = new Set(); // 圈 id:agent 报了 anon_active{on:true}
  const agentConn = new Map(); // 圈 id → agent 的 ws(在房)
  const pendingPub = new Map(); // 圈 id → agent 最近一次 hello 的公钥(后进房的圈主补发 keyreq)
  const ownerConns = new Map(); // 圈 id → Set<ws>:用 ownerKey 证明过圈主身份的连接(消息级钥匙)
  const rl = new TokenBuckets({ capacity: 20, perSec: 2 });

  let fmP = null;
  // d.fileMemoryModule:运维 / 测试可换成别的实现(env LARES_ANONYM_FILEMEMORY_MODULE,绝对路径)
  const fmHref = d.fileMemoryModule ? pathToFileURL(d.fileMemoryModule).href : FILEMEMORY_URL.href;
  const fileMemory = () => (fmP ??= import(fmHref));

  const isAgent = (ws, session, cid) => agentConn.get(cid) === ws
    && session.aiRole === 'anon' && session.aiCircleId === cid && session.userId === d.userIdFor(cid);
  const inRoom = (session, cid) => session.circleId === cid && Boolean(d.roomOf(cid)?.has(session.userId));
  const isPresent = (cid) => agentConn.has(cid);
  const isInvited = (cid) => Boolean(d.supervisor?.isInvited(cid));

  function ownersInRoom(cid) {
    const out = [];
    const extra = ownerConns.get(cid);
    for (const ws of d.sessionsOfCircle(cid)) {
      const s = ws._laresSession;
      if (!s?.userId || s.aiRole || !inRoom(s, cid)) continue;
      if ((s.isOwner && s.authCircleId === cid) || extra?.has(ws)) out.push(ws);
    }
    return out;
  }
  function rememberOwner(ws, cid) {
    let set = ownerConns.get(cid);
    if (!set) ownerConns.set(cid, (set = new Set()));
    set.add(ws);
  }

  const stateMsg = (cid) => ({ t: 'anon_agent_state', circleId: cid, present: isPresent(cid), active: active.has(cid), invited: isInvited(cid) });
  function broadcastState(cid) {
    const m = stateMsg(cid);
    for (const ws of d.sessionsOfCircle(cid)) {
      const s = ws._laresSession;
      if (!s?.userId || !d.circleAllowed(s, cid)) continue;
      d.send(ws, m);
    }
  }

  function setActive(cid, on) {
    const was = active.has(cid);
    if (on) active.add(cid); else active.delete(cid);
    if (was !== on) {
      log.log?.(`${tag(cid)} 强制关闭 ${on ? '开' : '关'}`);
      try { d.onActiveChange?.(cid); } catch (e) { log.error?.(`${tag(cid)} onActiveChange: ${e?.message ?? e}`); }
    }
  }

  function agentGone(cid) {
    agentConn.delete(cid);
    pendingPub.delete(cid);
    setActive(cid, false);
    try { d.onPresenceChange?.(cid); } catch { /* ignore */ }
    broadcastState(cid);
  }

  /// WS 入口。返回 true = 这条消息归这里管
  async function handle(ws, session, msg) {
    const t = msg?.t;
    if (typeof t !== 'string' || !t.startsWith('anon_')) return false;
    const cid = typeof msg.circleId === 'string' ? msg.circleId : '';
    const err = (code) => d.send(ws, { t: 'anon_error', circleId: cid || null, op: t, code });
    if (!session.userId) return err('say_hello_first'), true;
    if (!cid || cid.length > 128) return err('bad_request'), true;
    if (!d.circleAllowed(session, cid)) return err('not_member'), true;
    if (rl.take(`${session.userId}\0${cid}`) > 0) return err('rate_limited'), true;

    switch (t) {
      case 'anon_agent_invite': {
        if (session.aiRole) return err('not_allowed'), true;
        if (!d.registeredCircle(cid)) return err('not_registered'), true;
        if (!d.isOwnerFor(session, cid, msg.ownerKey)) return err('not_owner'), true;
        if (!inRoom(session, cid)) return err('not_in_room'), true;
        let k = null;
        if (msg.k !== undefined && msg.k !== null) {
          if (!Number.isInteger(msg.k) || msg.k < K_MIN || msg.k > K_MAX) return err('bad_k'), true;
          k = msg.k;
        }
        if (!d.supervisor) return err('unavailable'), true;
        if (isInvited(cid) || isPresent(cid)) return err('already_active'), true;
        if (msg.ownerKey) rememberOwner(ws, cid);
        const r = d.supervisor.invite(cid, { k, convenerId: session.userId }); // 召集人 = 发邀请的圈主(`end` 只认它)
        if (!r.ok) return err(r.code), true;
        log.log?.(`${tag(cid)} 圈主邀请 agent`);
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t });
        try { d.onPresenceChange?.(cid); } catch { /* ignore */ }
        broadcastState(cid);
        return true;
      }

      case 'anon_agent_dismiss': {
        if (session.aiRole) return err('not_allowed'), true;
        if (!d.registeredCircle(cid)) return err('not_registered'), true;
        if (!d.isOwnerFor(session, cid, msg.ownerKey)) return err('not_owner'), true;
        d.supervisor?.dismiss(cid, 'dismissed');
        // agent 进程的连接会随退出断开;强制开关不等它,先关(它已不在会话里)
        setActive(cid, false);
        log.log?.(`${tag(cid)} 圈主请 agent 离开`);
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t });
        try { d.onPresenceChange?.(cid); } catch { /* ignore */ }
        broadcastState(cid);
        return true;
      }

      case 'anon_agent_hello': {
        if (!isAgent(ws, session, cid)) return err('not_allowed'), true;
        if (!isStr(msg.x25519Pub, PUB_MAX) || !OPAQUE_RE.test(msg.x25519Pub)) return err('bad_request'), true;
        pendingPub.set(cid, msg.x25519Pub);
        const owners = ownersInRoom(cid);
        for (const o of owners) d.send(o, { t: 'anon_agent_keyreq', circleId: cid, x25519Pub: msg.x25519Pub });
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t, owners: owners.length });
        return true;
      }

      case 'anon_agent_key': {
        if (session.aiRole) return err('not_allowed'), true;
        if (!d.registeredCircle(cid)) return err('not_registered'), true;
        if (!d.isOwnerFor(session, cid, msg.ownerKey)) return err('not_owner'), true;
        if (!isStr(msg.sealed, SEALED_MAX) || !OPAQUE_RE.test(msg.sealed)) return err('bad_request'), true;
        if (msg.x25519Pub !== undefined && (!isStr(msg.x25519Pub, PUB_MAX) || !OPAQUE_RE.test(msg.x25519Pub))) return err('bad_request'), true;
        const agent = agentConn.get(cid);
        if (!agent) return err('no_agent'), true;
        // 圈主是针对哪把公钥封的:与 agent 当前公钥不符就不转(agent 重启换了钥匙)
        if (msg.x25519Pub !== undefined && pendingPub.get(cid) !== msg.x25519Pub) return err('stale_key'), true;
        d.send(agent, { t: 'anon_agent_key', circleId: cid, sealed: msg.sealed, ...(msg.x25519Pub ? { x25519Pub: msg.x25519Pub } : {}) });
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t });
        log.log?.(`${tag(cid)} 密封密钥已转交 agent`);
        return true;
      }

      case 'anon_active': {
        if (!isAgent(ws, session, cid)) return err('not_allowed'), true;
        if (typeof msg.on !== 'boolean') return err('bad_request'), true;
        setActive(cid, msg.on);
        broadcastState(cid);
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t, active: msg.on });
        return true;
      }

      case 'anon_released_notice': {
        if (!isAgent(ws, session, cid)) return err('not_allowed'), true;
        const ids = msg.itemIds;
        if (!Array.isArray(ids) || ids.length === 0 || ids.length > ITEM_IDS_MAX || !ids.every((x) => isStr(x, 128))) return err('bad_request'), true;
        d.send(ws, { t: 'anon_ok', circleId: cid, op: t });
        void releasedNotice(cid, new Set(ids));
        return true;
      }

      default:
        return err('unknown_op'), true;
    }
  }

  async function readReleased(cid, q) {
    const dir = memoryDirFor(d.dataDir, cid);
    if (!dir || !existsSync(dir)) return [];
    const fm = await fileMemory();
    if (typeof fm?.readReleasedKnowledge !== 'function') return [];
    const items = await fm.readReleasedKnowledge(dir, q);
    return Array.isArray(items) ? items.filter((x) => x && typeof x === 'object' && typeof x.id === 'string') : [];
  }

  async function releasedNotice(cid, ids) {
    try {
      const items = (await readReleased(cid, '')).filter((x) => ids.has(x.id)).map(pickItem);
      if (items.length === 0) { log.log?.(`${tag(cid)} released_notice:文件里没有对应条目`); return; }
      // 只含已放行条目;强制关闭期间 botApi.emit 被压住,这里直接走插件扇出
      d.fanout(cid, 'knowledge.released', { circleId: cid, items });
    } catch (e) {
      log.error?.(`${tag(cid)} released_notice 读记忆失败: ${e?.code ?? 'read_failed'}`);
    }
  }

  /// bot API:GET /bot/v1/circles/:id/anonym/knowledge?q=
  async function knowledgeOf(cid, q, { limit = 5 } = {}) {
    try {
      return (await readReleased(cid, String(q ?? ''))).slice(0, limit).map(pickItem);
    } catch (e) {
      log.error?.(`${tag(cid)} 读知识失败: ${e?.code ?? 'read_failed'}`);
      return [];
    }
  }

  // ── index.js 的钩子 ──
  function onJoin(ws, session, cid) {
    if (session.aiRole === 'anon' && session.aiCircleId === cid && session.userId === d.userIdFor(cid)) {
      const old = agentConn.get(cid);
      agentConn.set(cid, ws);
      if (old !== ws) {
        log.log?.(`${tag(cid)} agent 进房`);
        try { d.onPresenceChange?.(cid); } catch { /* ignore */ }
        broadcastState(cid);
      }
      return;
    }
    if (isPresent(cid) || isInvited(cid)) d.send(ws, stateMsg(cid));
    // 后进房的圈主:agent 还在等密钥 → 补发 keyreq
    const pub = pendingPub.get(cid);
    if (pub && !session.aiRole && session.isOwner && session.authCircleId === cid) {
      d.send(ws, { t: 'anon_agent_keyreq', circleId: cid, x25519Pub: pub });
    }
  }

  function onLeave(cid, userId) {
    if (userId === d.userIdFor(cid) && agentConn.has(cid)) {
      log.log?.(`${tag(cid)} agent 离房`);
      agentGone(cid);
    }
  }

  function onConnClose(ws) {
    for (const set of ownerConns.values()) set.delete(ws);
  }

  function onCircleDeleted(cid) {
    d.supervisor?.dismiss(cid, 'circle_deleted');
    agentConn.delete(cid);
    pendingPub.delete(cid);
    ownerConns.delete(cid);
    setActive(cid, false);
    const dir = memoryDirFor(d.dataDir, cid);
    if (dir) {
      try { rmSync(dir, { recursive: true, force: true }); } catch (e) { log.error?.(`${tag(cid)} 删除记忆目录失败: ${e?.code ?? 'error'}`); }
      // v1 遗留的单文件知识库
      try { unlinkSync(path.join(path.dirname(dir), `${cid}.json`)); } catch (e) { if (e?.code !== 'ENOENT') log.error?.(`${tag(cid)} 删除 v1 知识库失败: ${e?.code ?? 'error'}`); }
    }
  }

  function stopAll() { d.supervisor?.stopAll(); }

  return {
    handle, onJoin, onLeave, onConnClose, onCircleDeleted, knowledgeOf, stopAll, broadcastState,
    isActive: (cid) => active.has(cid),
    /// 隐名 agent 在场(已邀请或已进房)—— 语音助手与之互斥
    excludesVoice: (cid) => active.has(cid) || isPresent(cid) || isInvited(cid),
    isPresent,
    _state: { active, agentConn, pendingPub },
  };
}
