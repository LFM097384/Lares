// 离线、确定性的假 provider(单元测试 / 无密钥联调)。接口见 ./index.mjs。

import { tone } from '../audio.mjs';

const sleep = (ms, signal) => new Promise((resolve) => {
  if (!ms) return resolve();
  const t = setTimeout(resolve, ms);
  signal?.addEventListener?.('abort', () => { clearTimeout(t); resolve(); }, { once: true });
});

// ── ASR ──────────────────────────────────────────────────────────────────
/**
 * 每段「有声 → 停止送音频」算一句话:停止送音频 quietMs 后给定稿。
 * script:字符串数组(按句轮流)或 (identity, n) => string。
 */
export class MockAsr {
  /**
   * handshakeMs:>0 时模拟握手(期间送来的音频先排队,live 后冲刷);failOpen:接下来几次握手失败
   * (像真实的「Opening handshake has timed out」:onError + onClose,排队的音频随连接丢掉)。
   */
  constructor({ script = ['小助手，你好'], connectMs = 20, partialMs = 60, quietMs = 120, handshakeMs = 0, failOpen = 0 } = {}) {
    Object.assign(this, { script, connectMs, partialMs, quietMs, handshakeMs, failOpen });
    this.sessions = 0;
    this.failedOpens = 0;
    this.warmups = 0;
    this.liveSamples = 0; // 真正「到达服务端」的样本数(只算 live 会话)
    this.counts = new Map();
  }

  /// 预热:开一条连接立刻关,不送音频。
  async warmup() { this.warmups += 1; }

  textFor(identity) {
    const n = this.counts.get(identity) ?? 0;
    this.counts.set(identity, n + 1);
    if (typeof this.script === 'function') return this.script(identity, n);
    return this.script[n % this.script.length];
  }

  open({ identity, onPartial, onFinal, onClose, onError, onOpen }) {
    this.sessions += 1;
    const self = this;
    let samples = 0;
    let utter = 0;
    let quietTimer = null;
    let partialTimer = null;
    let closed = false;
    let live = !(this.handshakeMs > 0 || this.failOpen > 0);
    let queue = [];
    let hsTimer = null;
    const fail = this.failOpen > 0;
    if (fail) this.failOpen -= 1;
    const ingest = (pcm16k) => {
        samples += pcm16k.length;
        self.liveSamples += pcm16k.length;
        // 模拟服务端 VAD:只有「有声」块才算话,最后一个有声块之后静 quietMs 出定稿
        let e = 0;
        for (let i = 0; i < pcm16k.length; i++) e += Math.abs(pcm16k[i]);
        if (!pcm16k.length || e / pcm16k.length < 300) return;
        utter += pcm16k.length;
        clearTimeout(quietTimer);
        if (!partialTimer && utter > 1600) {
          partialTimer = setTimeout(() => { if (!closed) onPartial?.('…'); }, self.partialMs);
        }
        quietTimer = setTimeout(() => {
          if (closed || utter < 1600) return;
          utter = 0;
          partialTimer = null;
          onFinal?.(self.textFor(identity));
        }, self.quietMs);
    };
    const session = {
      get audioSec() { return samples / 16000; },
      get live() { return live; },
      send(pcm16k) {
        if (closed) return;
        if (!live) { queue.push(pcm16k); return; }
        ingest(pcm16k);
      },
      async finish() { session.close(); },
      close() {
        if (closed) return;
        closed = true;
        clearTimeout(hsTimer);
        clearTimeout(quietTimer);
        clearTimeout(partialTimer);
        queue = [];
        onClose?.();
      },
    };
    if (live) queueMicrotask(() => { if (!closed) onOpen?.(); });
    else {
      hsTimer = setTimeout(() => {
        if (closed) return;
        if (fail) {
          self.failedOpens += 1;
          onError?.(new Error('Opening handshake has timed out'));
          session.close();
          return;
        }
        live = true;
        onOpen?.();
        for (const p of queue.splice(0)) ingest(p);
      }, Math.max(1, this.handshakeMs));
    }
    return session;
  }
}

// ── LLM ──────────────────────────────────────────────────────────────────
export class MockLlm {
  /** reply:字符串或 (messages) => string */
  constructor({ reply = '好的，我听到了。这是一个测试回答，用来检查流式播放。', firstTokenMs = 50, tokenMs = 5, tokenChars = 2 } = {}) {
    Object.assign(this, { reply, firstTokenMs, tokenMs, tokenChars });
    this.calls = [];
  }

  async *stream({ messages, signal, maxTokens }) {
    this.calls.push({ messages, maxTokens });
    const text = typeof this.reply === 'function' ? this.reply(messages) : this.reply;
    await sleep(this.firstTokenMs, signal);
    let out = 0;
    for (let i = 0; i < text.length; i += this.tokenChars) {
      if (signal?.aborted) return;
      if (i > 0) await sleep(this.tokenMs, signal);
      if (signal?.aborted) return;
      const piece = text.slice(i, i + this.tokenChars);
      out += piece.length;
      yield { delta: piece };
    }
    yield { usage: { in: JSON.stringify(messages).length >> 1, out } };
  }

  prewarm() {}
}

// ── TTS ──────────────────────────────────────────────────────────────────
/**
 * 每个字 msPerChar 毫秒的正弦音,按 deltaMs 一片吐出;合成速度 = 实时 × speed。
 */
export class MockTts {
  constructor({ openMs = 30, firstAudioMs = 40, msPerChar = 40, deltaMs = 100, speed = 4, sampleRate = 24000, failOpen = 0 } = {}) {
    Object.assign(this, { openMs, firstAudioMs, msPerChar, deltaMs, speed, sampleRate, failOpen });
    this.opened = 0;
    this.closed = 0;
    this.texts = [];
  }

  async open({ voice } = {}) {
    await sleep(this.openMs);
    if (this.failOpen > 0) { this.failOpen -= 1; throw new Error('mock_tts_open_failed'); }
    this.opened += 1;
    const self = this;
    let handlers = {};
    let queue = Promise.resolve();
    let seg = 0;
    let dead = false;
    const ac = new AbortController();
    const session = {
      sampleRate: self.sampleRate,
      voice,
      openedAt: Date.now(),
      used: false,
      get alive() { return !dead; },
      setHandlers(h) { handlers = h ?? {}; },
      send(text) {
        session.used = true;
        const idx = seg++;
        self.texts.push(text);
        queue = queue.then(async () => {
          if (dead) return;
          await sleep(self.firstAudioMs, ac.signal);
          const total = Math.max(1, [...text].length) * self.msPerChar;
          for (let t = 0; t < total && !dead; t += self.deltaMs) {
            const ms = Math.min(self.deltaMs, total - t);
            handlers.onAudio?.(idx, tone(self.sampleRate, ms, { freq: 300 + (idx % 5) * 50 }));
            await sleep(ms / self.speed, ac.signal);
          }
          if (!dead) handlers.onSegmentDone?.(idx, { characters: [...text].length });
        });
        return idx;
      },
      async finish() { await queue; session.close(); },
      close() {
        if (dead) return;
        dead = true;
        self.closed += 1;
        ac.abort();
      },
    };
    return session;
  }
}
