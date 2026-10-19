// 灶语(Hearthvoice)· 平台无关的语音 AI 本体。公共出口。
//
//   import { createHearthvoice } from '../hearthvoice/index.mjs';
//   const hv = createHearthvoice({ port, asr, llm, tts, policy: { config, usageFile, emit, log } });
//   if (hv.dailyCapReached()) …;          // 今天额度已满:别进房
//   await hv.start();                      // 订阅 port 事件 → port.join() → 接上出站音轨
//   hv.setConfig({ trigger: 'always' });   // 热更新
//   await hv.stop();                       // 收尾 → port.leave()
//
// port 接口见 ./PORT.md 与 ./port.mjs;provider 接口见 ./providers/index.mjs。
// 本体零平台依赖:不 import Lares / LiveKit;唯一的 npm 依赖 `ws`(DashScope provider)可注入。

import { normalizeAiVoiceConfig } from './config.mjs';
import { CostGuard } from './caps.mjs';
import { VoiceAgent } from './pipeline.mjs';
import { checkPort } from './port.mjs';

export const AGENT_NAME = '灶语';
export const AGENT_NAME_EN = 'Hearthvoice';

export * from './config.mjs';
export { checkPort, memoryPort, PORT_EVENTS, OUT_RATE, OUT_FRAME_SAMPLES } from './port.mjs';
export { VoiceAgent, Player, stripSpeakerPrefix } from './pipeline.mjs';
export { CostGuard, truncateReply, maxTokensFor, localDay } from './caps.mjs';
export { detectWake, detectPtt, parseWakeWords, DEFAULT_HOMOPHONES } from './wake.mjs';
export { chunkForSpeech, IncrementalChunker, VOICE_CHUNKING, cleanForSpeech } from './chunker.mjs';
export { History } from './history.mjs';
export { ROOM_RATE, FRAME_SAMPLES, ASR_RATE, resample, tone, EnergyVad, int16ToBase64, base64ToInt16 } from './audio.mjs';
export {
  MockAsr, MockLlm, MockTts,
  DashscopeAsr, DashscopeTts, DASHSCOPE_DEFAULT_HOST, ASR_MODEL, TTS_MODEL, TTS_RATE,
  OpenAiCompatLlm, FallbackLlm, DASHSCOPE_COMPAT_BASE, resolveExtraBody,
  WarmPool,
} from './providers/index.mjs';

const SILENT_OUT = Object.freeze({ captureFrame: () => {}, clear: () => {}, queuedMs: () => 0 });

/**
 * 创建一个灶语实例(还没进房;start() 才进)。
 * @param {object} o
 * @param {object} o.port   平台适配(PORT.md)
 * @param {object} o.asr    ASR provider
 * @param {object} o.llm    LLM provider
 * @param {object} o.tts    TTS provider
 * @param {object} [o.policy]
 * @param {object} [o.policy.config]      HearthvoiceConfig(未归一化也行;坏的抛错)
 * @param {string|null} [o.policy.usageFile]  用量 / 每日上限持久化文件
 * @param {(ev:object)=>void} [o.policy.emit] 结构化事件(turn / usage / cap_reached …)
 * @param {(m:string)=>void} [o.policy.log]   人读日志(不含正文,除非 logText)
 * @param {boolean} [o.policy.logText]
 * @param {() => void} [o.policy.onDailyCap]  当天额度用完(插件通常就此退出)
 * @param {() => number} [o.policy.now]
 * @param {object} [o.policy.agent]           透传给 VoiceAgent 的高级选项(paceScale / interruptMs / warm …)
 */
export function createHearthvoice({ port, asr, llm, tts, policy = {} } = {}) {
  checkPort(port);
  for (const [k, v] of Object.entries({ asr, llm, tts })) if (!v) throw new TypeError(`hearthvoice: ${k} provider required`);
  const nc = normalizeAiVoiceConfig(policy.config ?? {});
  if (!nc.ok) throw new TypeError(`hearthvoice: bad config: ${nc.detail}`);
  let config = nc.config;
  const emit = policy.emit ?? (() => {});
  const log = policy.log ?? (() => {});
  const now = policy.now ?? Date.now;
  const guard = new CostGuard({ usageFile: policy.usageFile ?? null, config, emit, now, log });
  const providers = { asr, llm, tts };
  let agent = null;
  let started = null;
  let stopping = null;
  const offs = [];

  const sub = (ev, fn) => { const off = port.on(ev, fn); if (typeof off === 'function') offs.push(off); };

  const hv = {
    port,
    guard,
    get agent() { return agent; },
    get config() { return config; },

    /// 今天的回答次数是否已满(满了就别进房)
    dailyCapReached() { const c = guard.check(); return !c.ok && c.reason === 'daily'; },

    /// 订阅 port → 建回合引擎 → port.join() → 接出站音轨。只执行一次。
    start() {
      started ??= (async () => {
        // 处理器先挂:有的平台在 join() 内部、连上之前就开始投递事件
        sub('audio', (id, pcm, rate, ch) => agent?.onAudioFrame(id, pcm, rate, ch));
        sub('chat', (m) => agent?.onChat(m));
        sub('capctl', (id, m) => agent?.onCaptionControl(id, m));
        sub('name', (id, n) => agent?.setName(id, n));
        sub('left', (id) => agent?.participantLeft(id));
        sub('joined', () => agent?.republishState());
        agent = new VoiceAgent({
          ...(policy.agent ?? {}),
          config,
          providers,
          sink: SILENT_OUT, // 进房后换成 port.audioOut()
          room: {
            publishCaption: (c) => port.publishCaption(c),
            sendChat: (t) => port.sendChat(t),
            publishState: (f) => port.publishState?.(f),
          },
          selfIdentity: port.selfId,
          isHuman: port.isHuman,
          emit,
          guard,
          now,
          log,
          logText: policy.logText === true,
          onDailyCap: () => policy.onDailyCap?.(),
        });
        await port.join();
        agent.sink = port.audioOut();
        agent.republishState(); // 进房前的初始状态发不出去:进房后补发
        return hv;
      })();
      return started;
    },

    /// 热更新配置。坏配置返回 false 且不改动;改名时调用 port.rename。
    setConfig(c) {
      const r = normalizeAiVoiceConfig(c ?? {});
      if (!r.ok) return false;
      const renamed = r.config.name !== config.name;
      config = r.config;
      if (agent) agent.setConfig(config); else guard.setConfig(config);
      if (renamed) { try { port.rename?.(config.name); } catch { /* */ } }
      return true;
    },

    /// 收尾:关回合引擎(停播、关 ASR/TTS 连接)→ port.leave()。幂等。
    stop() {
      stopping ??= (async () => {
        for (const off of offs.splice(0)) { try { off(); } catch { /* */ } }
        try { await agent?.close(); } catch { /* */ }
        try { await port.leave(); } catch { /* */ }
      })();
      return stopping;
    },
  };
  return hv;
}
