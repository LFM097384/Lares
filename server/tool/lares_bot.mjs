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
//   await bot.leave();

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
    const tokenMsg = await this._connectSignaling();
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
    this.room.on(RoomEvent.DataReceived, (payload, participant) => {
      for (const h of this._textHandlers) {
        try {
          h(payload, participant?.identity ?? null);
        } catch (e) {
          console.error('[bot] onText 处理器抛错:', e);
        }
      }
    });

    await this.room.connect(tokenMsg.url, tokenMsg.token, { autoSubscribe: true });
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
      return buildAuthProof({
        mode: 'circle',
        nonce: challenge.nonce,
        userId: this.userId,
        circleId: this.circleId,
        secret: this.passcode,
      });
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
