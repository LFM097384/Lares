// hearthvoice-lares · 按 Lares 的环境变量(LARES_*)组装灶语的 provider。变量名是线上契约,别改(CONTRACT.md §1)。
// 本体 hearthvoice 只提供 provider 实现,不读环境变量;读 env 是插件的事。

import { MockAsr, MockLlm, MockTts, DashscopeAsr, DashscopeTts, OpenAiCompatLlm, FallbackLlm, DASHSCOPE_COMPAT_BASE, resolveExtraBody } from '../hearthvoice/index.mjs';
import { WebSocket } from '../lares-bridge/index.mjs';

/// 日志前缀保持 [ai-voice]:supervisor / 运维按它 grep
export const laresLog = (m) => process.stderr.write(`[ai-voice] ${m}\n`);

export function createProviders(kind, { env = process.env, mock = {}, log = () => {} } = {}) {
  if (kind === 'mock') {
    return { kind, asr: new MockAsr(mock.asr), llm: new MockLlm(mock.llm), tts: new MockTts(mock.tts) };
  }
  if (kind !== 'dashscope') throw new Error(`unknown_providers:${kind}`);
  return (async () => {
    const key = env.LARES_DASHSCOPE_API_KEY || '';
    if (!key) throw new Error('LARES_DASHSCOPE_API_KEY missing');
    const ds = { apiKey: key, host: env.LARES_DASHSCOPE_HOST || undefined, log: laresLog, WebSocket };
    return {
      kind,
      asr: new DashscopeAsr(ds),
      llm: await createLlm(env, { log }),
      tts: new DashscopeTts({ ...ds, model: env.LARES_AI_TTS_MODEL || undefined }),
    };
  })();
}

/**
 * LLM:LARES_AI_LLM_BASE_URL / LARES_AI_LLM_API_KEY(别名 LARES_AI_LLM_KEY)/ LARES_AI_LLM_MODEL / LARES_AI_LLM_EXTRA_BODY。
 * 主 LLM 不是 DashScope 且有 DashScope key 时,包一层 FallbackLlm:主 LLM 非 2xx / 超时 → 本轮改用 DashScope qwen-flash。
 */
export async function createLlm(env = process.env, { log = () => {}, fetchImpl } = {}) {
  const dsKey = String(env.LARES_DASHSCOPE_API_KEY ?? '').trim();
  const baseUrl = String(env.LARES_AI_LLM_BASE_URL ?? '').trim() || DASHSCOPE_COMPAT_BASE;
  const llmKey = String(env.LARES_AI_LLM_API_KEY ?? '').trim() || String(env.LARES_AI_LLM_KEY ?? '').trim() || dsKey;
  let extraBody;
  try { extraBody = resolveExtraBody(env.LARES_AI_LLM_EXTRA_BODY, baseUrl); } catch (e) { throw new Error(e.message.replace(/^extra_body/, 'LARES_AI_LLM_EXTRA_BODY')); }
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
