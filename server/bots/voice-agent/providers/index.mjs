// provider 接口(鸭子类型)与工厂。
//
// ASR  : open({identity, onPartial(text), onFinal(text), onClose(), onError(e)}) -> { send(pcm16k Int16Array), finish(): Promise, close(), audioSec }
// LLM  : stream({messages, model, maxTokens, signal}) -> AsyncIterable<{delta?:string, usage?:{in,out}}> ; prewarm()
// TTS  : open({voice}) -> Promise<Session>
//        Session: { sampleRate, alive, used, openedAt, setHandlers({onAudio(segIdx, pcm Int16Array), onSegmentDone(segIdx, {characters}), onError(e)}),
//                   send(text) -> segIdx, finish(): Promise, close() }

import { MockAsr, MockLlm, MockTts } from './mock.mjs';

export function createProviders(kind, { env = process.env, mock = {}, log = () => {} } = {}) {
  if (kind === 'mock') {
    return { kind, asr: new MockAsr(mock.asr), llm: new MockLlm(mock.llm), tts: new MockTts(mock.tts) };
  }
  if (kind !== 'dashscope') throw new Error(`unknown_providers:${kind}`);
  return (async () => {
    const { DashscopeAsr, DashscopeTts } = await import('./dashscope.mjs');
    const key = env.LARES_DASHSCOPE_API_KEY || '';
    if (!key) throw new Error('LARES_DASHSCOPE_API_KEY missing');
    return {
      kind,
      asr: new DashscopeAsr({ apiKey: key }),
      llm: await createLlm(env, { log }),
      tts: new DashscopeTts({ apiKey: key, model: env.LARES_AI_TTS_MODEL || undefined }),
    };
  })();
}

/**
 * LLM:LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(别名 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL / LARES_AI_LLM_EXTRA_BODY。
 * 主 LLM 不是 DashScope 且有 DashScope key 时,包一层 FallbackLlm:主 LLM 非 2xx / 超时 → 本轮改用 DashScope qwen-flash。
 */
export async function createLlm(env = process.env, { log = () => {}, fetchImpl } = {}) {
  const { OpenAiCompatLlm, FallbackLlm, DASHSCOPE_COMPAT_BASE, resolveExtraBody } = await import('./openai_compat.mjs');
  const dsKey = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  const baseUrl = String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || DASHSCOPE_COMPAT_BASE;
  const llmKey = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim() || dsKey;
  const extraBody = resolveExtraBody(env.LARES_AI_LLM_EXTRA_BODY, baseUrl);
  const f = fetchImpl ? { fetchImpl } : {};
  const ms = (name, dflt) => { const n = Number(String(env[name] ?? '').trim() || NaN); return Number.isFinite(n) && n > 0 ? n : dflt; };
  const primaryIsDashscope = /dashscope/i.test(baseUrl);
  const canFallback = !primaryIsDashscope && Boolean(dsKey);
  const primary = new OpenAiCompatLlm({
    baseUrl, apiKey: llmKey, model: String(env.LARES_AI_LLM_MODEL ?? '').trim() || null, extraBody,
    // 有备用时,等响应头/首包别等满 20 s:超时就回退
    headersTimeoutMs: canFallback ? ms('LARES_AI_LLM_TIMEOUT_MS', 6000) : undefined,
    ...f,
  });
  if (!canFallback) return primary;
  const fallback = new OpenAiCompatLlm({ baseUrl: DASHSCOPE_COMPAT_BASE, apiKey: dsKey, model: 'qwen-flash', name: 'dashscope', ...f });
  return new FallbackLlm({ primary, fallback, log });
}

/**
 * 预开的 TTS 连接池(只留 1 条备用)。握手 ~1.1s,绝不放在一轮的关键路径上。
 * - 备用连接超过 maxIdleMs(服务端约 60s+ 才断,取 50s)就先开新的再关旧的;
 * - 超过 idleStopMs 没人说话就不再保温(省连接);有人开口时 prewarm() 立刻补一条。
 * - 用过的连接不回收(一轮一条;打断时直接关)。
 */
export class WarmPool {
  constructor({ open, maxIdleMs = 50_000, idleStopMs = 10 * 60_000, tickMs = 1000, now = Date.now, log = () => {} }) {
    Object.assign(this, { openFn: open, maxIdleMs, idleStopMs, tickMs, now, log });
    this.spare = null;
    this.opening = null;
    this.lastActivity = now();
    this.timer = null;
    this.stopped = false;
    this.opens = 0;
    this.failures = 0;
  }

  start() {
    this.timer = setInterval(() => this._tick(), this.tickMs);
    this.timer.unref?.();
    this.prewarm();
    return this;
  }

  touch() { this.lastActivity = this.now(); }

  _fresh(s) { return s && s.alive && !s.used && this.now() - s.openedAt < this.maxIdleMs; }

  _open() {
    if (this.opening || this.stopped) return this.opening;
    this.opens += 1;
    const p = this.openFn().then((s) => {
      this.failures = 0;
      if (this.opening === p) this.opening = null;
      if (this.stopped) { s.close(); return null; }
      const old = this.spare;
      this.spare = s;
      if (old && old !== s) old.close();
      return s;
    }, (e) => {
      this.failures += 1;
      if (this.opening === p) this.opening = null;
      this.log(`TTS 预开连接失败: ${e.message}`);
      return null;
    });
    this.opening = p;
    return p;
  }

  /// 有人开口:确保有一条热连接。
  prewarm() {
    this.touch();
    if (!this._fresh(this.spare) && !this.opening && this.failures < 3) this._open();
  }

  _tick() {
    if (this.stopped) return;
    const idle = this.now() - this.lastActivity > this.idleStopMs;
    if (this.spare && (idle || !this.spare.alive)) { this.spare.close(); this.spare = null; }
    if (idle) return;
    const aging = this.spare && this.now() - this.spare.openedAt > this.maxIdleMs - 5000;
    if ((!this.spare || aging) && !this.opening && this.failures < 3) this._open();
    if (this.failures >= 3 && this.now() - this.lastActivity < 2 * this.tickMs) this.failures = 2; // 有活动时允许再试
  }

  /// 拿一条可用连接:备用 → 正在开的 → 现开(慢路径)。拿走后立即开下一条备用。
  async take() {
    this.touch();
    let s = this.spare;
    this.spare = null;
    if (s && !this._fresh(s)) { s.close(); s = null; }
    if (!s && this.opening) {
      const got = await this.opening;
      if (got && this.spare === got) { this.spare = null; s = got; }
    }
    if (!s) s = await this.openFn(); // 抛错由调用方处理
    this._open(); // 下一轮的备用
    return s;
  }

  /// 配置变了(音色):丢掉备用重开。
  reset(open) {
    if (open) this.openFn = open;
    this.spare?.close();
    this.spare = null;
    this.opening = null;
    this.failures = 0;
    this.prewarm();
  }

  stop() {
    this.stopped = true;
    clearInterval(this.timer);
    this.spare?.close();
    this.spare = null;
  }
}
