// ember-meet · 会议链接识别(纯函数,无依赖;ember-desk/links.mjs 也用它)。
// 只认识形状,不发网络请求。返回 { platform, meetingKey, link } 或 null(不是这个平台)。
// 主机是该平台但路径不像会议 → 抛 MeetUrlError(调用方翻成中文提示)。

export class MeetUrlError extends Error {
  constructor(code, message) { super(message); this.name = 'MeetUrlError'; this.code = code; }
}

const lc = (s) => String(s ?? '').toLowerCase();

/// Teams 主机:teams.microsoft.com、*.teams.microsoft.com(含 gov 子域等)、teams.live.com(免费 / 个人版)
export function isTeamsHost(hostname) {
  const h = lc(hostname);
  return h === 'teams.microsoft.com' || h.endsWith('.teams.microsoft.com') || h === 'teams.live.com';
}

/**
 * Teams 会议链接:
 *   https://teams.microsoft.com/l/meetup-join/19%3ameeting_…%40thread.v2/0?context=…   (工作 / 学校)
 *   https://teams.microsoft.com/meet/<数字>?p=<口令>                                     (新版短链)
 *   https://teams.live.com/meet/<数字>?p=<口令>                                          (免费版)
 *   https://teams.microsoft.com/v2/?meetingjoin=true#/l/meetup-join/…                   (网页内跳转)
 *   https://teams.microsoft.com/dl/launcher/launcher.html?url=/_#/l/meetup-join/…        (启动器)
 * @param {URL|string} input
 */
export function teamsOf(input) {
  const u = input instanceof URL ? input : new URL(String(input));
  if (!isTeamsHost(u.hostname)) return null;
  const host = lc(u.hostname);
  const p = u.pathname;
  let m = p.match(/^\/l\/meetup-join\/([^/]+)/i);
  if (m) return { platform: 'teams', host, meetingKey: `thread:${safeDecode(m[1])}`, link: u.href };
  m = p.match(/^\/meet\/(\d{6,20})\/?$/i);
  if (m) return { platform: 'teams', host, meetingKey: `meet:${m[1]}`, link: u.href, passcodePresent: u.searchParams.has('p') };
  // 跳转形态:真正的 meetup-join 路径藏在 hash 或 ?url= 里
  const inner = `${u.hash} ${u.searchParams.get('url') ?? ''}`;
  m = inner.match(/\/l\/meetup-join\/([^/?#\s]+)/i);
  if (m) return { platform: 'teams', host, meetingKey: `thread:${safeDecode(m[1])}`, link: u.href };
  throw new MeetUrlError('teams_bad_path', 'Teams 链接格式不认识(应为会议邀请里的「加入会议」链接,如 https://teams.microsoft.com/l/meetup-join/… 或 https://teams.live.com/meet/…)');
}

/// Google Meet(未实现,只识别形状):meet.google.com/abc-defg-hij
export function googleMeetOf(input) {
  const u = input instanceof URL ? input : new URL(String(input));
  if (lc(u.hostname) !== 'meet.google.com') return null;
  const m = u.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})\/?$/i);
  if (!m) throw new MeetUrlError('gmeet_bad_path', 'Google Meet 链接格式不认识(应为 https://meet.google.com/abc-defg-hij)');
  return { platform: 'google-meet', host: 'meet.google.com', meetingKey: `meet:${m[1].toLowerCase()}`, link: u.href };
}

/// 腾讯会议(未实现,只识别形状):meeting.tencent.com/dm/<code> 或 /p/<数字>
export function tencentOf(input) {
  const u = input instanceof URL ? input : new URL(String(input));
  const h = lc(u.hostname);
  if (!(h === 'meeting.tencent.com' || h.endsWith('.meeting.tencent.com') || h === 'voovmeeting.com' || h.endsWith('.voovmeeting.com'))) return null;
  const m = u.pathname.match(/^\/(?:dm|p|s)\/([A-Za-z0-9]{4,32})\/?$/);
  if (!m) throw new MeetUrlError('tencent_bad_path', '腾讯会议链接格式不认识(应为 https://meeting.tencent.com/dm/…)');
  return { platform: 'tencent', host: h, meetingKey: `tm:${m[1]}`, link: u.href };
}

function safeDecode(s) { try { return decodeURIComponent(s); } catch { return s; } }

/// 依次试所有平台。implemented=false 的平台 desk 会拒绝(给出原因),CLI 会报 not implemented。
export const PLATFORMS = Object.freeze([
  { platform: 'teams', of: teamsOf, implemented: true, label: 'Microsoft Teams' },
  { platform: 'google-meet', of: googleMeetOf, implemented: false, label: 'Google Meet' },
  { platform: 'tencent', of: tencentOf, implemented: false, label: '腾讯会议' },
]);

/**
 * @param {URL|string} input
 * @returns {null | {platform, host, meetingKey, link, implemented, label}}
 */
export function matchMeetingUrl(input) {
  let u;
  try { u = input instanceof URL ? input : new URL(String(input)); } catch { return null; }
  if (u.protocol !== 'https:') return null;
  for (const p of PLATFORMS) {
    const r = p.of(u);
    if (r) return { ...r, implemented: p.implemented, label: p.label };
  }
  return null;
}
