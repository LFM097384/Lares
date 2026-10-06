// OpenAI 兼容的流式 chat completions(默认 DashScope compatible-mode;也接 DeepSeek 等)。

export const DASHSCOPE_COMPAT_BASE = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
export const DEEPSEEK_BASE = 'https://api.deepseek.com';
export const DEEPSEEK_DEFAULT_MODEL = 'deepseek-flash';
/// DeepSeek 默认开思考(首 token 前先吐几十个 reasoning token,实测 +400ms):语音场景关掉。
export const DEEPSEEK_DEFAULT_EXTRA_BODY = Object.freeze({ thinking: Object.freeze({ type: 'disabled' }) });

export function hostOf(baseUrl) {
  try { return new URL(baseUrl).hostname.toLowerCase(); } catch { return ''; }
}
export const isDeepseekBase = (baseUrl) => hostOf(baseUrl) === 'api.deepseek.com';

/**
 * LARES_AI_LLM_EXTRA_BODY 解析:JSON 对象,合并进请求体顶层。
 * 未设(或空串)时:DeepSeek 默认 {"thinking":{"type":"disabled"}},其他服务 {}。
 * 设了但不是 JSON 对象 → 抛错(配置错就早点崩,别静默开着思考)。
 */
export function resolveExtraBody(raw, baseUrl) {
  const s = raw == null ? '' : String(raw).trim();
  if (!s) return isDeepseekBase(baseUrl) ? structuredClone(DEEPSEEK_DEFAULT_EXTRA_BODY) : {};
  let v;
  try { v = JSON.parse(s); } catch { throw new Error('LARES_AI_LLM_EXTRA_BODY: invalid JSON'); }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error('LARES_AI_LLM_EXTRA_BODY: must be a JSON object');
  return v;
}

// 这些字段由本模块控制,extra body 不许覆盖(否则流式解析 / 计费 / 上限会坏)
const RESERVED = new Set(['model', 'messages', 'stream', 'max_tokens']);

export class OpenAiCompatLlm {
  /**
   * @param {{baseUrl?:string, apiKey:string, model?:string, extraBody?:object, fetchImpl?:typeof fetch,
   *          timeoutMs?:number, headersTimeoutMs?:number, name?:string}} o
   * model 可被每次调用的 model 覆盖(config.model);环境变量 LARES_AI_LLM_MODEL 优先(由 index.mjs 处理)。
   * headersTimeoutMs:等响应头的上限(超时抛 llm_timeout,便于回退);timeoutMs:整轮上限。
   */
  constructor({ baseUrl = DASHSCOPE_COMPAT_BASE, apiKey, model = null, extraBody = {}, fetchImpl = fetch, timeoutMs = 20000, headersTimeoutMs = null, name = null } = {}) {
    if (!apiKey) throw new Error('llm_api_key_missing');
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.apiKey = apiKey;
    this.forcedModel = model;
    this.extraBody = extraBody ?? {};
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.headersTimeoutMs = headersTimeoutMs ?? timeoutMs;
    this.isDashscope = /dashscope/i.test(this.baseUrl);
    this.isDeepseek = isDeepseekBase(this.baseUrl);
    this.name = name ?? (this.isDeepseek ? 'deepseek' : this.isDashscope ? 'dashscope' : hostOf(this.baseUrl) || 'llm');
  }

  body({ messages, model, maxTokens }) {
    let m = this.forcedModel || model || (this.isDeepseek ? DEEPSEEK_DEFAULT_MODEL : 'qwen-flash');
    // 圈级 config.model 默认是 qwen-flash(给 DashScope 的):DeepSeek 不认,换成它的默认模型
    if (this.isDeepseek && !this.forcedModel && !/^deepseek/i.test(m)) m = DEEPSEEK_DEFAULT_MODEL;
    // max_tokens / stream / stream_options.include_usage:DashScope 与 DeepSeek 都支持
    const b = { model: m, messages, stream: true, stream_options: { include_usage: true }, max_tokens: maxTokens, temperature: 0.7 };
    // qwen3 系 / qwen-flash|turbo|plus 都是混合思考模型:语音场景一律关思考(首 token 延迟)
    if (this.isDashscope && /^qwen/i.test(m)) b.enable_thinking = false;
    for (const [k, v] of Object.entries(this.extraBody)) if (!RESERVED.has(k)) b[k] = v;
    return b;
  }

  /// 预热 TLS/HTTP 连接(fetch 的 keep-alive 池):随便打一下 /models,失败无所谓。
  prewarm() {
    this.fetch(`${this.baseUrl}/models`, { headers: { Authorization: `Bearer ${this.apiKey}` }, signal: AbortSignal.timeout(5000) })
      .then((r) => r.body?.cancel?.()).catch(() => {});
  }

  /** @returns {AsyncGenerator<{delta?:string, usage?:{in:number,out:number}}>} */
  async *stream({ messages, model, maxTokens = 256, signal }) {
    if (signal?.aborted) return;
    const ac = new AbortController();
    const onAbort = () => ac.abort();
    signal?.addEventListener('abort', onAbort, { once: true });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; ac.abort(); }, this.timeoutMs);
    const hTimer = setTimeout(() => { timedOut = true; ac.abort(); }, this.headersTimeoutMs);
    try {
      let res;
      try {
        res = await this.fetch(`${this.baseUrl}/chat/completions`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.apiKey}`, Accept: 'text/event-stream' },
          body: JSON.stringify(this.body({ messages, model, maxTokens })),
          signal: ac.signal,
        });
      } finally { clearTimeout(hTimer); }
      if (!res.ok) {
        let code = '';
        try { const j = await res.json(); code = j?.error?.code ?? j?.code ?? ''; } catch { /* ignore */ }
        throw new Error(`llm_http_${res.status}${code ? `:${code}` : ''}`);
      }
      const decoder = new TextDecoder();
      let buf = '';
      for await (const part of res.body) {
        buf += decoder.decode(part, { stream: true });
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          if (!line.startsWith('data:')) continue;
          const data = line.slice(5).trim();
          if (data === '[DONE]') return;
          let j;
          try { j = JSON.parse(data); } catch { continue; }
          // 只念 content;delta.reasoning_content(DeepSeek / qwen 思考过程)一律丢弃,绝不出声
          const delta = j?.choices?.[0]?.delta?.content;
          if (typeof delta === 'string' && delta) yield { delta };
          if (j?.usage) yield { usage: { in: j.usage.prompt_tokens ?? 0, out: j.usage.completion_tokens ?? 0 } };
        }
      }
    } catch (e) {
      if (signal?.aborted) return; // 被打断:安静退出
      if (timedOut) throw new Error('llm_timeout');
      throw e;
    } finally {
      clearTimeout(timer);
      clearTimeout(hTimer);
      signal?.removeEventListener('abort', onAbort);
    }
  }
}

/**
 * 主 LLM 失败(非 2xx / 超时 / 网络错)且还没吐出任何字时,改用备用 LLM 重答本轮。
 * 已经吐过字再断的不回退(会重复念)。被打断(signal)不回退。
 */
export class FallbackLlm {
  constructor({ primary, fallback, log = () => {} }) {
    Object.assign(this, { primary, fallback, log });
    this.fallbacks = 0;
  }

  prewarm() { this.primary.prewarm?.(); this.fallback.prewarm?.(); }

  async *stream(o) {
    let yielded = false;
    try {
      for await (const ev of this.primary.stream(o)) {
        if (ev.delta) yielded = true;
        yield ev;
      }
      return;
    } catch (e) {
      if (yielded || o.signal?.aborted) throw e;
      this.fallbacks += 1;
      this.log(`LLM ${this.primary.name ?? 'primary'} 失败(${String(e?.message ?? e).slice(0, 80)}),本轮回退 ${this.fallback.name ?? 'fallback'}`);
    }
    // 备用只用自己的默认模型(config.model 可能是给主 LLM 的)
    yield* this.fallback.stream({ ...o, model: undefined });
  }
}
