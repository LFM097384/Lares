// 转写记录 + 机器人 token 的信令消息处理(契约 docs/plans/transcript-bot-contract.md §3)。
//
// index.js 在主 switch 之前调 handle();返回 true = 这条消息归这里管。
// 依赖全部由 index.js 注入,本模块不直接摸 circles / registry 这些全局表。

import { TokenBuckets } from './ratelimit.js';
import { TEXT_MAX, ID_MAX, PAGE_MAX, PAGE_DEFAULT, validBlob } from './transcripts.js';
import { BOT_NAME_MAX } from './bot_tokens.js';
import { isAiUserId } from './ai_voice_supervisor.js';

const RELAY_BATCH = 50; // 补推时一条 WS 消息最多带几条密文(每条 ≤8 KB)

/**
 * @param {object} d
 *   store, tokens, botApi,
 *   send(ws,msg), broadcast(circleId,msg), sessionsOfCircle(circleId)
 *   settings() -> circleSettings 对象;saveSettings()
 *   registeredCircle(id), ownerKeyOk(id,key), circleAllowed(session,id)
 *   broadcastLobbySummary(id), broadcastCircleSettings(id)
 *   env
 */
export function createTranscriptWs(d) {
  const env = d.env ?? process.env;
  const perSec = Number(env.LARES_TRANSCRIPT_RATE_PER_SEC ?? 2);
  const burst = Number(env.LARES_TRANSCRIPT_BURST ?? 20);
  const appendRate = new TokenBuckets({ capacity: burst, perSec });
  const relayRate = new TokenBuckets({ capacity: burst, perSec });

  const settingsOf = (circleId) => d.settings()[circleId] ?? {};
  const isE2ee = (circleId) => settingsOf(circleId).e2ee === true;
  const isOn = (circleId) => settingsOf(circleId).transcript === true;
  const cidOf = (msg) => (typeof msg.circleId === 'string' ? msg.circleId : '');

  function ownerGate(ws, session, msg, op) {
    const circleId = cidOf(msg);
    const fail = (reason) => { d.send(ws, { t: 'owner_error', op, circleId, reason }); return null; };
    if (!session.userId) return fail('say_hello_first');
    if (!d.registeredCircle(circleId)) return fail('not_registered');
    if (!d.ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
    return { circleId, fail };
  }

  /// 给一条连接补推该圈的离线密文(分批)
  async function deliverPending(ws, session, circleId) {
    if (!session.userId || isAiUserId(session.userId)) return;
    const items = await d.store.pending(circleId, session.userId);
    for (let i = 0; i < items.length; i += RELAY_BATCH) {
      d.send(ws, { t: 'transcript_relay', circleId, items: items.slice(i, i + RELAY_BATCH) });
    }
    (ws._laresRelayDelivered ??= new Set()).add(circleId);
  }

  /// hello 成功后:把这个人有权看的圈子里积压的密文推过去
  async function onHello(ws, session) {
    try {
      if (!session.userId || !session.authed) return;
      if (session.authMode === 'circle') {
        if (session.authCircleId) await deliverPending(ws, session, session.authCircleId);
        return;
      }
      for (const circleId of await d.store.circlesWithPending(session.userId)) {
        if (d.circleAllowed(session, circleId)) await deliverPending(ws, session, circleId);
      }
    } catch (e) {
      console.error('[transcript] hello 补推失败:', e?.message ?? e);
    }
  }

  /// 进房后:登记为该圈成员(离线队列收件人),再补推
  async function onJoin(ws, session, circleId) {
    // AI 语音助手(u_ai_*)不是收件人:不进离线队列名单,也不补推密文
    if (isAiUserId(session.userId)) return;
    try {
      await d.store.addMember(circleId, session.userId);
      // circle 模式的连接从 hello 起就被钉在这个圈上,在线推送一直收得到;hello 时已补推过就不重复
      const pinned = session.authMode === 'circle' && session.authCircleId === circleId;
      if (pinned && ws._laresRelayDelivered?.has(circleId)) return;
      await deliverPending(ws, session, circleId);
    } catch (e) {
      console.error('[transcript] join 补推失败:', e?.message ?? e);
    }
  }

  /// 解散圈子时调用
  async function onCircleDeleted(circleId) {
    try { await d.store.deleteCircle(circleId); } catch (e) { console.error('[transcript] 解散清理失败:', e?.message ?? e); }
    try {
      for (const rec of await d.tokens.deleteCircle(circleId)) d.botApi.closeToken(rec.id);
    } catch (e) { console.error('[bot] 解散清理 token 失败:', e?.message ?? e); }
    d.botApi.closeCircle(circleId);
  }

  function sweep() {
    appendRate.sweep();
    relayRate.sweep();
  }

  async function handle(ws, session, msg) {
    switch (msg.t) {
      case 'circle_transcript_set': {
        const g = ownerGate(ws, session, msg, 'circle_transcript_set');
        if (!g) return true;
        if (typeof msg.on !== 'boolean') return g.fail('bad_request'), true;
        const all = d.settings();
        all[g.circleId] = { ...(all[g.circleId] ?? {}), transcript: msg.on };
        d.saveSettings();
        d.send(ws, { t: 'owner_ok', op: 'circle_transcript_set', circleId: g.circleId });
        d.broadcastLobbySummary(g.circleId);
        d.broadcastCircleSettings(g.circleId);
        return true;
      }

      case 'transcript_append': {
        const circleId = cidOf(msg);
        const fail = (reason) => { d.send(ws, { t: 'transcript_error', op: 'append', circleId, id: typeof msg.id === 'string' ? msg.id : undefined, reason }); return true; };
        if (!session.userId || !session.authed) return fail('say_hello_first');
        if (!circleId || session.circleId !== circleId) return fail('not_in_room');
        if (isE2ee(circleId)) return fail('e2ee');
        if (!isOn(circleId)) return fail('off');
        if (typeof msg.id !== 'string' || !msg.id || msg.id.length > ID_MAX) return fail('bad_id');
        if (typeof msg.text !== 'string' || msg.text.trim().length === 0 || msg.text.length > TEXT_MAX) return fail('bad_text');
        if (appendRate.take(session.userId) > 0) return fail('rate_limited');
        let r;
        try {
          r = await d.store.append(circleId, {
            userId: session.userId,
            name: session.name ?? '圈友', // 只认会话里的名字,msg.name 一概不看
            id: msg.id,
            text: msg.text,
            startedAt: typeof msg.startedAt === 'number' ? msg.startedAt : undefined,
          });
        } catch (e) {
          console.error('[transcript] 追加写盘失败:', e?.message ?? e);
          return fail('save_failed');
        }
        d.send(ws, { t: 'transcript_appended', circleId, id: msg.id, seq: r.item.seq });
        if (!r.duplicate) d.broadcast(circleId, { t: 'transcript_line', circleId, item: r.item });
        return true;
      }

      case 'transcript_get': {
        const circleId = cidOf(msg);
        const fail = (reason) => { d.send(ws, { t: 'transcript_error', op: 'get', circleId, reason }); return true; };
        if (!session.userId || !session.authed) return fail('say_hello_first');
        if (!circleId || !d.circleAllowed(session, circleId)) return fail('auth_scope');
        if (isE2ee(circleId)) return fail('e2ee');
        const before = msg.before === undefined || msg.before === null ? undefined : msg.before;
        if (before !== undefined && !Number.isInteger(before)) return fail('bad_request');
        const limit = msg.limit === undefined ? PAGE_DEFAULT : msg.limit;
        if (!Number.isInteger(limit) || limit < 1 || limit > PAGE_MAX) return fail('bad_request');
        const page = await d.store.page(circleId, { before, limit });
        d.send(ws, { t: 'transcript_page', circleId, items: page.items, more: page.more });
        return true;
      }

      case 'transcript_clear': {
        const g = ownerGate(ws, session, msg, 'transcript_clear');
        if (!g) return true;
        try {
          await d.store.clearArchive(g.circleId);
          await d.store.clearQueues(g.circleId);
        } catch (e) {
          console.error('[transcript] 清空失败:', e?.message ?? e);
          return g.fail('save_failed'), true;
        }
        d.send(ws, { t: 'owner_ok', op: 'transcript_clear', circleId: g.circleId });
        // 房里的、被钉在这个圈上的(在大厅里)都要清本地缓存
        const seen = new Set();
        const out = { t: 'transcript_cleared', circleId: g.circleId };
        for (const other of d.sessionsOfCircle(g.circleId)) { seen.add(other); d.send(other, out); }
        if (!seen.has(ws)) d.send(ws, out);
        d.botApi.emit(g.circleId, 'transcript_cleared', { circleId: g.circleId });
        return true;
      }

      case 'transcript_relay': {
        const circleId = cidOf(msg);
        const fail = (reason) => { d.send(ws, { t: 'transcript_error', op: 'relay', circleId, reason }); return true; };
        if (!session.userId || !session.authed) return fail('say_hello_first');
        if (!circleId || session.circleId !== circleId) return fail('not_in_room');
        if (!isE2ee(circleId)) return fail('not_e2ee');
        if (!isOn(circleId)) return fail('off');
        if (!validBlob(msg.blob)) return fail('bad_blob');
        if (relayRate.take(session.userId) > 0) return fail('rate_limited');
        let item;
        try {
          item = await d.store.enqueue(circleId, session.userId, msg.blob);
        } catch (e) {
          console.error('[transcript] 中继入队失败:', e?.message ?? e);
          return fail('save_failed');
        }
        d.send(ws, { t: 'transcript_relayed', circleId, rid: item.rid });
        // 在线即推:该圈所有连接(含发送者的其他设备),发送这条连接除外
        const out = { t: 'transcript_relay', circleId, items: [item] };
        for (const other of d.sessionsOfCircle(circleId)) {
          if (other === ws) continue;
          const s = other._laresSession;
          if (!s?.authed || !s.userId || isAiUserId(s.userId) || !d.circleAllowed(s, circleId)) continue;
          d.send(other, out);
        }
        return true;
      }

      case 'transcript_relay_ack': {
        const circleId = cidOf(msg);
        if (!session.userId || !session.authed || !circleId || !d.circleAllowed(session, circleId)) return true;
        const rids = Array.isArray(msg.rids) ? msg.rids.filter((r) => typeof r === 'string').slice(0, 5000) : [];
        if (rids.length) {
          try { await d.store.ack(circleId, session.userId, rids); } catch (e) { console.error('[transcript] ack 失败:', e?.message ?? e); }
        }
        return true;
      }

      case 'bot_token_create': {
        const g = ownerGate(ws, session, msg, 'bot_token_create');
        if (!g) return true;
        const name = typeof msg.name === 'string' ? msg.name.trim() : '';
        if (!name || name.length > BOT_NAME_MAX) return g.fail('bad_name'), true;
        try {
          const { token, record } = await d.tokens.create(g.circleId, name);
          d.send(ws, { t: 'bot_token', circleId: g.circleId, id: record.id, name: record.name, token, createdAt: record.createdAt });
        } catch (e) {
          if (e?.reason === 'too_many') return g.fail('too_many'), true;
          console.error('[bot] token 写盘失败:', e?.message ?? e);
          return g.fail('save_failed'), true;
        }
        return true;
      }

      case 'bot_token_list': {
        const g = ownerGate(ws, session, msg, 'bot_token_list');
        if (!g) return true;
        d.send(ws, { t: 'bot_tokens', circleId: g.circleId, items: d.tokens.list(g.circleId) });
        return true;
      }

      case 'bot_token_revoke': {
        const g = ownerGate(ws, session, msg, 'bot_token_revoke');
        if (!g) return true;
        if (typeof msg.id !== 'string' || !msg.id) return g.fail('bad_request'), true;
        let rec;
        try {
          rec = await d.tokens.revoke(g.circleId, msg.id);
        } catch (e) {
          console.error('[bot] token 吊销写盘失败:', e?.message ?? e);
          return g.fail('save_failed'), true;
        }
        if (!rec) return g.fail('not_found'), true;
        d.botApi.closeToken(rec.id);
        d.send(ws, { t: 'owner_ok', op: 'bot_token_revoke', circleId: g.circleId, id: rec.id });
        return true;
      }
    }
    return false;
  }

  return { handle, onHello, onJoin, onCircleDeleted, sweep };
}
