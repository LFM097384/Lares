// ember-zoom · 纯 ws 的 Zoom RTMS 客户端。线格式一律按 docs/plans/chatham/05-zoom-rtms-facts.md(§2–§5)。
//
//   信令  ws(server_urls[i])  → {msg_type:1, protocol_version:1, sequence, meeting_uuid, rtms_stream_id, signature}
//                             ← {msg_type:2, status_code:0, media_server:{server_urls:{audio,video,transcript,all}}}
//   媒体  ws(media url)        → {msg_type:3, …, signature, media_type, media_params}
//                             ← {msg_type:4, status_code:0}
//   信令                       → {msg_type:7, rtms_stream_id}                       CLIENT_READY_ACK
//                             → {msg_type:5, events:[{event_type:3|4|2, subscribe:true}]}   无响应
//   两条连接                   ← {msg_type:12, timestamp} → {msg_type:13, timestamp}(同值)
//   数据                       ← 17 转写 / 14 音频 / 6 事件 / 8 流状态 / 9 会话状态
// 签名:hex(HMAC-SHA256(clientSecret, clientId + "," + meeting_uuid + "," + rtms_stream_id))。
// 重连:3 s 起倍增,封顶 30 s;65 s 收不到信令心跳 → 重做信令握手。
//
// 事件(EventEmitter):
//   'ready'        ()                                   握手完成(7 已发、5 已订阅)
//   'transcript'   ({userId, userName, text, timestamp, startTime, endTime, language})
//   'join'         ({userId, userName})                 每个参与者一次(PARTICIPANT_JOIN 的 participants[] 拆开)
//   'leave'        ({userId, userName})
//   'speaker'      ({userId, userName, timestamp})      ACTIVE_SPEAKER_CHANGE
//   'audio'        ({userId, userName, pcm: Int16Array, sampleRate, channels, timestamp})
//   'state'        ({kind:'stream'|'session', state, reason})
//   'reconnecting' ({attempt, delayMs, why})
//   'stopped'      ({reason, stopReason?, statusCode?}) 终态,之后不再发任何事件
// 原文(转写)只经事件交给调用方,本模块不落盘、不写日志。
import { EventEmitter } from 'node:events';
import { createHmac } from 'node:crypto';
import { WebSocket as DefaultWebSocket } from './deps.mjs';

export const MSG = Object.freeze({
  SIGNALING_HAND_SHAKE_REQ: 1, SIGNALING_HAND_SHAKE_RESP: 2, DATA_HAND_SHAKE_REQ: 3, DATA_HAND_SHAKE_RESP: 4,
  EVENT_SUBSCRIPTION: 5, EVENT_UPDATE: 6, CLIENT_READY_ACK: 7, STREAM_STATE_UPDATE: 8, SESSION_STATE_UPDATE: 9,
  SESSION_STATE_REQ: 10, SESSION_STATE_RESP: 11, KEEP_ALIVE_REQ: 12, KEEP_ALIVE_RESP: 13,
  MEDIA_DATA_AUDIO: 14, MEDIA_DATA_VIDEO: 15, MEDIA_DATA_SHARE: 16, MEDIA_DATA_TRANSCRIPT: 17, MEDIA_DATA_CHAT: 18,
  STREAM_STATE_REQ: 19, STREAM_STATE_RESP: 20, STREAM_CLOSE_REQ: 21, STREAM_CLOSE_RESP: 22,
});
export const MEDIA = Object.freeze({ AUDIO: 1, VIDEO: 2, DESKSHARE: 4, TRANSCRIPT: 8, CHAT: 16, ALL: 32 });
export const EVENT = Object.freeze({
  FIRST_PACKET_TIMESTAMP: 1, ACTIVE_SPEAKER_CHANGE: 2, PARTICIPANT_JOIN: 3, PARTICIPANT_LEAVE: 4,
  SHARING_START: 5, SHARING_STOP: 6, MEDIA_CONNECTION_INTERRUPTED: 7, VIDEO_ON: 8, VIDEO_OFF: 9,
});
export const SESSION_STATE = Object.freeze({ INACTIVE: 0, INITIALIZE: 1, STARTED: 2, PAUSED: 3, RESUMED: 4, STOPPED: 5 });
export const STREAM_STATE = Object.freeze({ INACTIVE: 0, ACTIVE: 1, INTERRUPTED: 2, TERMINATING: 3, TERMINATED: 4, PAUSED: 5, RESUMED: 6 });
export const STOP_REASON = Object.freeze({
  1: 'HOST_TRIGGERED', 2: 'USER_TRIGGERED', 3: 'USER_LEFT', 4: 'USER_EJECTED', 5: 'HOST_DISABLED_APP', 6: 'MEETING_ENDED',
  7: 'STREAM_CANCELED', 8: 'STREAM_REVOKED', 9: 'ALL_APPS_DISABLED', 10: 'INTERNAL_EXCEPTION', 11: 'CONNECTION_TIMEOUT',
  24: 'KEEP_ALIVE_TIMEOUT', 25: 'MANUAL_API_TRIGGERED', 26: 'STREAMING_NOT_SUPPORTED',
});
/// 信令 / 数据握手 status_code:这些重试无意义(1 无效消息类型、2 无效 stream id、3 签名无效、9–13 媒体类型不支持)。8 = 重复信令请求 → 退避重试。
export const FATAL_STATUS = Object.freeze(new Set([1, 2, 3, 9, 10, 11, 12, 13]));
export const SAMPLE_RATE = Object.freeze({ 0: 8000, 1: 16000, 2: 32000, 3: 48000 });

export const rtmsSignature = (clientId, clientSecret, meetingUuid, streamId) =>
  createHmac('sha256', String(clientSecret)).update(`${clientId},${meetingUuid},${streamId}`).digest('hex');

/// 第 attempt 次(0 起)重连前的等待:3 s、6 s、12 s、24 s、30 s、30 s …
export const backoffDelay = (attempt, { initialMs = 3000, maxMs = 30_000 } = {}) => Math.min(maxMs, initialMs * 2 ** Math.max(0, attempt));

export const DEFAULT_SUBSCRIBE = Object.freeze([EVENT.PARTICIPANT_JOIN, EVENT.PARTICIPANT_LEAVE, EVENT.ACTIVE_SPEAKER_CHANGE]);

function decodeL16(b64, endian = 'le') {
  const buf = Buffer.from(String(b64 ?? ''), 'base64');
  const n = buf.length >> 1;
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) out[i] = endian === 'be' ? buf.readInt16BE(i * 2) : buf.readInt16LE(i * 2);
  return out;
}

export class RtmsClient extends EventEmitter {
  /**
   * @param {object} o
   * @param {string} o.clientId  @param {string} o.clientSecret
   * @param {string} o.meetingUuid  @param {string} o.streamId
   * @param {string[]|string} o.serverUrls   rtms_started.server_urls(逗号分隔字符串或数组)
   * @param {{transcript?: boolean, audio?: boolean}} [o.media]   缺省只要转写
   * @param {object} [o.transcriptParams]  例 {src_language, enable_lid};content_type 恒为 5
   * @param {object} [o.audioParams]       缺省 {content_type:2, sample_rate:1, channel:1, codec:1, data_opt:2, send_rate:20}
   */
  constructor({
    clientId, clientSecret, meetingUuid, streamId, serverUrls, media = { transcript: true, audio: false },
    transcriptParams = {}, audioParams = {}, subscribe = DEFAULT_SUBSCRIBE, WebSocket = DefaultWebSocket,
    backoff = {}, keepAliveTimeoutMs = 65_000, handshakeTimeoutMs = 15_000, maxReconnectMs = 5 * 60_000,
    audioEndian = 'le', sendCloseReq = true, log = () => {},
  } = {}) {
    super();
    if (!clientId || !clientSecret) throw new TypeError('RtmsClient: clientId / clientSecret required');
    if (!meetingUuid || !streamId) throw new TypeError('RtmsClient: meetingUuid / streamId required');
    const urls = (Array.isArray(serverUrls) ? serverUrls : String(serverUrls ?? '').split(',')).map((s) => String(s).trim()).filter(Boolean);
    if (!urls.length) throw new TypeError('RtmsClient: serverUrls required');
    Object.assign(this, { clientId, clientSecret, meetingUuid, streamId, serverUrls: urls, WS: WebSocket, log, keepAliveTimeoutMs, handshakeTimeoutMs, maxReconnectMs, audioEndian, sendCloseReq, subscribe: [...subscribe] });
    this.wantTranscript = media.transcript !== false;
    this.wantAudio = media.audio === true;
    if (!this.wantTranscript && !this.wantAudio) throw new TypeError('RtmsClient: need transcript and/or audio');
    this.transcriptParams = { content_type: 5, enable_lid: true, ...transcriptParams };
    this.audioParams = { content_type: 2, sample_rate: 1, channel: 1, codec: 1, data_opt: 2, send_rate: 20, ...audioParams };
    this.backoff = { initialMs: 3000, maxMs: 30_000, ...backoff };
    this.seq = 0;
    this.gen = 0;
    this.attempt = 0;
    this.failingSince = null;
    this.sig = null;
    this.media = null;
    this.timers = new Set();
    this.kaTimer = null;
    this.hsTimer = null;
    this.isReady = false;
    this.stopped = false;
    this.connects = 0; // 成功握手次数(1 = 首次,>1 = 重连过)
    this.signature = rtmsSignature(clientId, clientSecret, meetingUuid, streamId);
  }

  get mediaType() { return (this.wantTranscript ? MEDIA.TRANSCRIPT : 0) | (this.wantAudio ? MEDIA.AUDIO : 0); }

  start() {
    if (this.stopped) throw new Error('RtmsClient: already stopped');
    this._connect();
    return this;
  }

  /// 等 'ready'(或 'stopped' → reject)
  waitReady(timeoutMs = 30_000) {
    if (this.isReady) return Promise.resolve();
    if (this.stopped) return Promise.reject(new Error(`rtms stopped: ${this.stopInfo?.reason}`));
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { cleanup(); reject(new Error('rtms ready timeout')); }, timeoutMs);
      const ok = () => { cleanup(); resolve(); };
      const bad = (s) => { cleanup(); reject(Object.assign(new Error(`rtms stopped: ${s?.reason}`), { info: s })); };
      const cleanup = () => { clearTimeout(t); this.off('ready', ok); this.off('stopped', bad); };
      this.on('ready', ok);
      this.on('stopped', bad);
    });
  }

  // ── 内部 ──
  _later(fn, ms) { const t = setTimeout(() => { this.timers.delete(t); fn(); }, ms); t.unref?.(); this.timers.add(t); return t; }
  _send(ws, obj) { try { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); } catch (e) { this.log(`send failed: ${e.message}`); } }
  _nextSeq() { this.seq = (this.seq + 1) % 2 ** 31; return this.seq; }

  _connect() {
    const gen = ++this.gen;
    this.isReady = false;
    const url = this.serverUrls[this.attempt % this.serverUrls.length];
    let ws;
    try { ws = new this.WS(url); } catch (e) { this._retry(`signaling_connect: ${e.message}`); return; }
    this.sig = ws;
    this._armHandshakeTimer(gen);
    ws.on('open', () => {
      if (gen !== this.gen) return;
      this._send(ws, { msg_type: MSG.SIGNALING_HAND_SHAKE_REQ, protocol_version: 1, sequence: this._nextSeq(), meeting_uuid: this.meetingUuid, rtms_stream_id: this.streamId, signature: this.signature });
    });
    ws.on('message', (data) => { if (gen === this.gen) this._onSignaling(ws, data, gen); });
    ws.on('error', (e) => { if (gen === this.gen) this.log(`signaling error: ${e.message}`); });
    ws.on('close', (code) => { if (gen === this.gen && !this.stopped) this._retry(`signaling_closed:${code}`); });
  }

  _armHandshakeTimer(gen) {
    clearTimeout(this.hsTimer);
    this.hsTimer = setTimeout(() => { if (gen === this.gen && !this.isReady && !this.stopped) this._retry('handshake_timeout'); }, this.handshakeTimeoutMs);
    this.hsTimer.unref?.();
  }

  _armKeepAliveWatchdog(gen) {
    clearTimeout(this.kaTimer);
    this.kaTimer = setTimeout(() => { if (gen === this.gen && !this.stopped) this._retry('keepalive_timeout'); }, this.keepAliveTimeoutMs);
    this.kaTimer.unref?.();
  }

  _parse(data) { try { const m = JSON.parse(String(data)); return m && typeof m === 'object' ? m : null; } catch { return null; } }

  _onSignaling(ws, data, gen) {
    const m = this._parse(data);
    if (!m) return;
    switch (m.msg_type) {
      case MSG.SIGNALING_HAND_SHAKE_RESP: {
        const code = Number(m.status_code ?? 0);
        if (code !== 0) {
          if (FATAL_STATUS.has(code)) return this._stop({ reason: 'signaling_handshake_failed', statusCode: code });
          return this._retry(`signaling_status_${code}`);
        }
        const urls = m.media_server?.server_urls ?? {};
        const mediaUrl = this.wantAudio
          ? (urls.all || (this.wantTranscript ? null : urls.audio) || urls.transcript || urls.audio)
          : (urls.transcript || urls.all);
        if (!mediaUrl) return this._stop({ reason: 'no_media_url' });
        this._armKeepAliveWatchdog(gen);
        return this._connectMedia(mediaUrl, gen);
      }
      case MSG.KEEP_ALIVE_REQ:
        this._armKeepAliveWatchdog(gen);
        return this._send(ws, { msg_type: MSG.KEEP_ALIVE_RESP, timestamp: m.timestamp });
      case MSG.EVENT_UPDATE: return this._onEvent(m.event);
      case MSG.STREAM_STATE_UPDATE: {
        this.emit('state', { kind: 'stream', state: m.state, reason: m.reason });
        if (m.state === STREAM_STATE.TERMINATED) return this._stop({ reason: 'stream_terminated', stopReason: m.reason ?? null }, { closeReq: false });
        return undefined;
      }
      case MSG.SESSION_STATE_UPDATE: {
        this.emit('state', { kind: 'session', state: m.state, reason: m.stop_reason });
        if (m.state === SESSION_STATE.STOPPED) return this._stop({ reason: 'session_stopped', stopReason: m.stop_reason ?? null }, { closeReq: false });
        return undefined;
      }
      case MSG.STREAM_CLOSE_RESP: return undefined;
      default: return undefined;
    }
  }

  _connectMedia(url, gen) {
    let ws;
    try { ws = new this.WS(url); } catch (e) { this._retry(`media_connect: ${e.message}`); return; }
    this.media = ws;
    ws.on('open', () => {
      if (gen !== this.gen) return;
      const media_params = {};
      if (this.wantAudio) media_params.audio = this.audioParams;
      if (this.wantTranscript) media_params.transcript = this.transcriptParams;
      this._send(ws, { msg_type: MSG.DATA_HAND_SHAKE_REQ, protocol_version: 1, sequence: this._nextSeq(), meeting_uuid: this.meetingUuid, rtms_stream_id: this.streamId, signature: this.signature, media_type: this.mediaType, media_params });
    });
    ws.on('message', (data) => { if (gen === this.gen) this._onMedia(ws, data, gen); });
    ws.on('error', (e) => { if (gen === this.gen) this.log(`media error: ${e.message}`); });
    ws.on('close', (code) => { if (gen === this.gen && !this.stopped) this._retry(`media_closed:${code}`); });
  }

  _onMedia(ws, data, gen) {
    const m = this._parse(data);
    if (!m) return;
    switch (m.msg_type) {
      case MSG.DATA_HAND_SHAKE_RESP: {
        const code = Number(m.status_code ?? 0);
        if (code !== 0) {
          if (FATAL_STATUS.has(code)) return this._stop({ reason: 'data_handshake_failed', statusCode: code });
          return this._retry(`data_status_${code}`);
        }
        this._send(this.sig, { msg_type: MSG.CLIENT_READY_ACK, rtms_stream_id: this.streamId });
        if (this.subscribe.length) this._send(this.sig, { msg_type: MSG.EVENT_SUBSCRIPTION, events: this.subscribe.map((event_type) => ({ event_type, subscribe: true })) });
        clearTimeout(this.hsTimer);
        this.isReady = true;
        this.attempt = 0;
        this.failingSince = null;
        this.connects += 1;
        this.emit('ready', { reconnected: this.connects > 1 });
        return undefined;
      }
      case MSG.KEEP_ALIVE_REQ: return this._send(ws, { msg_type: MSG.KEEP_ALIVE_RESP, timestamp: m.timestamp });
      case MSG.MEDIA_DATA_TRANSCRIPT: {
        const c = m.content ?? {};
        const text = String(c.data ?? '');
        if (!text.trim()) return undefined;
        return this.emit('transcript', { userId: String(c.user_id ?? ''), userName: String(c.user_name ?? ''), text, timestamp: c.timestamp ?? null, startTime: c.start_time ?? null, endTime: c.end_time ?? null, language: c.language ?? null });
      }
      case MSG.MEDIA_DATA_AUDIO: {
        const c = m.content ?? {};
        return this.emit('audio', { userId: String(c.user_id ?? ''), userName: String(c.user_name ?? ''), pcm: decodeL16(c.data, this.audioEndian), sampleRate: SAMPLE_RATE[this.audioParams.sample_rate] ?? 16000, channels: 1, timestamp: c.timestamp ?? null });
      }
      case MSG.EVENT_UPDATE: return this._onEvent(m.event);
      case MSG.STREAM_STATE_UPDATE: case MSG.SESSION_STATE_UPDATE: return this._onSignaling(this.sig, data, gen);
      default: return undefined;
    }
  }

  _onEvent(ev) {
    if (!ev || typeof ev !== 'object') return;
    const people = Array.isArray(ev.participants) ? ev.participants : (ev.user_id != null ? [{ user_id: ev.user_id, user_name: ev.user_name }] : []);
    const norm = (p) => ({ userId: String(p?.user_id ?? ''), userName: String(p?.user_name ?? '') });
    switch (ev.event_type) {
      case EVENT.PARTICIPANT_JOIN: for (const p of people.map(norm)) if (p.userId) this.emit('join', p); break;
      case EVENT.PARTICIPANT_LEAVE: for (const p of people.map(norm)) if (p.userId) this.emit('leave', p); break;
      case EVENT.ACTIVE_SPEAKER_CHANGE: { const p = norm(people[0] ?? ev); if (p.userId) this.emit('speaker', { ...p, timestamp: ev.timestamp ?? null }); break; }
      default: break;
    }
  }

  _teardown() {
    clearTimeout(this.kaTimer);
    clearTimeout(this.hsTimer);
    for (const ws of [this.media, this.sig]) {
      if (!ws) continue;
      try { ws.removeAllListeners('message'); ws.on('error', () => {}); ws.terminate?.() ?? ws.close(); } catch { /* */ }
    }
    this.media = null;
    this.sig = null;
  }

  _retry(why) {
    if (this.stopped) return;
    const wasReady = this.isReady;
    this.gen += 1; // 旧连接的回调从此全部作废
    this.isReady = false;
    this._teardown();
    const now = Date.now();
    this.failingSince ??= now;
    if (now - this.failingSince > this.maxReconnectMs) { this._stop({ reason: 'reconnect_exhausted', why }); return; }
    const delayMs = backoffDelay(this.attempt, this.backoff);
    this.attempt += 1;
    this.log(`rtms reconnect in ${delayMs} ms (${why}${wasReady ? ', was ready' : ''})`);
    this.emit('reconnecting', { attempt: this.attempt, delayMs, why });
    this._later(() => { if (!this.stopped) this._connect(); }, delayMs);
  }

  _stop(info, { closeReq = true } = {}) {
    if (this.stopped) return;
    if (closeReq && this.sendCloseReq && this.isReady) {
      // STREAM_CLOSE_REQ(21):05 只列了编号,字段未核实(UNCONFIRMED);尽力而为,失败无妨
      this._send(this.sig, { msg_type: MSG.STREAM_CLOSE_REQ, rtms_stream_id: this.streamId, meeting_uuid: this.meetingUuid });
    }
    this.stopped = true;
    this.isReady = false;
    this.gen += 1;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    const name = info.stopReason != null ? STOP_REASON[info.stopReason] : undefined;
    this.stopInfo = { ...info, ...(name ? { stopReasonName: name } : {}) };
    // 先让 21 写出去再断
    const sig = this.sig;
    if (closeReq && sig?.readyState === 1) { this.sig = null; setTimeout(() => { try { sig.terminate(); } catch { /* */ } }, 50).unref?.(); }
    this._teardown();
    this.emit('stopped', this.stopInfo);
  }

  /// 主动停(Ember 离会 / 宿主退出)
  stop(reason = 'client_stop') { this._stop({ reason }); }
}
