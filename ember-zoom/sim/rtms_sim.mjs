#!/usr/bin/env node
// ember-zoom · 本地 RTMS 模拟器,按 docs/plans/chatham/05-zoom-rtms-facts.md 的线协议实现服务端一侧:
//   - 信令 WS + 媒体 WS(同一个 http server,路径 /signaling 与 /media),
//   - 校验签名 hex(HMAC-SHA256(clientSecret, clientId,meeting_uuid,rtms_stream_id))与握手顺序:
//       信令 1 → 2(带 media_server.server_urls);媒体 3 → 4;然后信令上必须先 7 才推数据;5 订阅事件(无响应),
//   - 两条连接每 keepAliveMs 发 {msg_type:12, timestamp},要求 {msg_type:13} 同值回复;漏 maxMissed 次即断,
//   - 播放脚本会议:转写(17,带 user_name)、入 / 离会(6,event 3/4,participants[])、活跃说话人(6,event 2)、音频(14)、
//     会话停止(9 state 5 + stop_reason),
//   - 给插件发一条正确签名的 meeting.rtms_started webhook(或 rtms_stopped),
//   - 注入故障:错误签名(信令回 status 3)、流中途断开(测重连)、stop reason。
// 只用于测试 / 本地联调,不是 Zoom。未核实的行为(UNCONFIRMED)按 05 的最保守读法实现,见 README。
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { createHmac, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from '../deps.mjs';
import { signWebhook } from '../webhook.mjs';
import { MSG, MEDIA, EVENT, SESSION_STATE, rtmsSignature } from '../rtms_client.mjs';

/** 脚本步骤:
 *   {join: [{user_id, user_name}]} | {leave: [{user_id, user_name}]} | {say: {user_id, user_name, text}} | {speaker: {user_id, user_name}}
 *   {audio: {user_id, user_name, frames?:n}} | {wait: ms} | {drop: 'media'|'signaling'} | {stop: stopReason} | {until: name}(等测试 sim.release(name))
 */
export class RtmsSim extends EventEmitter {
  constructor({ clientId, clientSecret, meetingUuid = `mtg-${randomUUID()}`, streamId = `st-${randomUUID()}`, keepAliveMs = 10_000, maxMissed = 3, stepMs = 5, log = () => {} } = {}) {
    super();
    Object.assign(this, { clientId, clientSecret, meetingUuid, streamId, keepAliveMs, maxMissed, stepMs, log });
    this.failures = { badSignature: false };
    this.violations = []; // 握手顺序 / 协议违规(测试断言为空)
    this.stats = { signalingHandshakes: 0, dataHandshakes: 0, readyAcks: 0, subscriptions: [], keepAliveReplies: { signaling: 0, media: 0 }, keepAliveMissedDrops: 0, connections: 0, closeReqs: 0 };
    this.conns = new Set();
    this.session = null; // 当前一对连接 { sig, media, ready, subscribed:Set }
    this.joined = new Map(); // user_id → user_name(当前在会,重连时补发)
    this.gates = new Map();
    this.server = http.createServer((req, res) => { res.writeHead(404); res.end(); });
    this.wss = new WebSocketServer({ noServer: true });
    this.server.on('upgrade', (req, socket, head) => {
      const p = new URL(req.url, 'http://x').pathname;
      if (p !== '/signaling' && p !== '/media') { socket.destroy(); return; }
      this.wss.handleUpgrade(req, socket, head, (ws) => this._onConn(ws, p.slice(1)));
    });
  }

  async listen(port = 0, host = '127.0.0.1') {
    await new Promise((r) => this.server.listen(port, host, r));
    this.port = this.server.address().port;
    this.base = `ws://${host}:${this.port}`;
    return this;
  }
  get signalingUrl() { return `${this.base}/signaling`; }
  get mediaUrl() { return `${this.base}/media`; }

  expectedSignature() { return rtmsSignature(this.clientId, this.clientSecret, this.meetingUuid, this.streamId); }
  _violation(s) { this.violations.push(s); this.log(`VIOLATION ${s}`); this.emit('violation', s); }
  _send(ws, obj) { try { if (ws?.readyState === 1) ws.send(JSON.stringify(obj)); } catch { /* */ } }

  _onConn(ws, kind) {
    this.stats.connections += 1;
    const c = { ws, kind, missed: 0, lastKa: null, ka: null, handshaken: false };
    this.conns.add(c);
    ws.on('message', (d) => { let m; try { m = JSON.parse(String(d)); } catch { this._violation(`${kind}: non-JSON`); return; } this._onMsg(c, m); });
    ws.on('close', () => { clearInterval(c.ka); this.conns.delete(c); if (this.session?.sig === c) this.session.sig = null; if (this.session?.media === c) this.session.media = null; this.emit('closed', kind); });
    ws.on('error', () => {});
  }

  _startKeepAlive(c) {
    clearInterval(c.ka);
    c.ka = setInterval(() => {
      if (c.lastKa !== null) {
        c.missed += 1;
        if (c.missed >= this.maxMissed) { this.stats.keepAliveMissedDrops += 1; this.log(`${c.kind}: keep-alive missed ×${c.missed}, dropping`); try { c.ws.terminate(); } catch { /* */ } clearInterval(c.ka); return; }
      }
      c.lastKa = Date.now();
      this._send(c.ws, { msg_type: MSG.KEEP_ALIVE_REQ, timestamp: c.lastKa });
    }, this.keepAliveMs);
    c.ka.unref?.();
  }

  _checkCommon(c, m, label) {
    if (m.meeting_uuid !== this.meetingUuid) { this._violation(`${label}: wrong meeting_uuid`); return 2; }
    if (m.rtms_stream_id !== this.streamId) { this._violation(`${label}: wrong rtms_stream_id`); return 2; }
    if (this.failures.badSignature || m.signature !== this.expectedSignature()) return 3;
    return 0;
  }

  _onMsg(c, m) {
    const t = m?.msg_type;
    if (t === MSG.KEEP_ALIVE_RESP) {
      if (c.lastKa === null || m.timestamp !== c.lastKa) this._violation(`${c.kind}: keep-alive resp timestamp mismatch`);
      else { c.missed = 0; c.lastKa = null; this.stats.keepAliveReplies[c.kind] += 1; }
      return;
    }
    if (c.kind === 'signaling') {
      if (t === MSG.SIGNALING_HAND_SHAKE_REQ) {
        if (c.handshaken) { this._send(c.ws, { msg_type: MSG.SIGNALING_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: 8, reason: 'duplicate' }); return; }
        if (m.protocol_version !== 1) this._violation('signaling: protocol_version != 1');
        const code = this._checkCommon(c, m, 'signaling');
        if (code) { this._send(c.ws, { msg_type: MSG.SIGNALING_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: code, reason: code === 3 ? 'invalid signature' : 'invalid stream id' }); this.emit('rejected', code); return; }
        c.handshaken = true;
        this.stats.signalingHandshakes += 1;
        this.session = { sig: c, media: null, ready: false, subscribed: new Set() };
        this._send(c.ws, { msg_type: MSG.SIGNALING_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: 0, reason: '', media_server: { server_urls: { audio: this.mediaUrl, video: this.mediaUrl, transcript: this.mediaUrl, all: this.mediaUrl } } });
        this._startKeepAlive(c);
        return;
      }
      if (!c.handshaken) { this._violation(`signaling: msg ${t} before handshake`); return; }
      if (t === MSG.CLIENT_READY_ACK) {
        const s = this.session;
        if (!s || s.sig !== c || !s.media?.handshaken) { this._violation('signaling: CLIENT_READY_ACK before data handshake'); return; }
        if (m.rtms_stream_id !== this.streamId) this._violation('signaling: CLIENT_READY_ACK wrong stream id');
        s.ready = true;
        this.stats.readyAcks += 1;
        // 重连后补发当前在会名单(PARTICIPANT_JOIN 只在订阅之后推;这里等订阅)
        this.emit('ready', { readyAcks: this.stats.readyAcks });
        return;
      }
      if (t === MSG.EVENT_SUBSCRIPTION) {
        if (!this.session?.ready) this._violation('signaling: EVENT_SUBSCRIPTION before CLIENT_READY_ACK');
        if (!Array.isArray(m.events)) { this._violation('signaling: EVENT_SUBSCRIPTION without events[]'); return; }
        for (const e of m.events) if (e?.subscribe === true) this.session.subscribed.add(e.event_type); else this.session.subscribed.delete(e?.event_type);
        this.stats.subscriptions.push(m.events.map((e) => e.event_type));
        if (this.joined.size && this.session.subscribed.has(EVENT.PARTICIPANT_JOIN)) {
          this._send(c.ws, { msg_type: MSG.EVENT_UPDATE, event: { event_type: EVENT.PARTICIPANT_JOIN, timestamp: Date.now(), participants: [...this.joined].map(([user_id, user_name]) => ({ user_id, user_name })) } });
        }
        this.emit('subscribed', [...this.session.subscribed]);
        return;
      }
      if (t === MSG.STREAM_CLOSE_REQ) { this.stats.closeReqs += 1; this._send(c.ws, { msg_type: MSG.STREAM_CLOSE_RESP, rtms_stream_id: this.streamId, status_code: 0 }); this.emit('close_req'); return; }
      this._violation(`signaling: unexpected msg_type ${t}`);
      return;
    }
    // media
    if (t === MSG.DATA_HAND_SHAKE_REQ) {
      if (!this.session?.sig) { this._violation('media: DATA_HAND_SHAKE_REQ before signaling handshake'); try { c.ws.close(); } catch { /* */ } return; }
      if (c.handshaken) { this._violation('media: duplicate data handshake'); return; }
      const code = this._checkCommon(c, m, 'media');
      const mt = Number(m.media_type);
      if (!code && (!Number.isInteger(mt) || mt <= 0 || (mt & ~(MEDIA.AUDIO | MEDIA.VIDEO | MEDIA.DESKSHARE | MEDIA.TRANSCRIPT | MEDIA.CHAT | MEDIA.ALL)))) {
        this._send(c.ws, { msg_type: MSG.DATA_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: 9, reason: 'media type not supported' });
        return;
      }
      if (code) { this._send(c.ws, { msg_type: MSG.DATA_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: code, reason: 'rejected' }); return; }
      if ((mt & MEDIA.TRANSCRIPT) && m.media_params?.transcript && m.media_params.transcript.content_type !== 5) this._violation('media: transcript content_type != 5');
      if ((mt & MEDIA.AUDIO) && m.media_params?.audio && m.media_params.audio.codec !== 1) this._violation('media: audio codec != L16');
      c.handshaken = true;
      c.mediaType = mt;
      this.session.media = c;
      this.stats.dataHandshakes += 1;
      this._send(c.ws, { msg_type: MSG.DATA_HAND_SHAKE_RESP, protocol_version: 1, sequence: m.sequence, status_code: 0, reason: '', payload_encrypted: false, media_params: m.media_params ?? {} });
      this._startKeepAlive(c);
      return;
    }
    if (!c.handshaken) { this._violation(`media: msg ${t} before data handshake`); return; }
    this._violation(`media: unexpected msg_type ${t}`);
  }

  // ── 驱动 ──
  get ready() { return Boolean(this.session?.ready && this.session.media && this.session.sig); }
  waitFor(ev, pred = () => true, timeoutMs = 10_000) {
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.off(ev, h); reject(new Error(`sim: timeout waiting for ${ev}`)); }, timeoutMs);
      const h = (...a) => { if (pred(...a)) { clearTimeout(t); this.off(ev, h); resolve(a[0]); } };
      this.on(ev, h);
    });
  }
  async waitReady(timeoutMs = 10_000) {
    const t0 = Date.now();
    while (!(this.ready && this.session.subscribed.size)) {
      if (Date.now() - t0 > timeoutMs) throw new Error('sim: client never became ready');
      await new Promise((r) => setTimeout(r, 5));
    }
  }
  release(name) { const g = this.gates.get(name); if (g) g.resolve(); else this.gates.set(name, { done: true }); }
  _gate(name) {
    const g = this.gates.get(name);
    if (g?.done) { this.gates.delete(name); return Promise.resolve(); }
    return new Promise((resolve) => this.gates.set(name, { resolve: () => { this.gates.delete(name); resolve(); } }));
  }

  _pushEvent(event) {
    const s = this.session;
    if (!s?.ready || !s.subscribed.has(event.event_type)) return false;
    this._send(s.sig.ws, { msg_type: MSG.EVENT_UPDATE, event: { timestamp: Date.now(), ...event } });
    return true;
  }
  join(people) { for (const p of people) this.joined.set(String(p.user_id), p.user_name ?? ''); return this._pushEvent({ event_type: EVENT.PARTICIPANT_JOIN, participants: people }); }
  leave(people) { for (const p of people) this.joined.delete(String(p.user_id)); return this._pushEvent({ event_type: EVENT.PARTICIPANT_LEAVE, participants: people }); }
  speaker(p) { return this._pushEvent({ event_type: EVENT.ACTIVE_SPEAKER_CHANGE, user_id: p.user_id, user_name: p.user_name }); }
  say({ user_id, user_name, text }) {
    const s = this.session;
    if (!s?.ready || !(s.media.mediaType & MEDIA.TRANSCRIPT)) return false;
    const now = Date.now();
    this._send(s.media.ws, { msg_type: MSG.MEDIA_DATA_TRANSCRIPT, content: { user_id, user_name, start_time: now - 1500, end_time: now, timestamp: now, language: 'zh', data: text } });
    return true;
  }
  audio({ user_id, user_name, pcm }) {
    const s = this.session;
    if (!s?.ready || !(s.media.mediaType & MEDIA.AUDIO)) return false;
    const buf = Buffer.alloc(pcm.length * 2);
    for (let i = 0; i < pcm.length; i++) buf.writeInt16LE(pcm[i], i * 2);
    this._send(s.media.ws, { msg_type: MSG.MEDIA_DATA_AUDIO, content: { user_id, user_name, data: buf.toString('base64'), length: buf.length, timestamp: Date.now() } });
    return true;
  }
  /// 故障:掐断一条连接(不发任何关闭原因),客户端应退避重连
  drop(which = 'media') { const c = which === 'media' ? this.session?.media : this.session?.sig; if (c) { try { c.ws.terminate(); } catch { /* */ } } if (which === 'signaling' || which === 'both') { try { this.session?.media?.ws.terminate(); } catch { /* */ } } this.session = which === 'media' ? this.session : null; }
  /// 会话停止:信令上 {msg_type:9, state:5, stop_reason}
  stop(stopReason = 6) {
    const s = this.session;
    if (s?.sig) this._send(s.sig.ws, { msg_type: MSG.SESSION_STATE_UPDATE, state: SESSION_STATE.STOPPED, stop_reason: stopReason, timestamp: Date.now() });
    setTimeout(() => { for (const c of this.conns) { try { c.ws.close(1000); } catch { /* */ } } }, 100).unref?.();
  }

  async play(script) {
    for (const step of script) {
      if (step.wait) await new Promise((r) => setTimeout(r, step.wait));
      else if (step.until) await this._gate(step.until);
      else if (step.join) this.join(step.join);
      else if (step.leave) this.leave(step.leave);
      else if (step.say) this.say(step.say);
      else if (step.speaker) this.speaker(step.speaker);
      else if (step.audio) { for (let i = 0; i < (step.audio.frames ?? 10); i++) this.audio({ ...step.audio, pcm: step.audio.pcm ?? new Int16Array(320) }); }
      else if (step.drop) { this.drop(step.drop); await this.waitReady(); }
      else if (step.stop !== undefined) { this.stop(step.stop); }
      if (this.stepMs) await new Promise((r) => setTimeout(r, this.stepMs));
    }
  }

  // ── webhook ──
  startedPayload(extra = {}) {
    return { account_id: 'acct_sim', is_original_host: true, meeting_id: 81234567890, meeting_uuid: this.meetingUuid, operator_id: 'op_sim', rtms_stream_id: this.streamId, server_urls: this.signalingUrl, ...extra };
  }
  /// 给插件发 webhook。secret 用对的(或故意错的)webhook secret token。返回 {status, body}
  async sendWebhook(url, { secret, event = 'meeting.rtms_started', payload = null, timestamp = Math.floor(Date.now() / 1000), badSignature = false } = {}) {
    const body = JSON.stringify({ event, event_ts: Date.now(), payload: payload ?? (event === 'meeting.rtms_stopped' ? { meeting_uuid: this.meetingUuid, rtms_stream_id: this.streamId, stop_reason: 6 } : this.startedPayload()) });
    let sig = signWebhook(secret, timestamp, body);
    if (badSignature) sig = `v0=${createHmac('sha256', 'wrong').update(body).digest('hex')}`;
    const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', 'x-zm-request-timestamp': String(timestamp), 'x-zm-signature': sig }, body });
    return { status: res.status, body: await res.text() };
  }

  async close() {
    for (const c of this.conns) { clearInterval(c.ka); try { c.ws.terminate(); } catch { /* */ } }
    this.wss.close();
    this.server.closeAllConnections?.();
    await new Promise((r) => this.server.close(() => r()));
  }
}

// CLI:本地联调 —— 起 sim,给插件 webhook 发 rtms_started,播一段短会。
//   ZOOM_CLIENT_ID=… ZOOM_CLIENT_SECRET=… ZOOM_WEBHOOK_SECRET=… node ember-zoom/sim/rtms_sim.mjs http://127.0.0.1:8790/webhook
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const url = process.argv[2] || 'http://127.0.0.1:8790/webhook';
  const env = process.env;
  const sim = new RtmsSim({ clientId: env.ZOOM_CLIENT_ID, clientSecret: env.ZOOM_CLIENT_SECRET, keepAliveMs: 10_000, stepMs: 400, log: (m) => process.stderr.write(`[sim] ${m}\n`) });
  await sim.listen(0);
  process.stderr.write(`[sim] signaling ${sim.signalingUrl}\n`);
  const r = await sim.sendWebhook(url, { secret: env.ZOOM_WEBHOOK_SECRET });
  process.stderr.write(`[sim] webhook → ${r.status}\n`);
  await sim.waitReady(30_000);
  const A = { user_id: 16778240, user_name: '张伟' }, B = { user_id: 16779264, user_name: '李秀梅' };
  await sim.play([
    { join: [A, B] },
    { say: { ...A, text: '大家好，我是张伟，在星辰科技负责产品。我觉得下季度可以先做小范围试点。' } },
    { say: { ...B, text: '同意，下周先跑一下，预算控制在十万以内。' } },
    { wait: 60_000 },
    { stop: 6 },
  ]);
  setTimeout(async () => { process.stderr.write(`[sim] violations: ${JSON.stringify(sim.violations)}\n`); await sim.close(); }, 1000);
}
