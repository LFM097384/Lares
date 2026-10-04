// 房间适配器:信令(HMAC 挑战应答,与真人客户端同一套)+ LiveKit(rtc-node)进房、发布音轨、收发数据。
// 不 import server/tool/lares_bot.mjs:那个文件静态 import rtc-node,会和这里动态加载的副本打架;
// 帧格式 / 证明算法与它完全一致(server/src/index.js verifyAuth、app chat_envelope.dart)。

import crypto from 'node:crypto';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import WebSocket from 'ws';
import { argon2id } from 'hash-wasm';
import { ROOM_RATE, FRAME_SAMPLES } from './audio.mjs';

export const CHAT_TOPIC = 'lares.chat';
export const CAPTION_TOPIC = 'lares.cap';
export const AI_STATE_TOPIC = 'lares.ai'; // {t:'state', state, seq}(CONTRACT §5)
const ARGON2 = { parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32, outputType: 'hex' };
const hmacHex = (k, m) => crypto.createHmac('sha256', k).update(m, 'utf8').digest('hex');

export const authVerifier = (passcode, circleId) => argon2id({ password: passcode, salt: `lares-auth-v2:${circleId}`, ...ARGON2 });
export function e2eeKeyHex(passcode, circleId) {
  const salt = crypto.createHash('sha256').update(`lares-e2ee-v2:${circleId}`, 'utf8').digest().subarray(0, 16);
  return argon2id({ password: passcode, salt, ...ARGON2 });
}
export function encodeChatFrame(header) {
  const h = Buffer.from(JSON.stringify(header), 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(h.length, 0);
  return new Uint8Array(Buffer.concat([len, h]));
}
export function decodeChatFrame(bytes) {
  const b = Buffer.from(bytes);
  if (b.length < 4) return null;
  const n = b.readUInt32BE(0);
  if (n === 0 || n > b.length - 4) return null;
  try { return { header: JSON.parse(b.subarray(4, 4 + n).toString('utf8')) }; } catch { return null; }
}

/// 默认 userId:u_ai_<sha256(circleId) 前 8 hex>(CONTRACT §1)
export const defaultAiUserId = (circleId) => `u_ai_${crypto.createHash('sha256').update(circleId).digest('hex').slice(0, 8)}`;

let rtcPromise = null;
/// 与 server/src/bot_speak.js loadRtcNode() 同策略:先服务端依赖,再退回 server/tool。
export function loadRtcNode() {
  rtcPromise ??= (async () => {
    try { return await import('@livekit/rtc-node'); } catch { /* 退回 tool 目录 */ }
    try {
      const here = path.dirname(fileURLToPath(import.meta.url));
      const req = createRequire(path.join(here, '..', '..', 'tool', 'package.json'));
      return await import(pathToFileURL(req.resolve('@livekit/rtc-node')).href);
    } catch { return null; }
  })();
  return rtcPromise;
}

export class AuthError extends Error {}
export class CircleGoneError extends Error {}
export class E2eeRequiredError extends Error {}

export class LaresRoom {
  /**
   * @param {object} o
   * @param {string} o.circleId
   * @param {string} o.userId
   * @param {string} o.name
   * @param {string} o.signaling
   * @param {string} [o.authSecret]   HMAC 密钥(v2 = verifier hex;v1 = 口令)
   * @param {1|2} [o.authV]
   * @param {string} [o.passcode]     独立模式:由口令派生(v2 时算 verifier)
   * @param {string} [o.memberSecret] 服务端托管:u_ai_* 身份凭证(env LARES_AI_MEMBER_SECRET)
   * @param {boolean} [o.e2ee]
   * @param {(m:string)=>void} [o.log]
   */
  constructor(o) {
    Object.assign(this, { joinTimeoutMs: 15000, log: () => {}, ...o });
    // 稳定的 deviceId:同一圈的 AI 重启后仍是同一台「设备」
    this.deviceId = `d_ai_${crypto.createHash('sha256').update(`dev:${this.circleId}:${this.userId}`).digest('hex').slice(0, 12)}`;
    this.handlers = { audio: [], chat: [], capctl: [], left: [], names: [], joined: [], disconnected: [] };
    this.streams = new Map();
    this.closed = false;
  }

  on(kind, cb) { this.handlers[kind].push(cb); return this; }
  _fire(kind, ...a) { for (const h of this.handlers[kind]) { try { h(...a); } catch (e) { this.log(`处理器出错(${kind}): ${e.message}`); } } }

  async join() {
    const rtc = await loadRtcNode();
    if (!rtc) throw new Error('rtc_node_unavailable');
    this.rtc = rtc;
    if (!this.authSecret && this.passcode) {
      this.authSecret = this.authV === 2 ? await authVerifier(this.passcode, this.circleId) : this.passcode;
    }
    const tok = await this._signal();
    const { Room, RoomEvent, AudioSource, LocalAudioTrack, TrackPublishOptions, TrackSource, TrackKind, AudioStream } = rtc;
    const opts = { autoSubscribe: true };
    if (this.e2ee) {
      if (!this.passcode) throw new Error('e2ee_requires_passcode');
      const hex = await e2eeKeyHex(this.passcode, this.circleId);
      opts.encryption = { keyProviderOptions: { sharedKey: new TextEncoder().encode(hex) } }; // 必须给 connect()
    }
    const room = new Room();
    this.room = room;
    // 监听必须在 connect 之前挂
    room.on(RoomEvent.TrackSubscribed, (track, _pub, p) => {
      if (track.kind !== TrackKind.KIND_AUDIO) return;
      const id = p?.identity;
      // 不听自己,也不听别的 AI(u_ai_*):两个机器人不互相对话
      if (!id || id === this.userId || id.startsWith('u_ai_') || id.startsWith('bot:') || this.streams.has(id)) return;
      if (p.name) this._fire('names', id, p.name);
      const stream = new AudioStream(track, { sampleRate: ROOM_RATE, numChannels: 1 });
      this.streams.set(id, stream);
      (async () => {
        try {
          for await (const f of stream) {
            if (this.closed) break;
            this._fire('audio', id, f.data, f.sampleRate, f.channels);
          }
        } catch (e) { if (!this.closed) this.log(`音频流出错: ${e.message}`); } finally { this.streams.delete(id); }
      })();
    });
    room.on(RoomEvent.TrackUnsubscribed, (_t, _pub, p) => {
      const s = this.streams.get(p?.identity);
      if (s) { this.streams.delete(p.identity); s.close?.(); }
    });
    room.on(RoomEvent.ParticipantConnected, (p) => {
      if (p?.name) this._fire('names', p.identity, p.name);
      if (p?.identity) this._fire('joined', p.identity); // 晚进房的人补发一次 lares.ai 状态
    });
    room.on(RoomEvent.ParticipantDisconnected, (p) => { this._fire('left', p.identity); });
    room.on(RoomEvent.Disconnected, (r) => { if (!this.closed) this._fire('disconnected', r); });
    room.on(RoomEvent.DataReceived, (payload, p, _kind, topic) => this._data(payload, p?.identity ?? null, topic));
    await room.connect(tok.url, tok.token, opts);
    for (const p of room.remoteParticipants?.values?.() ?? []) if (p.name) this._fire('names', p.identity, p.name);

    // 发布自己的声音:队列只留 ~200ms,打断时 clearQueue 后很快就安静
    this.source = new AudioSource(ROOM_RATE, 1, 200);
    this.track = LocalAudioTrack.createAudioTrack('ai-voice', this.source);
    await room.localParticipant.publishTrack(this.track, new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }));
    return this;
  }

  _signal() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.signaling);
      this.ws = ws;
      let settled = false;
      const fail = (e) => { if (settled) return; settled = true; try { ws.close(); } catch { /* */ } reject(e); };
      const timer = setTimeout(() => fail(new Error('join_timeout')), this.joinTimeoutMs);
      ws.on('error', fail);
      ws.on('close', (code) => fail(
        code === 4401 ? new AuthError('auth_failed')
          : code === 4410 ? new CircleGoneError('circle_deleted')
            : new Error(`signaling_closed:${code}`)));
      ws.on('message', (raw) => {
        let m;
        try { m = JSON.parse(raw); } catch { return; }
        if (m.t === 'challenge') {
          let auth = null;
          if (m.authRequired !== false) {
            const modes = Array.isArray(m.modes) ? m.modes : ['circle'];
            if (!modes.includes('circle') || !this.authSecret) return fail(new AuthError('no_credentials'));
            // v1 / v2 证明算法相同,只是密钥不同(口令 / verifier hex)
            auth = { mode: 'circle', nonce: m.nonce, circleId: this.circleId, proof: hmacHex(this.authSecret, `${m.nonce}:${this.userId}:${this.circleId}`) };
            if (this.authV === 2) auth.v = 2;
          }
          // 服务端托管:u_ai_* 身份要额外出示圈级凭证(env LARES_AI_MEMBER_SECRET),否则 hello 被拒 userId_reserved
          const aiAuth = this.memberSecret ? { circleId: this.circleId, proof: hmacHex(this.memberSecret, `${m.nonce}:${this.userId}:${this.circleId}`) } : null;
          ws.send(JSON.stringify({ t: 'hello', userId: this.userId, deviceId: this.deviceId, name: String(this.name).slice(0, 24), platform: 'ai', ...(auth ? { auth } : {}), ...(aiAuth ? { aiAuth } : {}) }));
        } else if (m.t === 'welcome') {
          if (m.circle?.e2ee === true && !this.e2ee) return fail(new E2eeRequiredError('circle_requires_e2ee: start with --passcode <p> --e2ee'));
          ws.send(JSON.stringify({ t: 'join', circleId: this.circleId }));
        } else if (m.t === 'knock_waiting' && !settled) {
          this.log('圈子开了敲门模式,AI 不能自行进入');
          fail(new Error('knock_waiting'));
        } else if (m.t === 'error' && !settled) {
          const r = String(m.message ?? m.reason ?? 'error');
          fail(r === 'circle_deleted' ? new CircleGoneError(r) : /auth/.test(r) ? new AuthError(r) : new Error(`signaling_error:${r}`));
        } else if (m.t === 'token' && m.prefetch !== true && !settled) {
          settled = true;
          clearTimeout(timer);
          // 信令连接不能关:presence 就是它
          ws.removeAllListeners('close');
          ws.on('close', (code) => { if (!this.closed) this._fire('disconnected', code === 4410 ? 'circle_deleted' : 'signaling'); });
          this._ping = setInterval(() => { try { ws.send(JSON.stringify({ t: 'ping' })); } catch { /* */ } }, 25_000);
          this._ping.unref?.();
          resolve(m);
        }
      });
    });
  }

  _data(payload, from, topic) {
    if (from === this.userId) return;
    if (topic === CHAT_TOPIC) {
      const h = decodeChatFrame(payload)?.header;
      if (!h || h.t !== 'text' || typeof h.body !== 'string') return;
      const claimsBot = h.bot === true || (typeof h.sid === 'string' && h.sid.startsWith('bot:'));
      if (from !== null && claimsBot) return;
      if (from === null && h.bot !== true) return;
      if (from && h.sn) this._fire('names', from, h.sn);
      this._fire('chat', { id: h.id, senderId: h.sid, senderName: h.sn, body: h.body, bot: from === null, from });
    } else if (topic === CAPTION_TOPIC && from) {
      let m;
      try { m = JSON.parse(Buffer.from(payload).toString('utf8')); } catch { return; }
      if (m && (m.t === 'capack' || m.t === 'capreq')) this._fire('capctl', from, m);
    }
  }

  /// pipeline 的音频出口
  sink() {
    const { AudioFrame } = this.rtc;
    return {
      // frame 是独立的 Int16Array(Player 每帧新建),符合「slice 不 subarray」
      captureFrame: (pcm) => (this.closed ? undefined : this.source.captureFrame(new AudioFrame(pcm, ROOM_RATE, 1, FRAME_SAMPLES))),
      clear: () => { try { this.source.clearQueue(); } catch { /* */ } },
      queuedMs: () => { try { return this.source.queuedDuration || 0; } catch { return 0; } },
    };
  }

  async publishCaption(cap) {
    if (this.closed || !this.room) return;
    await this.room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(cap)), { reliable: true, topic: CAPTION_TOPIC });
  }

  /// lares.ai 状态帧(reliable, JSON UTF-8)。只含状态与 seq,不含任何文字内容。
  async publishState(frame) {
    if (this.closed || !this.room) return;
    await this.room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(frame)), { reliable: true, topic: AI_STATE_TOPIC });
  }

  async sendChat(text) {
    if (this.closed || !this.room) return;
    const header = { v: 1, t: 'text', id: crypto.randomUUID(), sid: this.userId, sn: this.name, cid: this.circleId, ts: Date.now(), body: String(text) };
    await this.room.localParticipant.publishData(encodeChatFrame(header), { reliable: true, topic: CHAT_TOPIC });
  }

  /// 改显示名(config.name 变了)
  rename(name) {
    this.name = name;
    try { this.room?.localParticipant?.updateName?.(name); } catch { /* */ }
  }

  async leave() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this._ping);
    for (const s of this.streams.values()) { try { await s.close?.(); } catch { /* */ } }
    this.streams.clear();
    try { await this.source?.close?.(); } catch { /* */ }
    try { await this.room?.disconnect(); } catch { /* */ }
    try { this.ws?.send(JSON.stringify({ t: 'leave', circleId: this.circleId })); } catch { /* */ }
    try { this.ws?.close(); } catch { /* */ }
  }
}
