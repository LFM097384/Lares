// Injected LLM for Gate v2. No module in core/gate reads env; callers build an `llm` object and pass it in.
//   llm = { async chat(messages, { json=false, temperature=0.3, maxTokens=8192 } = {}) -> { text, usage, finish } }
// createDeepSeekLLM is the production implementation (OpenAI-compatible /chat/completions).
// The key is never logged and never included in error text.

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function createDeepSeekLLM({ baseUrl = 'https://api.deepseek.com', key, model = 'deepseek-flash', retries = 3, timeoutMs = 120000, fetchImpl } = {}) {
  if (!key) throw new Error('createDeepSeekLLM: key is required');
  const base = String(baseUrl || 'https://api.deepseek.com').replace(/\/+$/, '');
  const doFetch = fetchImpl || globalThis.fetch;
  const scrub = (s) => String(s ?? '').split(key).join('***');

  async function chat(messages, { json = false, temperature = 0.3, maxTokens = 8192 } = {}) {
    const body = { model, messages, temperature, max_tokens: maxTokens, thinking: { type: 'disabled' } };
    if (json) body.response_format = { type: 'json_object' };
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      if (attempt) await sleep(1000 * 2 ** (attempt - 1) + Math.floor(Math.random() * 250));
      let res;
      try {
        res = await doFetch(`${base}/chat/completions`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (e) { lastErr = new Error(scrub(`LLM network error: ${e?.name || ''} ${e?.message || e}`)); continue; }
      if (res.status === 429 || res.status >= 500) { lastErr = new Error(`LLM HTTP ${res.status}`); continue; }
      if (!res.ok) {
        const t = scrub((await res.text().catch(() => '')).slice(0, 300));
        throw new Error(`LLM HTTP ${res.status}: ${t}`);
      }
      let data;
      try { data = await res.json(); } catch (e) { lastErr = new Error('LLM returned non-JSON body'); continue; }
      const choice = data?.choices?.[0];
      return { text: choice?.message?.content ?? '', usage: data?.usage || {}, finish: choice?.finish_reason };
    }
    throw lastErr || new Error('LLM failed');
  }

  return { chat, model };
}

// Robust JSON extraction: strips ``` fences, falls back to the first balanced {...}.
export function parseJSON(text) {
  let s = String(text ?? '').trim();
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) s = fence[1].trim();
  try { return JSON.parse(s); } catch {}
  const start = s.indexOf('{');
  if (start < 0) throw new Error('no JSON object in LLM output');
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return JSON.parse(s.slice(start, i + 1));
  }
  throw new Error('unbalanced JSON object in LLM output');
}

function account(stats, usage) {
  if (!stats) return;
  stats.calls = (stats.calls || 0) + 1;
  stats.promptTokens = (stats.promptTokens || 0) + (Number(usage?.prompt_tokens) || 0);
  stats.completionTokens = (stats.completionTokens || 0) + (Number(usage?.completion_tokens) || 0);
}

// chat with json=true, parse, retry once on unparseable / truncated JSON. Every call is counted in opts.stats.
export async function chatJSON(llm, messages, { stats, temperature = 0.3, maxTokens = 8192 } = {}) {
  if (!llm || typeof llm.chat !== 'function') throw new Error('chatJSON: llm with chat() is required');
  let lastErr;
  for (let k = 0; k < 2; k++) {
    const r = (await llm.chat(messages, { json: true, temperature, maxTokens })) || {};
    const text = String(r.text ?? '');
    account(stats, r.usage);
    try { return { data: parseJSON(text), text, usage: r.usage || {} }; } catch (e) { lastErr = new Error(`${e.message} (finish_reason=${r.finish}, ${text.length} chars)`); }
  }
  throw lastErr;
}
