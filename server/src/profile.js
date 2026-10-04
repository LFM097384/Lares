// 成员资料(profile_set):昵称 / 头像 emoji / 一句话签名的清洗与校验。纯函数,无状态。
//
// 为什么要清洗:名字会出现在别人的房间列表、大厅摘要、推送里。控制字符能搅乱排版,
// bidi 覆盖符(U+202E 等)能把「张三」显示成别的样子冒充他人。

export const PROFILE_NAME_MAX = 24;
export const PROFILE_BIO_MAX = 40;

const segmenter = new Intl.Segmenter('und', { granularity: 'grapheme' });

// C0/C1 控制符、bidi 嵌入/覆盖/隔离、零宽空格/LRM/RLM/BOM。保留 U+200D(ZWJ,组合 emoji 要用)
const STRIP_RE = /[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069\u200B\u200E\u200F\uFEFF]/g;

export function stripControl(s) {
  if (typeof s !== 'string') return '';
  return s
    .replace(/[\t\n\r\v\f]/g, ' ')
    .replace(STRIP_RE, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function graphemes(s) {
  return [...segmenter.segment(s)].map((x) => x.segment);
}

export function capGraphemes(s, n) {
  const g = graphemes(s);
  return g.length <= n ? s : g.slice(0, n).join('');
}

/// 昵称:非字符串 / 清洗后为空 → null
export function cleanName(raw) {
  if (typeof raw !== 'string') return null;
  const s = capGraphemes(stripControl(raw), PROFILE_NAME_MAX).trim();
  return s ? s : null;
}

/// 签名:'' 表示清空
export function cleanBio(raw) {
  if (typeof raw !== 'string') return '';
  return capGraphemes(stripControl(raw), PROFILE_BIO_MAX).trim();
}

/// 头像 emoji:'' 表示清空;不是单个 emoji → null(无效)
export function cleanEmoji(raw) {
  if (typeof raw !== 'string') return null;
  const s = stripControl(raw);
  if (s === '') return '';
  if (s.length > 16) return null;
  if (graphemes(s).length !== 1) return null;
  if (!/\p{Extended_Pictographic}/u.test(s) && !/\p{Regional_Indicator}{2}/u.test(s)) return null;
  return s;
}

/// AI 语音助手(u_ai_*)与机器人(bot:*)的资料由服务器管,不许自己改
export function profileSetAllowed(userId) {
  if (typeof userId !== 'string' || !userId) return false;
  return !userId.startsWith('u_ai_') && !userId.startsWith('bot:');
}
