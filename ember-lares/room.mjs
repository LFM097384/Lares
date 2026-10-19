// ember-lares · Lares 房间:LaresRoom(信令 HMAC / aiAuth、LiveKit)的子类。
// LaresRoom 按相对路径从 ../lares-bridge 引入(与灶语共用的单一实现;见 README「依赖」)。
// 与灶语(语音 AI)的差别:
//  - E2EE 可用「密封密钥」入房:信令就绪后发 anon_agent_hello {circleId, x25519Pub},等 anon_agent_key 解封得媒体密钥 hex;
//  - 不发布音轨(agent 不说话);
//  - 收发 LiveKit data topic `lares.anon`(JSON,reliable),事件 'anon'(identity, msg);
//  - deviceId 前缀 d_anon_,与语音 bot 区分。
import crypto from 'node:crypto';
import { LaresRoom, loadRtcNode, e2eeKeyHex, authVerifier, ROOM_RATE } from '../lares-bridge/index.mjs';
import { generateX25519, unseal } from '../ember/index.mjs';

/// 线协议名不变(app / 服务器兼容):data topic、agent userId 前缀、deviceId 前缀
export const ANON_TOPIC = 'lares.anon';

export const anonAgentUserId = (circleId) => `u_ai_anon_${crypto.createHash('sha256').update(circleId).digest('hex').slice(0, 8)}`;
const MAX_MSG_BYTES = 16 * 1024;

export class AnonRoom extends LaresRoom {
  /** o.sealedKey: true = E2EE 媒体密钥走密封流程;o.keyTimeoutMs */
  constructor(o) {
    super(o);
    this.deviceId = `d_anon_${crypto.createHash('sha256').update(`dev:${this.circleId}:${this.userId}`).digest('hex').slice(0, 12)}`;
    this.handlers.anon = [];
    this.handlers.server = [];
    this.names = new Map();
  }

  nameOf(id) { return this.names.get(id) ?? ''; }
  participants() {
    return [...(this.room?.remoteParticipants?.values?.() ?? [])].map((p) => ({ id: p.identity, name: p.name ?? '' }));
  }

  /// 信令 WS 上发 anon_* 元数据(anon_active / anon_released_notice)
  notifyServer(msg) {
    try { this.ws?.send(JSON.stringify(msg)); } catch (e) { this.log(`信令发送失败: ${e.message}`); }
  }

  /// 等封好的媒体密钥:hello → (圈主客户端封装)→ anon_agent_key
  _awaitSealedKey() {
    const kp = generateX25519();
    const timeoutMs = this.keyTimeoutMs ?? 5 * 60_000;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { cleanup(); reject(Object.assign(new Error('sealed_key_timeout'), { code: 'no_key' })); }, timeoutMs);
      timer.unref?.();
      const onMsg = (raw) => {
        let m;
        try { m = JSON.parse(raw); } catch { return; }
        if (m?.circleId !== this.circleId) return;
        if (m.t === 'anon_agent_key') {
          if (m.x25519Pub !== undefined && m.x25519Pub !== kp.pubB64) return; // 封给旧钥匙的
          try {
            const hex = unseal(m.sealed, kp, this.circleId);
            cleanup();
            resolve(hex);
          } catch { this.log('密封密钥解封失败,继续等待'); this._fire('server', { t: 'unseal_failed' }); }
        } else if (m.t === 'anon_error' && m.op === 'anon_agent_hello') {
          cleanup();
          reject(Object.assign(new Error(`anon_hello_${m.code}`), { code: m.code }));
        }
      };
      const cleanup = () => { clearTimeout(timer); this.ws?.off?.('message', onMsg); };
      this.ws.on('message', onMsg);
      this.notifyServer({ t: 'anon_agent_hello', circleId: this.circleId, x25519Pub: kp.pubB64 });
      this.log('已发 anon_agent_hello,等圈主封装媒体密钥');
    });
  }

  async join() {
    const rtc = await loadRtcNode();
    if (!rtc) throw new Error('rtc_node_unavailable');
    this.rtc = rtc;
    if (!this.authSecret && this.passcode) {
      this.authSecret = this.authV === 2 ? await authVerifier(this.passcode, this.circleId) : this.passcode;
    }
    const tok = await this._signal();
    // 其余信令消息(anon_error / anon_ok 等)转出去
    this.ws.on('message', (raw) => { let m; try { m = JSON.parse(raw); } catch { return; } if (typeof m?.t === 'string' && m.t.startsWith('anon_') && m.t !== 'anon_agent_key') this._fire('server', m); });
    const { Room, RoomEvent, TrackKind, AudioStream } = rtc;
    const opts = { autoSubscribe: true };
    if (this.e2ee) {
      const hex = this.mediaKeyHex
        ?? (this.sealedKey ? await this._awaitSealedKey() : this.passcode ? await e2eeKeyHex(this.passcode, this.circleId) : null);
      if (!hex) throw new Error('e2ee_requires_key');
      opts.encryption = { keyProviderOptions: { sharedKey: new TextEncoder().encode(hex) } };
    }
    const room = new Room();
    this.room = room;
    room.on(RoomEvent.TrackSubscribed, (track, _pub, p) => {
      if (track.kind !== TrackKind.KIND_AUDIO) return;
      const id = p?.identity;
      if (!id || id === this.userId || id.startsWith('u_ai_') || id.startsWith('bot:') || this.streams.has(id)) return;
      if (p.name) { this.names.set(id, p.name); this._fire('names', id, p.name); }
      const stream = new AudioStream(track, { sampleRate: ROOM_RATE, numChannels: 1 });
      this.streams.set(id, stream);
      (async () => {
        try { for await (const f of stream) { if (this.closed) break; this._fire('audio', id, f.data, f.sampleRate, f.channels); } }
        catch (e) { if (!this.closed) this.log(`音频流出错: ${e.message}`); } finally { this.streams.delete(id); }
      })();
    });
    room.on(RoomEvent.TrackUnsubscribed, (_t, _pub, p) => {
      const s = this.streams.get(p?.identity);
      if (s) { this.streams.delete(p.identity); s.close?.(); }
    });
    room.on(RoomEvent.ParticipantConnected, (p) => {
      if (!p?.identity) return;
      if (p.name) this.names.set(p.identity, p.name);
      this._fire('joined', p.identity);
    });
    room.on(RoomEvent.ParticipantDisconnected, (p) => { this.names.delete(p.identity); this._fire('left', p.identity); });
    room.on(RoomEvent.Disconnected, (r) => { if (!this.closed) this._fire('disconnected', r); });
    room.on(RoomEvent.DataReceived, (payload, p, _kind, topic) => this._data(payload, p?.identity ?? null, topic));
    await room.connect(tok.url, tok.token, opts);
    for (const p of room.remoteParticipants?.values?.() ?? []) if (p.name) this.names.set(p.identity, p.name);
    return this;
  }

  _data(payload, from, topic) {
    if (topic !== ANON_TOPIC) return super._data(payload, from, topic);
    if (!from || from === this.userId || payload?.length > MAX_MSG_BYTES) return;
    let m;
    try { m = JSON.parse(Buffer.from(payload).toString('utf8')); } catch { return; }
    if (m && typeof m === 'object' && typeof m.t === 'string') this._fire('anon', from, m);
  }

  async publishAnon(obj, to = null) {
    if (this.closed || !this.room) return;
    const opts = { reliable: true, topic: ANON_TOPIC };
    if (to) opts.destination_identities = [to];
    await this.room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(obj)), opts);
  }
}
