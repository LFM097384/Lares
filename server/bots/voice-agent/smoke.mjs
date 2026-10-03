// 真实 provider 冒烟(各打一次 LLM / TTS / ASR,打印延迟,不打印任何内容或密钥)。
// 用法:LARES_DASHSCOPE_API_KEY=… node bots/voice-agent/smoke.mjs
//   或  node bots/voice-agent/smoke.mjs --key-csv <DashScope 控制台导出的 apiKey CSV>
// 密钥只进 process.env,不回显、不落盘。
import { readFileSync } from 'node:fs';
import { DashscopeAsr, DashscopeTts } from './providers/dashscope.mjs';
import { OpenAiCompatLlm, DASHSCOPE_COMPAT_BASE } from './providers/openai_compat.mjs';
import { concatInt16, resample } from './audio.mjs';

const i = process.argv.indexOf('--key-csv');
if (i > 0) {
  for (const line of readFileSync(process.argv[i + 1], 'utf8').split(/\r?\n/)) {
    const [k, ...v] = line.split(',');
    if (k?.trim() === 'apiKey') process.env.LARES_DASHSCOPE_API_KEY = v.join(',').trim();
  }
}
const key = process.env.LARES_DASHSCOPE_API_KEY;
if (!key) { console.log(JSON.stringify({ error: 'no key' })); process.exit(2); }
const out = {};

// LLM
{
  const llm = new OpenAiCompatLlm({ baseUrl: DASHSCOPE_COMPAT_BASE, apiKey: key });
  const t0 = Date.now();
  let first = null;
  let chars = 0;
  let usage = null;
  try {
    for await (const ev of llm.stream({ model: 'qwen-flash', maxTokens: 40, messages: [{ role: 'user', content: '用一句话说你好' }] })) {
      if (ev.delta) { first ??= Date.now() - t0; chars += ev.delta.length; }
      if (ev.usage) usage = ev.usage;
    }
    out.llm = { ok: chars > 0, firstTokenMs: first, totalMs: Date.now() - t0, chars, usage };
  } catch (e) { out.llm = { ok: false, error: e.message }; }
}

// TTS
let ttsPcm = null;
{
  const tts = new DashscopeTts({ apiKey: key });
  const t0 = Date.now();
  try {
    const s = await tts.open({ voice: 'Cherry' });
    const openMs = Date.now() - t0;
    const parts = [];
    let firstAudio = null;
    let chars = 0;
    const t1 = Date.now();
    await new Promise((resolve, reject) => {
      s.setHandlers({
        onAudio: (_i, pcm) => { firstAudio ??= Date.now() - t1; parts.push(pcm); },
        onSegmentDone: (_i, u) => { chars = u.characters; resolve(); },
        onError: reject,
      });
      s.send('小助手，今天天气怎么样？');
      setTimeout(() => reject(new Error('tts_timeout')), 15000);
    });
    s.close();
    ttsPcm = concatInt16(parts);
    out.tts = { ok: ttsPcm.length > 0, openMs, firstAudioMs: firstAudio, audioMs: Math.round((ttsPcm.length / 24000) * 1000), characters: chars };
  } catch (e) { out.tts = { ok: false, error: e.message }; }
}

// ASR(用上面合成的语音)
if (ttsPcm) {
  const asr = new DashscopeAsr({ apiKey: key });
  const pcm16 = resample(ttsPcm, 24000, 16000);
  const t0 = Date.now();
  let partials = 0;
  try {
    const text = await new Promise((resolve, reject) => {
      let endAt = 0;
      const h = asr.open({
        identity: 'smoke',
        onPartial: () => { partials += 1; },
        onFinal: (t) => { out.asrFinalAfterEndMs = Date.now() - endAt; resolve(t); },
        onError: reject,
      });
      (async () => {
        for (let o = 0; o < pcm16.length; o += 1600) { h.send(pcm16.slice(o, o + 1600)); await new Promise((r) => setTimeout(r, 100)); }
        endAt = Date.now();
        for (let k = 0; k < 15; k++) { h.send(new Int16Array(1600)); await new Promise((r) => setTimeout(r, 100)); }
      })();
      setTimeout(() => { h.close(); reject(new Error('asr_timeout')); }, 20000);
    });
    const expect = '小助手今天天气怎么样';
    const got = String(text).replace(/[\s\p{P}]/gu, '');
    out.asr = { ok: got.length > 0, matches: got === expect, partials, finalAfterSpeechEndMs: out.asrFinalAfterEndMs, totalMs: Date.now() - t0 };
    delete out.asrFinalAfterEndMs;
  } catch (e) { out.asr = { ok: false, error: e.message }; }
}

console.log(JSON.stringify(out, null, 1));
process.exit(0);
