// Minimal OpenAI-compatible chat client for the Chatham Gate. Never logs the key.
export function llmConfig() {
  return {
    baseUrl: (process.env.CHATHAM_LLM_BASE_URL || 'https://api.deepseek.com').replace(/\/+$/, ''),
    key: process.env.CHATHAM_LLM_KEY || '',
    model: process.env.CHATHAM_LLM_MODEL || 'deepseek-flash',
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function chat(messages, { json = false, temperature = 0.3, stats } = {}) {
  const { baseUrl, key, model } = llmConfig();
  if (!key) throw new Error('CHATHAM_LLM_KEY is not set');
  const body = { model, messages, temperature, max_tokens: 8192, thinking: { type: 'disabled' } };
  if (json) body.response_format = { type: 'json_object' };
  let lastErr;
  for (let attempt = 0; attempt <= 3; attempt++) {
    if (attempt) await sleep(1000 * 2 ** (attempt - 1) + Math.floor(Math.random() * 250));
    let res;
    try {
      res = await fetch(`${baseUrl}/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(120000),
      });
    } catch (e) { lastErr = new Error(`LLM network error: ${e?.name || ''} ${e?.message || e}`); continue; }
    if (res.status === 429 || res.status >= 500) { lastErr = new Error(`LLM HTTP ${res.status}`); continue; }
    if (!res.ok) {
      const t = (await res.text().catch(() => '')).slice(0, 300).split(key).join('***');
      throw new Error(`LLM HTTP ${res.status}: ${t}`);
    }
    const data = await res.json();
    const text = data?.choices?.[0]?.message?.content ?? '';
    const usage = data?.usage || {};
    if (stats) {
      stats.calls = (stats.calls || 0) + 1;
      stats.promptTokens = (stats.promptTokens || 0) + (usage.prompt_tokens || 0);
      stats.completionTokens = (stats.completionTokens || 0) + (usage.completion_tokens || 0);
    }
    return { text, usage, finish: data?.choices?.[0]?.finish_reason };
  }
  throw lastErr || new Error('LLM failed');
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

// Retries once on unparseable / truncated JSON (seen occasionally on long digests).
export async function chatJSON(messages, opts = {}) {
  let lastErr;
  for (let k = 0; k < 2; k++) {
    const { text, usage, finish } = await chat(messages, { json: true, ...opts });
    try { return { data: parseJSON(text), text, usage }; } catch (e) { lastErr = new Error(`${e.message} (finish_reason=${finish}, ${text.length} chars)`); }
  }
  throw lastErr;
}
