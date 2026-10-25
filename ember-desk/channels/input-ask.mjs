// 输入通道 · 提问(文字 / 剪贴板):经 API POST /ask。有 LLM key → createDeepSeekLLM;无 key → 确定性 mock 回答(llm:false)。
// 这是个人面:问题和回答只在本机(feed + 已启用的输出通道),不进任何会议。
// 测试注入 ctx.overrides.ask = { llm }(llm.chat(messages) → {text})
import { createDeepSeekLLM } from '../../ember/index.mjs';

export const SYSTEM_PROMPT = '你是「炉灵」,用户本机上的助手。用简洁的中文回答。你不知道任何会议里的内容,也不要编造。';

export default function inputAsk(ctx) {
  const ov = ctx.overrides?.ask ?? {};
  let llm = ov.llm !== undefined ? ov.llm : undefined;
  const getLlm = () => {
    if (llm !== undefined) return llm;
    const key = ctx.secrets?.LARES_AI_LLM_KEY;
    llm = key ? createDeepSeekLLM({ baseUrl: ctx.secrets.LARES_AI_LLM_BASE_URL || 'https://api.deepseek.com', key, model: ctx.secrets.LARES_AI_LLM_MODEL || 'deepseek-flash', retries: 1, timeoutMs: 60_000 }) : null;
    return llm;
  };
  let running = true;
  let asked = 0;
  return {
    id: 'ask',
    kind: 'input',
    name: '提问',
    describe: () => '向炉灵提问(托盘 / CLI / MCP / 状态页);回答进消息流',
    configured: () => true,
    async start() { running = true; },
    async stop() { running = false; },
    status: () => ({ running, detail: `${getLlm() ? 'LLM 已配置' : '无 LLM key(mock 回答)'} · 本次已问 ${asked}` }),
    async ask(text) {
      const q = String(text ?? '').trim().slice(0, 8000);
      if (!q) throw Object.assign(new Error('问题为空'), { status: 400 });
      asked++;
      const m = getLlm();
      if (!m) return { answer: `(未配置 LLM key,mock 回答)收到问题,共 ${q.length} 个字。配置 LARES_AI_LLM_KEY 后可得到真实回答。`, llm: false };
      const r = await m.chat([{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: q }], { temperature: 0.3, maxTokens: 2048 });
      return { answer: String(r?.text ?? '').trim() || '(空回答)', llm: true };
    },
  };
}
