// OpenAI 兼容的流式 chat completions(默认 DashScope compatible-mode)。

export const DASHSCOPE_COMPAT_BASE = 'https://dashscope.aliyuncs.com/compatible-mode/v1';

export class OpenAiCompatLlm {
  /**
   * @param {{baseUrl?:string, apiKey:string, model?:string, fetchImpl?:typeof fetch, timeoutMs?:number}} o
   * model 可被每次调用的 model 覆盖(config.model);环境变量 LARES_AI_LLM_MODEL 优先(由 index.mjs 处理)。
   */
  constructor({ baseUrl = DASHSCOPE_COMPAT_BASE, apiKey, model = null, fetchImpl = fetch, timeoutMs = 20000 } = {}) {
    if (!apiKey) throw new Error('llm_api_key_missing');
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.apiKey = apiKey;
    this.forcedModel = model;
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.isDashscope = /dashscope/i.test(this.baseUrl);
  }

  body({ messages, model, maxTokens }) {
    const m = this.forcedModel || model || 'qwen-flash';
    const b = { model: m, messages, stream: true, stream_options: { include_usage: true }, max_tokens: maxTokens, temperature: 0.7 };
    // qwen3 系 / qwen-flash|turbo|plus 都是混合思考模型:语音场景一律关思考(首 token 延迟)
    if (this.isDashscope && /^qwen/i.test(m)) b.enable_thinking = false;
    return b;
  }

  /// 预热 TLS/HTTP 连接(fetch 的 keep-alive 池):随便打一下 /models,失败无所谓。
  prewarm() {
    this.fetch(`${this.baseUrl}/models`, { headers: { Authorization: `Bearer ${this.apiKey}` }, signal: AbortSignal.timeout(5000) })
      .then((r) => r.body?.cancel?.()).catch(() => {});
  }

  /** @returns {AsyncGenerator<{delta?:string, usage?:{in:number,out:number}}>} */
  async *stream({ messages, model, maxTokens = 256, signal }) {
    const ac = new AbortController();
    const onAbort = () => ac.abort();
    signal?.addEventListener('abort', onAbort, { once: true });
    const timer = setTimeout(() => ac.abort(), this.timeoutMs);
    try {
      const res = await this.fetch(`${this.baseUrl}/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.apiKey}`, Accept: 'text/event-stream' },
        body: JSON.stringify(this.body({ messages, model, maxTokens })),
        signal: ac.signal,
      });
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
          const delta = j?.choices?.[0]?.delta?.content;
          if (typeof delta === 'string' && delta) yield { delta };
          if (j?.usage) yield { usage: { in: j.usage.prompt_tokens ?? 0, out: j.usage.completion_tokens ?? 0 } };
        }
      }
    } catch (e) {
      if (signal?.aborted) return; // 被打断:安静退出
      throw e;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    }
  }
}
