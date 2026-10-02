// Lares Bot SDK —— 让一个程序以「圈子成员」的身份进房、说话、听声。
//
// ## 定位(重要,别搞混)
//
// 本文件**只服务于自动化测试与压测**:多个 bot 同时进房、发已知波形、
// 验证「谁在说话」的链路。它刻意保持零新增依赖(只用 ws + rtc-node),
// 这样 CI 里跑压测足够快。
//
// **AI 炉灵不要建在这上面** —— 用 LiveKit 官方的 `@livekit/agents`:
// 它自带 STT/LLM/TTS 插件生态、Silero VAD、语义化轮次检测、Worker 编排,
// 那些东西没必要自己造。详见 docs/plans/lares-spirit.md。
// 两者底层都是 rtc-node,所以下面记的那些坑对两边都适用。
//
// ## 一条不能含糊的设计原则
//
// **bot 是参与者,不是服务器的一部分。**
// 它跟真人客户端走**同一套** HMAC 挑战应答,没有后门、没有特权通道。
// 这不是洁癖:将来上了 E2EE,密钥由圈口令派生,而只有真正持有口令的
// 参与者才解得开内容。如果 bot 走后门进房,它就必须由服务器持有密钥,
// E2EE 当场失效。所以"bot 必须自己认证"这件事,是 E2EE 成立的前提。
//
// ## 用法
//
//   import { LaresBot } from './lares_bot.mjs';
//   const bot = new LaresBot({ circleId: 'home', name: '炉灵', passcode: '...' });
//   await bot.join();
//   await bot.speak(pcm16);          // 发声
//   bot.onAudio((frame, from) => {}); // 听声
//   bot.onChat((m) => {});            // 收聊天(含服务器代发的机器人消息,m.bot === true)
//   bot.onCaption((c) => {});         // 收字幕(lares.cap)
//   await bot.sendChat('你好');        // 发聊天(与 App 同一帧格式)
//   await bot.sendCaption('一句话', { final: true });
//   await bot.leave();
//
// 注册圈(App 新建的 c_xxx 圈)只认 v2 证明:传 authVersion: 2。
// E2EE 圈:传 e2ee: true(密钥由 passcode 派生,与 App 相同),数据通道与音频一并加解密。
// 不持有口令的程序要和 E2EE 圈打交道只能走这里;REST API(docs/bot-api.md)对 E2EE 圈一律 409。

import crypto from 'node:crypto';
import WebSocket from 'ws';
import {
  Room,
  RoomEvent,
  AudioSource,
  AudioStream,
  LocalAudioTrack,
  TrackPublishOptions,
  TrackSource,
  TrackKind,
  AudioFrame,
} from '@livekit/rtc-node';
// 纯 WASM Argon2;tool/ 下没装时会沿目录向上落到 server/node_modules(服务端依赖)
import { argon2id } from 'hash-wasm';

export const CHAT_TOPIC = 'lares.chat';
export const CAPTION_TOPIC = 'lares.cap';

/// 与 App(app/lib/src/e2ee/e2ee_key.dart)和服务端一致的 Argon2 参数
const ARGON2 = { parallelism: 1, iterations: 3, memorySize: 64 * 1024, hashLength: 32, outputType: 'hex' };

/// v2 鉴权 verifier = hex(Argon2id(口令, "lares-auth-v2:"+circleId))
export function authVerifier(passcode, circleId) {
  return argon2id({ password: passcode, salt: `lares-auth-v2:${circleId}`, ...ARGON2 });
}

/// E2EE 共享密钥(64 位 hex)= Argon2id(口令, sha256("lares-e2ee-v2:"+circleId) 前 16 字节)。
/// 交给 LiveKit 的是这串 hex 的 **ASCII 字节**(App 的 setSharedKey 内部做 key.codeUnits)。
export function e2eeKeyHex(passcode, circleId) {
  const salt = crypto.createHash('sha256').update(`lares-e2ee-v2:${circleId}`, 'utf8').digest().subarray(0, 16);
  return argon2id({ password: passcode, salt, ...ARGON2 });
}

/// 聊天帧:4 字节大端 header 长度 + UTF-8 JSON header + payload(app/lib/src/chat/chat_envelope.dart)
export function encodeChatFrame(header, payload = new Uint8Array(0)) {
  const h = Buffer.from(JSON.stringify(header), 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(h.length, 0);
  return new Uint8Array(Buffer.concat([len, h, Buffer.from(payload)]));
}

export function decodeChatFrame(bytes) {
  const b = Buffer.from(bytes);
  if (b.length < 4) return null;
  const n = b.readUInt32BE(0);
  if (n === 0 || n > b.length - 4) return null;
  try {
    return { header: JSON.parse(b.subarray(4, 4 + n).toString('utf8')), payload: b.subarray(4 + n) };
  } catch {
    return null;
  }
}

/// LiveKit 要求的采样率。48kHz 是 WebRTC 的原生档位,
/// 用别的值会让 SDK 内部重采样,白白引入延迟和失真。
export const SAMPLE_RATE = 48000;
export const CHANNELS = 1;
/// 10ms 一帧 —— WebRTC 的标准帧长。480 = 48000 * 0.01
export const FRAME_SAMPLES = 480;

const hmacHex = (key, msg) =>
  crypto.createHmac('sha256', key).update(msg).digest('hex');

/// 按服务端协议算证明。两种模式的消息体不同,别写混:
///   token  : HMAC(token,    `${nonce}:${userId}`)
///   circle : HMAC(passcode, `${nonce}:${userId}:${circleId}`)
/// 依据:server/src/index.js 的 verifyAuth()(第 183-212 行)。
export function buildAuthProof({ mode, nonce, userId, circleId, secret }) {
  if (mode === 'token') {
    return { mode, nonce, proof: hmacHex(secret, `${nonce}:${userId}`) };
  }
  if (mode === 'circle') {
    return {
      mode,
      nonce,
      circleId,
      proof: hmacHex(secret, `${nonce}:${userId}:${circleId}`),
    };
  }
  throw new Error(`未知鉴权模式: ${mode}`);
}

/// 生成一段正弦波 PCM16。测试用:频率已知,收端可以用 FFT 反查是谁在说。
export function sineWave(freqHz, seconds, amplitude = 12000) {
  const total = Math.floor(SAMPLE_RATE * seconds);
  const pcm = new Int16Array(total);
  for (let i = 0; i < total; i++) {
    pcm[i] = Math.round(Math.sin((2 * Math.PI * freqHz * i) / SAMPLE_RATE) * amplitude);
  }
  return pcm;
}

export class LaresBot {
  /**
   * @param {object} opts
   * @param {string} opts.circleId      要进的圈子
   * @param {string} [opts.name]        成员列表里显示的名字
   * @param {string} [opts.userId]      身份;不给则随机生成(压测时必须各不相同)
   * @param {string} [opts.signaling]   信令地址,默认取 LARES_SIGNALING
   * @param {string} [opts.passcode]    圈口令 → circle 模式
   * @param {string} [opts.token]       全局令牌 → token 模式
   * @param {number} [opts.joinTimeoutMs]
   */
  constructor(opts) {
    if (!opts?.circleId) throw new Error('circleId 必填');
    this.circleId = opts.circleId;
    // 默认给个随机后缀:压测时开 20 个 bot,userId 撞车会被服务端当成同一个人挤掉
    this.userId = opts.userId ?? `u_bot_${crypto.randomBytes(4).toString('hex')}`;
    this.deviceId = `d_bot_${crypto.randomBytes(4).toString('hex')}`;
    this.name = opts.name ?? '机器人';
    this.signaling = opts.signaling ?? process.env.LARES_SIGNALING ?? 'ws://127.0.0.1:8787';
    this.passcode = opts.passcode ?? process.env.LARES_CIRCLE_PASSCODE ?? null;
    this.token = opts.token ?? process.env.LARES_AUTH_TOKEN ?? null;
    this.joinTimeoutMs = opts.joinTimeoutMs ?? 15000;
    // 1 = HMAC(口令);2 = HMAC(Argon2 verifier)。注册圈只收 2。
    this.authVersion = opts.authVersion ?? 1;
    this.e2ee = opts.e2ee === true;
    this._verifier = null;
    this._chatHandlers = [];
    this._captionHandlers = [];
    this._capSeq = 0;
    this._capOpenId = null;

    this.ws = null;
    this.room = null;
    this.source = null;
    this.track = null;
    this._audioHandlers = [];
    this._textHandlers = [];
    this._streams = new Map(); // participantIdentity -> AudioStream
    this._closed = false;
  }

  /// 连信令 → 认证 → 进圈 → 拿 token → 连 LiveKit。
  async join() {
    if (this.authVersion === 2 && this.passcode) this._verifier = await authVerifier(this.passcode, this.circleId);
    const tokenMsg = await this._connectSignaling();
    const roomOpts = {};
    if (this.e2ee) {
      if (!this.passcode) throw new Error('e2ee: true 需要 passcode(密钥由口令派生)');
      const hex = await e2eeKeyHex(this.passcode, this.circleId);
      // ratchetSalt / KDF 用 SDK 默认值("LKFrameEncryptionKey" / PBKDF2),与 App 的 livekit_client 默认一致
      roomOpts.encryption = { keyProviderOptions: { sharedKey: new TextEncoder().encode(hex) } };
    }
    this.room = new Room();

    // 订阅别人的音频。**必须在 connect 之前挂监听** ——
    // 已经在房里的人会在 connect 完成的瞬间触发 TrackSubscribed,
    // 晚挂就漏掉他们,表现是"先进来的人听不见,后进来的听得见"。
    this.room.on(RoomEvent.TrackSubscribed, (track, _pub, participant) => {
      // TrackKind.KIND_AUDIO === 1(已实跑 node -e 确认,不是猜的)
      if (track.kind !== TrackKind.KIND_AUDIO) return;
      if (this._audioHandlers.length === 0) return;
      this._attachStream(track, participant);
    });
    this.room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
      this._dispatchData(payload, participant?.identity ?? null, topic);
      for (const h of this._textHandlers) {
        try {
          h(payload, participant?.identity ?? null);
        } catch (e) {
          console.error('[bot] onText 处理器抛错:', e);
        }
      }
    });

    // ⚠️ E2EE 选项必须传给 connect(),Room 构造函数会静默忽略它(实测:放构造里 = 明文发送)
    await this.room.connect(tokenMsg.url, tokenMsg.token, { autoSubscribe: true, ...roomOpts });
    return this;
  }

  /// 信令握手。服务端一连上就下发 challenge,认证通过后才能 join。
  _connectSignaling() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.signaling);
      this.ws = ws;
      let settled = false;
      const fail = (e) => {
        if (settled) return;
        settled = true;
        try { ws.close(); } catch { /* 已经关了就算了 */ }
        reject(e);
      };
      const timer = setTimeout(
        () => fail(new Error(`进房超时(${this.joinTimeoutMs}ms):信令 ${this.signaling}`)),
        this.joinTimeoutMs,
      );

      ws.on('error', fail);
      ws.on('close', (code) => {
        // 4401 = 认证失败。单独拎出来说,因为这是配错口令时最常见的情况,
        // 而一句笼统的"连接关闭"会让人去查网络,查错方向。
        if (code === 4401) fail(new Error('认证失败(4401):口令或令牌不对'));
        else if (code === 4429) fail(new Error('被限流(4429):失败次数过多,等 5 分钟'));
        else fail(new Error(`信令连接关闭,code=${code}`));
      });

      ws.on('message', (raw) => {
        let msg;
        try {
          msg = JSON.parse(raw);
        } catch {
          return; // 不是 JSON 就不是给我们的
        }

        if (msg.t === 'challenge') {
          const auth = this._buildAuth(msg);
          ws.send(JSON.stringify({
            t: 'hello',
            userId: this.userId,
            deviceId: this.deviceId,
            name: this.name,
            platform: 'bot',
            ...(auth ? { auth } : {}),
          }));
          return;
        }

        // 认证通过的回执叫 welcome(server/src/index.js:381)。
        if (msg.t === 'welcome') {
          ws.send(JSON.stringify({ t: 'join', circleId: this.circleId }));
          return;
        }

        // ⚠️ 带 prefetch 标记的是**预取** token(index.js:561),不是进房 token。
        // bot 自己不发 token_prefetch,所以正常不会收到;但显式排掉,
        // 免得将来有人照抄这段代码时被它误触发。
        if (msg.t === 'token' && msg.prefetch === true) return;

        if (msg.t === 'token') {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          // 拿到 token 后**不要关掉这条 ws**:presence 就是这条连接,
          // 断了 bot 就从成员列表消失,别人看不到它在。
          ws.removeAllListeners('close');
          ws.on('close', () => { if (!this._closed) console.warn('[bot] 信令断开'); });
          resolve(msg);
        }
      });
    });
  }

  /// 根据 challenge 通告的模式挑一个我们有凭据的。
  _buildAuth(challenge) {
    if (challenge.authRequired === false) return null;
    const modes = Array.isArray(challenge.modes) ? challenge.modes : [];
    // 优先 circle:它把连接钉死在一个圈子,权限更窄。
    // token 是全局令牌,能操作任意圈子,能不用就不用。
    if (modes.includes('circle') && this.passcode) {
      const proof = buildAuthProof({
        mode: 'circle',
        nonce: challenge.nonce,
        userId: this.userId,
        circleId: this.circleId,
        secret: this._verifier ?? this.passcode,
      });
      return this._verifier ? { ...proof, v: 2 } : proof;
    }
    if (modes.includes('token') && this.token) {
      return buildAuthProof({
        mode: 'token',
        nonce: challenge.nonce,
        userId: this.userId,
        secret: this.token,
      });
    }
    if (modes.length === 0) return null; // 服务端没开鉴权
    throw new Error(
      `服务端要求 [${modes.join(',')}] 鉴权,但没给对应凭据。` +
      `circle 模式传 passcode,token 模式传 token。`,
    );
  }

  /// 发布麦克风轨。第一次 speak() 会自动调,一般不用手动碰。
  async _ensurePublished() {
    if (this.track) return;
    this.source = new AudioSource(SAMPLE_RATE, CHANNELS);
    this.track = LocalAudioTrack.createAudioTrack('bot-voice', this.source);
    await this.room.localParticipant.publishTrack(
      this.track,
      new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }),
    );
  }

  /**
   * 把一段 PCM16 单声道 48kHz 的音频说出去。
   *
   * 节奏控制用的是**绝对时间基准**而不是每帧 sleep 固定值:
   * `setTimeout(9)` 那种写法会累积误差 —— 每帧多睡 1ms,说一分钟就漂了 6 秒,
   * 音频会越来越滞后于真实时间。这里每帧都对齐到 start + n*10ms。
   */
  async speak(pcm16) {
    if (!this.room) throw new Error('还没 join()');
    await this._ensurePublished();

    const start = Date.now();
    const totalFrames = Math.floor(pcm16.length / FRAME_SAMPLES);
    for (let f = 0; f < totalFrames; f++) {
      if (this._closed) break;
      // ⚠️ 必须 slice(拷贝)而不是 subarray(视图)。
      // subarray 返回的是同一块 ArrayBuffer 上的视图,而 AudioFrame 要跨 FFI
      // 边界把这块内存交给 Rust 侧。复用同一个 buffer 的不同区间会让接收端
      // 读到错位/重复的数据 —— 实测症状:单帧测频正确(441Hz),
      // 但拼接后整体测出 100Hz(= 48000/480,正好是帧长的倒数),
      // 也就是帧与帧之间出现了周期性不连续,而**没有任何报错**。
      const chunk = pcm16.slice(f * FRAME_SAMPLES, (f + 1) * FRAME_SAMPLES);
      await this.source.captureFrame(
        new AudioFrame(chunk, SAMPLE_RATE, CHANNELS, FRAME_SAMPLES),
      );
      const targetMs = (f + 1) * 10;
      const drift = targetMs - (Date.now() - start);
      if (drift > 0) await new Promise((r) => setTimeout(r, drift));
    }
  }

  /// 订阅房间里所有人的音频。回调签名 (frame, fromIdentity)。
  /// 必须在 join() **之前**注册,否则会漏掉进房瞬间就已在房里的人。
  onAudio(handler) {
    this._audioHandlers.push(handler);
    return this;
  }

  /// 订阅数据通道(文字/图片消息)。回调签名 (payloadBytes, fromIdentity)。
  onText(handler) {
    this._textHandlers.push(handler);
    return this;
  }

  /// 订阅聊天(topic lares.chat)。回调签名 (msg),msg = {id, senderId, senderName, body, ts, bot, from}。
  /// bot === true 仅当帧来自服务器(participant 为空)且 header 带 bot:true —— 与 App 的防伪规则一致;
  /// 有 participant 却冒充机器人的帧直接丢弃。
  onChat(handler) {
    this._chatHandlers.push(handler);
    return this;
  }

  /// 订阅字幕(topic lares.cap 的 {t:'cap'} 帧)。回调签名 (cap),cap = {id, seq, text, final, from, bot}。
  /// bot = {id,name} 仅当帧来自服务器(participant 为空)。
  onCaption(handler) {
    this._captionHandlers.push(handler);
    return this;
  }

  _dispatchData(payload, from, topic) {
    if (topic === CHAT_TOPIC && this._chatHandlers.length) {
      const f = decodeChatFrame(payload);
      const h = f?.header;
      if (!h || h.t !== 'text' || typeof h.body !== 'string') return;
      const claimsBot = h.bot === true || (typeof h.sid === 'string' && h.sid.startsWith('bot:'));
      if (from !== null && claimsBot) return; // 参与者冒充机器人
      if (from === null && h.bot !== true) return; // 无主帧却不是机器人帧
      const msg = { id: h.id, senderId: h.sid, senderName: h.sn, circleId: h.cid, ts: h.ts, body: h.body, bot: from === null, from };
      for (const cb of this._chatHandlers) { try { cb(msg); } catch (e) { console.error('[bot] onChat 处理器抛错:', e); } }
    } else if (topic === CAPTION_TOPIC && this._captionHandlers.length) {
      let m;
      try { m = JSON.parse(Buffer.from(payload).toString('utf8')); } catch { return; }
      if (m?.t !== 'cap' || typeof m.id !== 'string' || typeof m.text !== 'string' || typeof m.final !== 'boolean') return;
      if (from !== null && 'bot' in m) return; // 防伪:参与者的帧不许带 bot
      if (from === null && !(m.bot && typeof m.bot.id === 'string')) return;
      const cap = { id: m.id, seq: m.seq, text: m.text, final: m.final, from, bot: from === null ? { id: m.bot.id, name: String(m.bot.name ?? '') } : null };
      for (const cb of this._captionHandlers) { try { cb(cap); } catch (e) { console.error('[bot] onCaption 处理器抛错:', e); } }
    }
  }

  /// 发一条聊天(与 App 同格式,广播给房间)。e2ee: true 时数据包随房间密钥加密(实测无密钥者解不出)。返回消息 id。
  async sendChat(text) {
    if (!this.room) throw new Error('还没 join()');
    const header = {
      v: 1, t: 'text', id: crypto.randomUUID(),
      sid: this.userId, sn: this.name, cid: this.circleId, ts: Date.now(), body: String(text),
    };
    await this.room.localParticipant.publishData(encodeChatFrame(header), { reliable: true, topic: CHAT_TOPIC });
    return header.id;
  }

  /// 发一条字幕。同一句的 partial 共用 id,final 定稿后下一句换新 id。返回 {id, seq}。
  async sendCaption(text, { final = false, id } = {}) {
    if (!this.room) throw new Error('还没 join()');
    const capId = id ?? this._capOpenId ?? `cap_${crypto.randomBytes(6).toString('hex')}`;
    this._capSeq += 1;
    this._capOpenId = final ? null : capId;
    const frame = { t: 'cap', id: capId, seq: this._capSeq, text: String(text), final: Boolean(final) };
    await this.room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(frame)), { reliable: true, topic: CAPTION_TOPIC });
    return { id: capId, seq: this._capSeq };
  }

  _attachStream(track, participant) {
    const id = participant?.identity ?? 'unknown';
    if (this._streams.has(id)) return;
    const stream = new AudioStream(track);
    this._streams.set(id, stream);
    (async () => {
      try {
        for await (const frame of stream) {
          if (this._closed) break;
          for (const h of this._audioHandlers) {
            try {
              h(frame, id);
            } catch (e) {
              console.error('[bot] onAudio 处理器抛错:', e);
            }
          }
        }
      } catch (e) {
        if (!this._closed) console.error(`[bot] 读 ${id} 的音频流出错:`, e);
      } finally {
        this._streams.delete(id);
      }
    })();
  }

  /// 干净退场。不调它的话,进程退出时对方会等到超时才看到你离开。
  async leave() {
    this._closed = true;
    for (const s of this._streams.values()) {
      try { await s.close?.(); } catch { /* 关不掉就算了,进程要退了 */ }
    }
    this._streams.clear();
    try { await this.room?.disconnect(); } catch { /* 同上 */ }
    try { this.ws?.close(); } catch { /* 同上 */ }
  }
}
