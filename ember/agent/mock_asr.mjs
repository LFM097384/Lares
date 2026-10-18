// Ember · 离线、确定性的假 ASR(单元测试 / 无密钥联调)。从 server/bots/voice-agent/providers/mock.mjs 复制 ASR 部分;接口 = ASR provider:open({identity,onOpen,onPartial,onFinal,onClose,onError}) → {send(pcm16k), finish(), close()}。

import { tone } from './audio.mjs';

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
