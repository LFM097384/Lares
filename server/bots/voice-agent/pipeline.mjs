// 回合引擎(纯逻辑:provider / 时钟 / 音频出口 / 房间发布全部注入,不碰 rtc-node)。
//
// 一轮:ASR 定稿 → 触发判定(wake/always/ptt)→ 费用护栏 → LLM 流 → 增量断句 → TTS(每块按序)
//      → 播放队列(24k→48k、10ms 帧、绝对时间节拍)→ 房间。
// 字幕:每轮一个 cap id;每块开始播放时更新 partial;结束时 final = 实际听到的文字。
// 聊天:结束后把回复发到聊天;被打断则只发听到的部分 + "…"。
// 打断:config.interrupt 且有人本地 VAD 连续有声 ≥ interruptMs 时立刻清空播放队列、
//      中止 LLM 与 TTS,按已播样本数算 spokenUntil,历史只记听到的部分。
// 开场白(quick openers):不做。qwen-flash 首 token 实测 ~300ms,加上热 TTS 连接,
//      TTFA 本来就在 1s 级别;固定开场白「嗯,」会让每句都一个味,得不偿失。

import crypto from 'node:crypto';
import { IncrementalChunker, VOICE_CHUNKING, cleanForSpeech } from './chunker.mjs';
import { detectWake, detectPtt } from './wake.mjs';
import { CostGuard, truncateReply } from './caps.mjs';
import { History, spokenUntilFromPlayback, playbackPosition } from './history.mjs';
import { resample, firstChannel, EnergyVad, ROOM_RATE, FRAME_SAMPLES, ASR_RATE } from './audio.mjs';
import { WarmPool } from './providers/index.mjs';

const realSleep = (ms) => new Promise((r) => setTimeout(r, ms));
// lares.ai 状态帧的 seq:每进程单调递增(CONTRACT §5)。
let stateSeq = 0;
const FILLER_ONLY = /^[\s嗯对啊哦呃噢唔额，。！？、,.!?;；:：…~～\-—]*$/u;

/// 去掉回复开头的「<名字>:」/「<名字>：」(LLM 照着「名字: 内容」的历史格式自报家门)。
export function stripSpeakerPrefix(text, name) {
  const s = String(text ?? '');
  const n = String(name ?? '').trim();
  if (!n) return s;
  const esc = n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return s.replace(new RegExp(`^\\s*(?:${esc}|AI|助手)\\s*[:：]\\s*`, 'u'), '');
}

/// 播放器:接各段 PCM(任意采样率),切 10ms 帧,按绝对时间节拍送进 sink,并记录每段真正送出的样本数。
export class Player {
  /**
   * @param {{sink:{captureFrame(f:Int16Array):any, clear():void, queuedMs?:()=>number}, now?:()=>number, sleep?:(ms)=>Promise,
   *          paceScale?:number, onFirstFrame?:()=>void, onSegmentStart?:(seg:number)=>void}} o
   */
  constructor({ sink, now = Date.now, sleep = realSleep, paceScale = 1, onFirstFrame, onSegmentStart }) {
    Object.assign(this, { sink, now, sleep, paceScale, onFirstFrame, onSegmentStart });
    this.q = [];
    this.received = [];
    this.handed = [];
    this.started = new Set();
    this.inputDone = false;
    this.stopped = false;
    this.framesOut = 0;
    this._kick = null;
    this._drained = new Promise((r) => { this._resolveDrained = r; });
    this._loopP = this._loop();
  }

  get drained() { return this._drained; }
  get playing() { return !this.stopped && this.framesOut > 0 && !this._idle; }

  enqueue(seg, pcm, rate = ROOM_RATE) {
    if (this.stopped || !pcm.length) return;
    const p = rate === ROOM_RATE ? pcm : resample(pcm, rate, ROOM_RATE);
    this.received[seg] = (this.received[seg] ?? 0) + p.length;
    this.q.push({ seg, pcm: p, off: 0 });
    this._wake();
  }

  endInput() { this.inputDone = true; this._wake(); }

  _wake() { const k = this._kick; this._kick = null; k?.(); }

  /// 已真正播出的样本数(按段)。减去 sink 里还排着没播的部分(从最后面的段往前扣)。
  playedBySeg() {
    const out = this.handed.map((x) => x ?? 0);
    let queued = Math.round(((this.sink.queuedMs?.() ?? 0) * ROOM_RATE) / 1000);
    for (let i = out.length - 1; i >= 0 && queued > 0; i--) {
      const d = Math.min(out[i], queued);
      out[i] -= d;
      queued -= d;
    }
    return out;
  }

  stop() {
    if (this.stopped) return;
    const played = this.playedBySeg();
    this.stopped = true;
    this.q = [];
    try { this.sink.clear(); } catch { /* sink 已关 */ }
    this._wake();
    this._resolveDrained({ stopped: true });
    this._stoppedPlayed = played;
  }

  async _loop() {
    let base = this.now();
    let n = 0;
    const frameMs = 10 * this.paceScale;
    let waited = false;
    while (!this.stopped) {
      if (!this.q.length) {
        if (this.inputDone) break;
        this._idle = true;
        await new Promise((r) => { this._kick = r; });
        this._idle = false;
        base = this.now();
        n = 0;
        continue;
      }
      const frame = new Int16Array(FRAME_SAMPLES);
      let filled = 0;
      while (filled < FRAME_SAMPLES && this.q.length) {
        const it = this.q[0];
        if (!this.started.has(it.seg)) {
          this.started.add(it.seg);
          try { this.onSegmentStart?.(it.seg); } catch { /* 回调错不影响播放 */ }
        }
        const take = Math.min(FRAME_SAMPLES - filled, it.pcm.length - it.off);
        frame.set(it.pcm.subarray(it.off, it.off + take), filled);
        it.off += take;
        filled += take;
        this.handed[it.seg] = (this.handed[it.seg] ?? 0) + take;
        if (it.off >= it.pcm.length) this.q.shift();
        // 段与段之间不要等:不够一帧且后面暂时没数据时,若输入还没结束就先等一下下一段
        if (filled < FRAME_SAMPLES && !this.q.length && !this.inputDone) {
          this._idle = true;
          await Promise.race([new Promise((r) => { this._kick = r; }), this.sleep(40 * this.paceScale)]);
          this._kick = null;
          this._idle = false;
          waited = true;
          if (this.stopped) return;
        }
      }
      if (this.stopped) return;
      if (this.framesOut === 0) { try { this.onFirstFrame?.(); } catch { /* */ } }
      this.framesOut += 1;
      // ⚠️ 帧必须是独立拷贝(见 README-bot.md 坑 1):frame 是新建的 Int16Array,不是视图
      await this.sink.captureFrame(frame);
      if (waited) { base = this.now(); n = 0; waited = false; } // 等过数据:重新对齐节拍,不要事后猛补
      n += 1;
      const d = base + n * frameMs - this.now();
      if (d > 0) await this.sleep(d);
    }
    if (!this.stopped) this._resolveDrained({ stopped: false });
  }
}

/// 一位说话人的识别会话管理:本地 VAD 判有声才开连接;pre-roll 300ms;静音后再送 ~1s;空闲 20s 关连接。
/// ASR 闸门关着(ptt 模式 / 回答次数到上限)时:本地 VAD 照跑(打断靠它),但不开连接、不送一帧音频。
class SpeakerAsr {
  constructor(agent, identity) {
    this.agent = agent;
    this.identity = identity;
    this.vad = new EnergyVad({ hangoverMs: agent.opts.hangoverMs ?? 1000 });
    this.preroll = [];
    this.prerollSamples = 0;
    this.session = null;
    this.idleTimer = null;
    this.armedUntil = 0; // 只喊了唤醒词:接下来一句直接当问题
    this.live = false; // 当前会话已握手成功
    this.unacked = []; // 当前会话 live 之前送出的全部音频(握手失败时重送)
    this.unackedSamples = 0;
    this.attempt = 0; // 握手重试次数
    this.retryTimer = null;
    this.gaveUp = false; // 重试用尽:这句不再开连接
  }

  push(pcm16k, durMs) {
    const v = this.vad.push(pcm16k, durMs);
    const asrOn = this.agent._asrAllowed();
    if (v.onset && asrOn) this.agent._onSpeechOnset(this.identity);
    if (asrOn && (v.active || v.ended) && !this.gaveUp) {
      if (!this.session && !this.retryTimer) this._open();
      if (this.preroll.length) {
        for (const p of this.preroll) this._send(p);
        this.preroll = [];
        this.prerollSamples = 0;
      }
      this._send(pcm16k);
      this._armIdle();
    } else {
      if (!v.active) this.gaveUp = false; // 重试用尽后:等这句说完,下一句重新开连接
      if (!asrOn && (this.session || this.retryTimer)) this.close();
      this.preroll.push(pcm16k);
      this.prerollSamples += pcm16k.length;
      const max = (ASR_RATE * (this.agent.opts.prerollMs ?? 300)) / 1000;
      while (this.prerollSamples - (this.preroll[0]?.length ?? 0) >= max) this.prerollSamples -= this.preroll.shift().length;
    }
    if (v.voiced) this.agent._onHumanVoice(this.identity, v.runMs);
  }

  /// 送一块音频。会话还没 live(握手中 / 重试退避中)时另存一份:握手失败重开时整段重送,
  /// pre-roll 和开口第一个字都不丢。
  _send(pcm) {
    if (!this.live) {
      this.unacked.push(pcm);
      this.unackedSamples += pcm.length;
      const max = ASR_RATE * (this.agent.opts.asrBufferSec ?? 8); // = DashscopeAsr 握手队列上限
      while (this.unackedSamples > max && this.unacked.length > 1) this.unackedSamples -= this.unacked.shift().length;
    }
    this.session?.send(pcm);
  }

  _open() {
    const a = this.agent;
    let s = null;
    const markLive = () => {
      if (!s || s._live) return;
      s._live = true;
      if (this.session === s) { this.live = true; this.unacked = []; this.unackedSamples = 0; this.attempt = 0; }
    };
    this.live = false;
    s = a.providers.asr.open({
      identity: this.identity,
      onOpen: () => markLive(),
      onPartial: () => {},
      onFinal: (text) => { markLive(); a._onAsrFinal(this.identity, text); },
      onClose: () => this._closed(s),
      onError: (e) => a.log(`ASR 出错: ${e.message}`),
    });
    s.openedAt = a.now();
    this.session = s;
    // 重试时:上一次连接丢掉的全部音频(含 pre-roll)先送进新连接(provider 握手期间自己排队)
    for (const p of this.unacked) s.send(p);
    if (s.live) markLive();
  }

  _armIdle() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.close(), this.agent.opts.asrIdleMs ?? 20_000);
    this.idleTimer.unref?.();
  }

  /// 每个会话只记一次账;只在它还是当前会话时才清空(关旧会话不影响新开的)。
  /// 当前会话没 live 就断了(握手超时等)且不是我们自己关的:退避后重开,最多 asrRetries 次。
  _closed(s) {
    if (!s || s._accounted) return;
    s._accounted = true;
    const failedOpen = this.session === s && !s._live && !s._byUs && !s.live;
    if (this.session === s) this.session = null;
    this.agent.guard.addUsage({ asrSec: failedOpen ? 0 : (s.audioSec ?? 0) });
    if (!failedOpen) { if (!this.session && !this.retryTimer) clearTimeout(this.idleTimer); return; }
    const a = this.agent;
    const max = a.opts.asrRetries ?? 2;
    if (a.closed || this.attempt >= max) {
      if (!a.closed) {
        a.log(`ASR 连接失败,重试 ${this.attempt} 次后放弃这句;下一句重新连接`);
        a.emit({ ev: 'error', where: 'asr', message: 'asr_open_failed' });
        this.gaveUp = true;
      }
      this._reset();
      return;
    }
    this.attempt += 1;
    const backoff = (a.opts.asrRetryBackoffMs ?? 250) * this.attempt;
    a.log(`ASR 握手失败,${backoff}ms 后重试(第 ${this.attempt}/${max} 次,保留 ${Math.round((this.unackedSamples / ASR_RATE) * 1000)}ms 音频)`);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (a.closed || !a._asrAllowed()) { this._reset(); return; }
      this._open();
    }, backoff);
    this.retryTimer.unref?.();
  }

  _reset() {
    clearTimeout(this.retryTimer);
    clearTimeout(this.idleTimer);
    this.retryTimer = null;
    this.session = null;
    this.live = false;
    this.attempt = 0;
    this.unacked = [];
    this.unackedSamples = 0;
  }

  close() {
    clearTimeout(this.idleTimer);
    const s = this.session;
    this._reset(); // 立刻摘下:收尾期间不再往它送音频;退避中的重试也取消
    if (!s) return;
    s._byUs = true;
    Promise.resolve(s.finish?.()).catch(() => {}).finally(() => { try { s.close(); } catch { /* */ } this._closed(s); });
  }
}
export class VoiceAgent {
  /**
   * @param {object} o
   * @param {object} o.config        归一化后的 AiVoiceConfig
   * @param {{asr,llm,tts}} o.providers
   * @param {{captureFrame(f:Int16Array):any, clear():void, queuedMs?:()=>number}} o.sink  48k 单声道出口
   * @param {{publishCaption(cap:object):any, sendChat(text:string):any, publishState?(frame:object):any}} o.room
   * @param {string} [o.selfIdentity]
   * @param {(ev:object)=>void} [o.emit]   stdout 事件
   * @param {CostGuard} [o.guard]
   * @param {() => number} [o.now]
   * @param {number} [o.paceScale]  测试用:节拍加速(0.1 = 10 倍速)
   * @param {number} [o.interruptMs]  默认 200
   * @param {boolean} [o.logText]
   * @param {(m:string)=>void} [o.log]
   * @param {() => void} [o.onDailyCap]
   */
  constructor(o) {
    this.opts = o;
    this.config = o.config;
    this.providers = o.providers;
    this.sink = o.sink;
    this.room = o.room;
    this.self = o.selfIdentity ?? null;
    this.emit = o.emit ?? (() => {});
    this.now = o.now ?? Date.now;
    this.log = o.log ?? (() => {});
    this.guard = o.guard ?? new CostGuard({ now: this.now, config: this.config, emit: this.emit });
    this.history = new History(o.historyTurns ?? 10);
    this.speakers = new Map();
    this.names = new Map();
    this.declined = new Set();
    this.turn = null;
    this.pending = null;
    this.turnSeq = 0;
    this.capNoticeAt = 0;
    this.closed = false;
    this.asrGate = 'on'; // 'on' | 'ptt' | 'cap'
    this.aiState = null; // lares.ai 上最后发出的状态(CONTRACT §5)
    this.stateFrame = null;
    this.pool = new WarmPool({
      open: () => this.providers.tts.open({ voice: this.config.voice }),
      now: this.now,
      log: this.log,
      maxIdleMs: o.ttsMaxIdleMs ?? 50_000,
    });
    if (o.warm !== false) {
      this.pool.start();
      // ASR 冷握手在生产上偶发卡满超时:启动时先握一次手就断(不送音频、不计费),第一句话走热路径
      if (this.config.trigger !== 'ptt') {
        Promise.resolve().then(() => this.providers.asr.warmup?.()).catch((e) => this.log(`ASR 预热失败: ${e?.message ?? e}`));
      }
    }
    this._asrAllowed(); // 起始状态(ptt / 已到上限)也记一行
    this._syncState();
  }

  setConfig(config) {
    const voiceChanged = config.voice !== this.config.voice;
    const triggerChanged = config.trigger !== this.config.trigger;
    this.config = config;
    this.guard.setConfig(config);
    if (voiceChanged) this.pool.reset();
    // 换触发方式(如 wake → ptt):关掉所有已开的 ASR 会话;需要时下一句会按新配置重开
    if (triggerChanged) this._closeAllAsr();
    this._asrAllowed();
  }

  _closeAllAsr() { for (const sp of this.speakers.values()) sp.close(); }

  /// 现在能不能往 ASR 送音频?ptt 模式不送;每小时/每日回答次数用完时也不送(窗口腾出来再恢复)。
  /// 状态变化时记一行 stderr(不含任何文字内容),并在闸门关上时关掉所有会话。
  _asrAllowed() {
    let gate = 'on';
    let cap = null;
    if (this.config.trigger === 'ptt') gate = 'ptt';
    else if (!(cap = this.guard.check()).ok) gate = 'cap';
    if (gate !== this.asrGate) {
      const prev = this.asrGate;
      this.asrGate = gate;
      // 上限期间语音问题到不了 _capCheck:进入每小时上限时发一次 cap_reached(每日上限由 recordTurn 发)。
      // 不在聊天里发提示——没人叫它时也刷屏;@AI 聊天仍走 _capCheck,会收到提示。
      if (gate === 'cap' && cap?.reason === 'hourly') this.emit({ ev: 'cap_reached', scope: 'hourly', retryInMs: cap.retryInMs });
      if (gate === 'on') this.log(`ASR 恢复(之前:${prev === 'ptt' ? 'ptt 模式' : '回答次数上限'})`);
      else this.log(`ASR 暂停:${gate === 'ptt' ? 'ptt 模式,语音不上云' : '回答次数到上限,窗口腾出前不识别'};本地 VAD 打断照常`);
      if (gate !== 'on') this._closeAllAsr();
      // 每小时上限:窗口腾出时主动复查一次,不必等有人开口才从 idle 回到 listening
      clearTimeout(this._capTimer);
      if (gate === 'cap' && cap?.reason === 'hourly' && cap.retryInMs > 0) {
        this._capTimer = setTimeout(() => { if (!this.closed) this._asrAllowed(); }, cap.retryInMs + 50);
        this._capTimer.unref?.();
      }
      this._syncState();
    }
    return gate === 'on';
  }

  /// lares.ai 状态(CONTRACT §5):进行中的一轮决定 thinking/speaking,否则看 ASR 闸门 listening/idle。
  _syncState() {
    const t = this.turn;
    let s;
    if (this.closed) s = 'idle';
    else if (t && !t.ended) s = t.phase;
    else s = this.asrGate === 'on' ? 'listening' : 'idle';
    if (s === this.aiState) return; // 只在变化时发
    this.aiState = s;
    this._publishState();
  }

  /// 重发当前状态(进房后 / 有人新进房时调;新 seq)。
  republishState() { if (this.aiState) this._publishState(); }

  _publishState() {
    stateSeq += 1;
    this.stateFrame = { t: 'state', state: this.aiState, seq: stateSeq };
    const f = this.stateFrame;
    Promise.resolve().then(() => this.room.publishState?.(f)).catch(() => {});
  }

  setName(identity, name) { if (name) this.names.set(identity, String(name).slice(0, 32)); }

  /// lares.cap 上收到的控制帧:capack{on:false} = 这位成员不同意被转写。
  onCaptionControl(identity, msg) {
    if (!msg || msg.t !== 'capack' || typeof msg.on !== 'boolean') return;
    if (msg.on) this.declined.delete(identity);
    else {
      this.declined.add(identity);
      const sp = this.speakers.get(identity);
      if (sp) { sp.close(); this.speakers.delete(identity); }
    }
  }

  participantLeft(identity) {
    const sp = this.speakers.get(identity);
    if (sp) { sp.close(); this.speakers.delete(identity); }
  }

  /// 房间里某人的一帧音频(任意采样率/声道)。
  onAudioFrame(identity, data, sampleRate = ROOM_RATE, channels = 1) {
    if (this.closed || !identity || identity === this.self || identity.startsWith('bot:') || identity.startsWith('u_ai_')) return;
    if (this.declined.has(identity)) return;
    const mono = firstChannel(data, channels);
    const pcm16k = resample(mono, sampleRate, ASR_RATE);
    let sp = this.speakers.get(identity);
    if (!sp) { sp = new SpeakerAsr(this, identity); this.speakers.set(identity, sp); }
    sp.push(pcm16k, (mono.length / sampleRate) * 1000);
  }

  _onSpeechOnset() {
    // 有人开口:TTS 连接保温、LLM 连接预热
    this.pool.prewarm();
    this.providers.llm.prewarm?.();
  }

  _onHumanVoice(identity, runMs) {
    const t = this.turn;
    if (!t || !this.config.interrupt || t.ended) return;
    if (!t.player?.playing && !t.player?.framesOut) return; // 还没开口:不算插话
    if (runMs >= (this.opts.interruptMs ?? 200)) this.interrupt(`voice:${identity}`);
  }

  _onAsrFinal(identity, rawText) {
    const text = String(rawText ?? '').trim();
    if (!text || FILLER_ONLY.test(text)) return;
    const sp = this.speakers.get(identity);
    const name = this.names.get(identity) ?? identity;
    const at = this.now();
    const tr = this.config.trigger;
    if (tr === 'ptt') return; // 正常到不了这里(ptt 不开 ASR);保险
    if (tr === 'always') {
      const w = detectWake(text, this.config);
      return this._request({ trigger: 'always', speaker: name, query: w.hit && w.query ? w.query : text, at });
    }
    const w = detectWake(text, this.config);
    if (w.hit) {
      if (!w.query) { if (sp) sp.armedUntil = at + 8000; return; }
      return this._request({ trigger: 'wake', speaker: name, query: w.query, at });
    }
    if (sp && sp.armedUntil > at) {
      sp.armedUntil = 0;
      return this._request({ trigger: 'wake', speaker: name, query: text, at });
    }
  }

  /// 聊天消息(lares.chat)。@AI / @名字 开头的在任何触发模式下都回答。
  onChat(msg) {
    if (!msg || msg.bot || msg.senderId === this.self || String(msg.senderId ?? '').startsWith('u_ai_') || String(msg.from ?? '').startsWith('u_ai_')) return;
    const p = detectPtt(msg.body, this.config);
    if (!p.hit || !p.query) return;
    this._request({ trigger: 'ptt', speaker: msg.senderName || msg.senderId || '成员', query: p.query, at: this.now() });
  }

  _request(req) {
    if (this.closed) return;
    if (this.turn && !this.turn.ended) { this.pending = req; return; } // 最多排一个(新的顶掉旧的)
    this._startTurn(req);
  }

  _capCheck() {
    const c = this.guard.check();
    if (c.ok) return true;
    if (c.reason === 'daily') {
      this.emit({ ev: 'cap_reached', scope: 'daily', turns: this.guard.turnsToday() });
      this._notice('今天的回答次数已经用完了，明天再聊吧。');
      this.opts.onDailyCap?.();
    } else {
      this.emit({ ev: 'cap_reached', scope: 'hourly', retryInMs: c.retryInMs });
      this._notice('这一小时回答得有点多了，稍后再来找我吧。');
    }
    return false;
  }

  _notice(text) {
    if (this.now() - this.capNoticeAt < 10 * 60_000) return;
    this.capNoticeAt = this.now();
    Promise.resolve(this.room.sendChat(text)).catch(() => {});
  }

  _systemPrompt() {
    const c = this.config;
    return `${c.persona}\n你的名字是「${c.name}」。这是一个多人语音房间,用户消息以「名字: 内容」开头。`
      + `回答要能直接念出来:口语化,不超过${c.maxReplyChars}个字,不要 Markdown、列表、表情或网址。`
      + `直接说回答内容,开头不要加自己的名字或「${c.name}:」。`;
  }

  async _startTurn(req) {
    if (!this._capCheck()) return;
    this.guard.recordTurn();
    const t = {
      id: `t_${crypto.randomBytes(5).toString('hex')}`,
      capId: `cap_ai_${crypto.randomBytes(6).toString('hex')}`,
      capSeq: 0,
      req,
      ac: new AbortController(),
      chunks: [],
      segDone: [],
      segChars: [],
      ended: false,
      interrupted: false,
      llmDone: false,
      ttsFailed: false,
      marks: {},
      usage: { llmIn: 0, llmOut: 0, ttsChars: 0 },
      phase: 'thinking', // lares.ai:thinking → speaking(首帧)
    };
    this.turn = t;
    this._syncState(); // lares.ai → thinking
    this._asrAllowed(); // 这一轮用掉了最后的额度:立刻停 ASR(本地 VAD 打断照常);进行中不改 lares.ai 状态
    this.history.addUser(`${req.speaker}: ${req.query}`);
    const messages = [{ role: 'system', content: this._systemPrompt() }, ...this.history.messages()];
    const mark = (k) => { if (t.marks[k] === undefined) t.marks[k] = this.now() - req.at; };

    t.player = new Player({
      sink: this.sink,
      now: this.now,
      paceScale: this.opts.paceScale ?? 1,
      onFirstFrame: () => { mark('ttfa'); if (!t.ended) { t.phase = 'speaking'; this._syncState(); } }, // lares.ai → speaking
      onSegmentStart: (seg) => this._caption(t, this._join(t.chunks.slice(0, seg + 1)), false),
    });

    // TTS 连接(热备用,通常 0ms)与 LLM 并行
    const ttsP = this.pool.take().then((s) => {
      if (t.ended) { s.close(); return null; }
      t.tts = s;
      s.setHandlers({
        onAudio: (seg, pcm) => {
          if (t.ended) return;
          mark('ttsFirstAudio');
          t.player.enqueue(seg, pcm, s.sampleRate);
        },
        onSegmentDone: (seg, u) => {
          t.segDone[seg] = true;
          t.usage.ttsChars += u?.characters || [...(t.chunks[seg] ?? '')].length;
          this._maybeEndInput(t);
        },
        onError: (e) => { this.log(`TTS 中途出错: ${e.message}`); t.ttsFailed = true; t.player.endInput(); },
      });
      for (let i = 0; i < t.chunks.length; i++) s.send(t.chunks[i]);
      return s;
    }, (e) => {
      this.log(`TTS 不可用,改发文字: ${e.message}`);
      t.ttsFailed = true;
      t.player.endInput();
      return null;
    });

    const chunker = new IncrementalChunker(VOICE_CHUNKING);
    const max = this.config.maxReplyChars;
    let used = 0;
    let capped = false;
    const pushChunk = (raw) => {
      if (capped || t.ended) return;
      let c = cleanForSpeech(raw);
      // 真机实测:qwen-flash 会模仿历史里的「名字: 内容」格式,回复以「小助手：」开头 —— 念出来、上字幕都很怪
      if (used === 0) c = stripSpeakerPrefix(c, this.config.name);
      if (!c) return;
      const n = [...c].length;
      if (used + n > max) {
        c = truncateReply(c, max - used);
        capped = true;
        t.ac.abort(); // 够了:不再要 LLM 的 token
        if (!c || c === '…') return;
      }
      used += [...c].length;
      mark('firstSentence');
      t.chunks.push(c);
      t.segChars.push([...c].length);
      if (t.tts) t.tts.send(c);
    };

    try {
      for await (const ev of this.providers.llm.stream({ messages, model: this.config.model, maxTokens: this.guard.maxTokens, signal: t.ac.signal })) {
        if (t.ended) break;
        if (ev.usage) { t.usage.llmIn = ev.usage.in; t.usage.llmOut = ev.usage.out; continue; }
        if (!ev.delta) continue;
        mark('llmFirstToken');
        for (const c of chunker.feed(ev.delta)) pushChunk(c);
        if (capped) break;
      }
      if (!t.ended) for (const c of chunker.flush()) pushChunk(c);
    } catch (e) {
      if (!t.ended) {
        this.log(`LLM 出错: ${e.message}`);
        this.emit({ ev: 'error', where: 'llm', message: String(e.message).slice(0, 120) });
      }
    }
    t.llmDone = true;
    if (t.ended) return;
    await ttsP;
    if (t.ended) return;
    if (!t.chunks.length) { t.player.endInput(); this._finish(t, { spoken: false }); return; }
    this._maybeEndInput(t);
    const r = await t.player.drained;
    if (!r.stopped && !t.ended) this._finish(t, { spoken: !t.ttsFailed || t.player.framesOut > 0 });
  }

  _maybeEndInput(t) {
    if (!t.llmDone || !t.tts) return;
    for (let i = 0; i < t.chunks.length; i++) if (!t.segDone[i]) return;
    t.player.endInput();
  }

  /// 拼块:CJK 之间不加空格,拉丁之间补一个。
  _join(chunks) {
    let s = '';
    for (const c of chunks) {
      if (s && /[A-Za-z0-9.,!?;:]$/.test(s) && /^[A-Za-z0-9]/.test(c)) s += ' ';
      s += c;
    }
    return s;
  }

  _caption(t, text, final) {
    if (!text) return;
    t.capSeq += 1;
    Promise.resolve(this.room.publishCaption({ t: 'cap', id: t.capId, seq: t.capSeq, text, final })).catch(() => {});
  }

  /// 打断当前这轮(人声插话 / 外部调用)。返回 {heard, spokenUntil} 或 null。
  interrupt(reason = 'manual') {
    const t = this.turn;
    if (!t || t.ended) return null;
    t.player.stop();
    t.ac.abort();
    try { t.tts?.close(); } catch { /* */ }
    const stored = this._join(t.chunks);
    const played = t.player._stoppedPlayed ?? t.player.playedBySeg();
    // 每段总样本:已合成完的用真实值;没合成完的用「已收到」与「按字数估计」中较大的(宁可少算听到的)
    const totals = t.chunks.map((c, i) => {
      const rec = t.player.received[i] ?? 0;
      return t.segDone[i] ? rec : Math.max(rec, Math.round([...c].length * 0.22 * ROOM_RATE));
    });
    const playedTotal = played.reduce((a, b) => a + b, 0);
    const pos = playbackPosition(totals, playedTotal);
    const su = spokenUntilFromPlayback(stored, t.chunks, pos.chunkIndex, pos.fraction);
    const heard = stored.slice(0, su);
    t.interrupted = true;
    this.log(`被打断(${reason.split(':')[0]}):听到 ${[...heard].length}/${[...stored].length} 字`);
    this._finish(t, { spoken: true, heard, spokenUntil: su, stored });
    return { heard, spokenUntil: su };
  }

  _finish(t, { spoken, heard, spokenUntil, stored }) {
    if (t.ended) return;
    t.ended = true;
    try { t.tts?.close(); } catch { /* */ }
    const full = stored ?? this._join(t.chunks);
    if (t.interrupted) {
      if (heard && heard.trim()) {
        this._caption(t, `${heard}…`, true);
        Promise.resolve(this.room.sendChat(`${heard}…`)).catch(() => {});
      } else this._caption(t, '…', true);
      this.history.addAssistant(full, { interrupted: true, spokenUntil });
    } else if (full) {
      if (spoken) this._caption(t, full, true);
      Promise.resolve(this.room.sendChat(full)).catch(() => {});
      this.history.addAssistant(full);
    }
    this.guard.addUsage(t.usage);
    const m = t.marks;
    const ev = {
      ev: 'turn',
      id: t.id,
      trigger: t.req.trigger,
      asrFinalAt: t.req.at,
      llmFirstTokenMs: m.llmFirstToken ?? null,
      firstSentenceMs: m.firstSentence ?? null,
      ttsFirstAudioMs: m.ttsFirstAudio ?? null,
      ttfaMs: m.ttfa ?? null,
      replyChars: [...full].length,
      heardChars: t.interrupted ? [...(heard ?? '')].length : (spoken ? [...full].length : 0),
      interrupted: t.interrupted,
      ...(t.ttsFailed ? { ttsFailed: true } : {}),
      ...(this.opts.logText ? { query: t.req.query, reply: full } : {}),
    };
    this.emit(ev);
    this.lastTurn = ev;
    if (this.turn === t) this.turn = null;
    this._syncState(); // lares.ai → listening / idle(正常结束和打断都走这里)
    const next = this.pending;
    this.pending = null;
    if (!this.guard.check().ok && this.guard.check().reason === 'daily') { this.opts.onDailyCap?.(); return; }
    if (next && !this.closed && this.now() - next.at < 20_000) setImmediate(() => this._request(next));
  }

  /// 等当前这轮结束(测试 / 优雅退出用)。
  async idle(timeoutMs = 10_000) {
    const t0 = Date.now();
    while ((this.turn || this.pending) && Date.now() - t0 < timeoutMs) await realSleep(10);
  }

  async close() {
    this.closed = true;
    clearTimeout(this._capTimer);
    this.interrupt('shutdown');
    this._syncState(); // lares.ai → idle(尽力而为;房间可能已关)
    for (const sp of this.speakers.values()) sp.close();
    this.speakers.clear();
    this.pool.stop();
  }
}
