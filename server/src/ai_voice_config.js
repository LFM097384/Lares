// lares.ai-voice 配置(= 插件 config)。契约 CONTRACT.md §3。
// 由服务端 plugins.js(内置插件 normalizeConfig / settingsSchema)与 bot 进程共用。
// 注意:config 会广播给圈内成员 —— 这里永远不放任何密钥。

export const AI_VOICE_DEFAULT_PERSONA =
  '你是圈子里的语音小助手。用口语化、温暖、简短的中文回答,一般一两句话;不确定就直说不知道;不要使用 Markdown、列表或表情符号。';

export const AI_VOICE_DEFAULTS = Object.freeze({
  name: '小助手',
  wakeWords: '小助手',
  persona: AI_VOICE_DEFAULT_PERSONA,
  trigger: 'wake',
  voice: 'Cherry',
  model: 'qwen-flash',
  maxReplyChars: 120,
  maxTurnsPerHour: 30,
  maxTurnsPerDay: 200,
  interrupt: true,
});

export const AI_VOICE_TRIGGERS = Object.freeze(['wake', 'always', 'ptt']);
const STR_MAX = { name: 16, wakeWords: 100, persona: 1000, voice: 40, model: 64 };
const INT_RANGE = { maxReplyChars: [20, 400], maxTurnsPerHour: [1, 200], maxTurnsPerDay: [1, 2000] };
const TOKEN_RE = /^[A-Za-z0-9._-]+$/; // voice / model:只收标识符,防奇怪字符进上游请求
const clampInt = (v, [lo, hi]) => Math.min(hi, Math.max(lo, Math.round(v)));
const cut = (s, n) => [...s].slice(0, n).join('');

/**
 * 宽松归一:缺省补默认,越界夹紧,超长截断,未知字段丢弃;类型错的字段回落默认。
 * 只有「根本不是对象」才失败。
 * @returns {{ok:true, config:object} | {ok:false, detail:string}}
 */
export function normalizeAiVoiceConfig(cfg) {
  if (cfg === null || typeof cfg !== 'object' || Array.isArray(cfg)) return { ok: false, detail: 'not_object' };
  const out = { ...AI_VOICE_DEFAULTS };
  for (const [k, max] of Object.entries(STR_MAX)) {
    const v = cfg[k];
    if (typeof v !== 'string') continue;
    const s = cut(v.trim(), max);
    if (!s) continue;
    if ((k === 'voice' || k === 'model') && !TOKEN_RE.test(s)) continue;
    out[k] = s;
  }
  if (AI_VOICE_TRIGGERS.includes(cfg.trigger)) out.trigger = cfg.trigger;
  for (const [k, range] of Object.entries(INT_RANGE)) {
    const v = cfg[k];
    if (typeof v === 'number' && Number.isFinite(v)) out[k] = clampInt(v, range);
  }
  if (typeof cfg.interrupt === 'boolean') out.interrupt = cfg.interrupt;
  return { ok: true, config: out };
}

export const AI_VOICE_SETTINGS_SCHEMA = Object.freeze({
  type: 'object',
  additionalProperties: false,
  properties: {
    name: { type: 'string', maxLength: 16, default: AI_VOICE_DEFAULTS.name, title: '名字(也是唤醒词)' },
    wakeWords: { type: 'string', maxLength: 100, default: AI_VOICE_DEFAULTS.wakeWords, title: '额外唤醒词(逗号/顿号/空格分隔)' },
    persona: { type: 'string', maxLength: 1000, default: AI_VOICE_DEFAULTS.persona, title: '人设(系统提示)' },
    trigger: {
      type: 'string', enum: [...AI_VOICE_TRIGGERS], default: AI_VOICE_DEFAULTS.trigger, title: '触发方式',
      description: 'wake = 叫名字/唤醒词;always = 有人说完就回答;ptt = 仅文字聊天里以 @AI 或 @名字 开头的消息',
    },
    voice: { type: 'string', maxLength: 40, default: AI_VOICE_DEFAULTS.voice, title: '音色' },
    model: { type: 'string', maxLength: 64, default: AI_VOICE_DEFAULTS.model, title: '对话模型' },
    maxReplyChars: { type: 'integer', minimum: 20, maximum: 400, default: AI_VOICE_DEFAULTS.maxReplyChars, title: '单次回复最多字数' },
    maxTurnsPerHour: { type: 'integer', minimum: 1, maximum: 200, default: AI_VOICE_DEFAULTS.maxTurnsPerHour, title: '每小时最多回答次数' },
    maxTurnsPerDay: { type: 'integer', minimum: 1, maximum: 2000, default: AI_VOICE_DEFAULTS.maxTurnsPerDay, title: '每天最多回答次数' },
    interrupt: { type: 'boolean', default: AI_VOICE_DEFAULTS.interrupt, title: '有人插话时停止说话' },
  },
});
