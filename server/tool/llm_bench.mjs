// LLM-only 首 token 延迟基准(走 bot 自己的 createLlm / OpenAiCompatLlm,流式)。
// 用法:node tool/llm_bench.mjs [--rounds 1] [--qwen]
//   DeepSeek:env LARES_AI_LLM_BASE_URL(默认 https://api.deepseek.com)/ LARES_AI_LLM_KEY / LARES_AI_LLM_MODEL(默认 deepseek-flash)
//   --qwen:另测 DashScope qwen-flash(需 env LARES_DASHSCOPE_API_KEY,或 --key-csv)
//   --thinking:另测 DeepSeek 开思考(EXTRA_BODY={})对照
// 密钥只读 env,不回显、不落盘;只打印延迟数字。
import { readFileSync } from 'node:fs';
import { OpenAiCompatLlm, DASHSCOPE_COMPAT_BASE, resolveExtraBody } from '../bots/voice-agent/providers/openai_compat.mjs';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const rounds = Number(opt('--rounds', '1'));
const csv = opt('--key-csv', null);
if (csv) for (const line of readFileSync(csv, 'utf8').split(/\r?\n/)) { const [k, ...v] = line.split(','); if (k?.trim() === 'apiKey') process.env.LARES_DASHSCOPE_API_KEY = v.join(',').trim(); }

const SYS = '你是语音聊天室里的助手「小助手」。回答会被念出来:口语化、简短,一两句话,不用列表和表情。';
const PROMPTS = [
  '请用一句话介绍一下北京。', '上海有什么好吃的？一句话回答。', '推荐一项适合冬天的运动，简短一点。', '杭州最有名的景点是哪里？一句话。',
  '明天早上八点提醒大家集合，你怎么说？', '给我讲个特别短的笑话。', '学习累了怎么放松一下？', '一加一等于几？',
];

async function bench(label, llm, model) {
  llm.prewarm?.();
  await new Promise((r) => setTimeout(r, 800)); // 让预热连接先建好(bot 里也会在有人开口时预热)
  const first = [];
  const total = [];
  let errors = 0;
  for (let r = 0; r < rounds; r++) {
    for (const p of PROMPTS) {
      const t0 = performance.now();
      let ft = null;
      try {
        for await (const ev of llm.stream({ messages: [{ role: 'system', content: SYS }, { role: 'user', content: p }], model, maxTokens: 196 })) {
          if (ev.delta && ft == null) ft = performance.now() - t0;
        }
        if (ft == null) errors += 1; else { first.push(Math.round(ft)); total.push(Math.round(performance.now() - t0)); }
      } catch (e) { errors += 1; console.error(`${label}: ${String(e.message).slice(0, 80)}`); }
    }
  }
  const pct = (a, q) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.ceil(q * s.length) - 1)] : null; };
  const out = { label, n: first.length, errors, firstTokenP50: pct(first, 0.5), firstTokenP90: pct(first, 0.9), totalP50: pct(total, 0.5), firstTokenRaw: first };
  console.log(JSON.stringify(out));
  return out;
}

const dsBase = process.env.LARES_AI_LLM_BASE_URL || 'https://api.deepseek.com';
const dsKey = process.env.LARES_AI_LLM_KEY || process.env.LARES_AI_LLM_API_KEY;
const dsModel = process.env.LARES_AI_LLM_MODEL || 'deepseek-flash';
if (dsKey) {
  await bench(`deepseek ${dsModel} thinking=disabled`, new OpenAiCompatLlm({ baseUrl: dsBase, apiKey: dsKey, model: dsModel, extraBody: resolveExtraBody(process.env.LARES_AI_LLM_EXTRA_BODY, dsBase) }));
  if (flag('--thinking')) await bench(`deepseek ${dsModel} thinking=default(on)`, new OpenAiCompatLlm({ baseUrl: dsBase, apiKey: dsKey, model: dsModel, extraBody: {} }));
} else console.error('no LARES_AI_LLM_KEY: skip DeepSeek');
if (flag('--qwen')) {
  const k = process.env.LARES_DASHSCOPE_API_KEY;
  if (k) await bench('dashscope qwen-flash', new OpenAiCompatLlm({ baseUrl: DASHSCOPE_COMPAT_BASE, apiKey: k, model: 'qwen-flash' }), 'qwen-flash');
  else console.error('no LARES_DASHSCOPE_API_KEY: skip qwen-flash');
}
