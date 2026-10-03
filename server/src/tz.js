// 时区小工具:推送免打扰、连续打卡、周报都要按「某人 / 某圈的本地时间」算。
//
// 时区规格 TzSpec = { tz?: IANA 名(如 'Asia/Shanghai'), offsetMin?: 相对 UTC 的分钟偏移(东八区 = 480) }。
// 有合法 IANA 名就用它(自动处理夏令时),否则用固定偏移,再否则 UTC。
// Flutter 原生拿不到 IANA 名,客户端一般只报 offsetMin;IANA 留给将来与机器人 / 网页端。

const DAY_MS = 86_400_000;
const fmtCache = new Map();
const WEEKDAY = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/// IANA 名是否可用(Intl 认识)
export function validTz(tz) {
  if (typeof tz !== 'string' || !tz || tz.length > 64) return false;
  try { formatter(tz); return true; } catch { return false; }
}

function formatter(tz) {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', weekday: 'short',
    });
    if (fmtCache.size > 200) fmtCache.clear();
    fmtCache.set(tz, f);
  }
  return f;
}

/// 规范化:非法字段丢掉。返回 {tz} | {offsetMin} | {}
export function normalizeTz(spec) {
  if (!spec || typeof spec !== 'object') return {};
  if (validTz(spec.tz)) return { tz: spec.tz };
  const o = spec.offsetMin;
  if (Number.isInteger(o) && o >= -14 * 60 && o <= 14 * 60) return { offsetMin: o };
  return {};
}

const pad = (n) => String(n).padStart(2, '0');

/**
 * t 在该时区的本地日历信息。
 * @returns {{dayKey:string, dayIndex:number, minutes:number, dow:number}}
 *   dayKey 'YYYY-MM-DD';dayIndex = 本地日的「天序号」(按 UTC 日历换算,可做加减);
 *   minutes = 本地当天的第几分钟(0..1439);dow 0=周日..6=周六
 */
export function localParts(t, spec = {}) {
  const s = normalizeTz(spec);
  let y; let mo; let d; let h; let mi; let dow;
  if (s.tz) {
    const parts = {};
    for (const p of formatter(s.tz).formatToParts(new Date(t))) parts[p.type] = p.value;
    y = Number(parts.year); mo = Number(parts.month); d = Number(parts.day);
    h = Number(parts.hour) % 24; mi = Number(parts.minute); dow = WEEKDAY[parts.weekday] ?? 0;
  } else {
    const dt = new Date(t + (s.offsetMin ?? 0) * 60_000);
    y = dt.getUTCFullYear(); mo = dt.getUTCMonth() + 1; d = dt.getUTCDate();
    h = dt.getUTCHours(); mi = dt.getUTCMinutes(); dow = dt.getUTCDay();
  }
  const dayIndex = Math.floor(Date.UTC(y, mo - 1, d) / DAY_MS);
  return { dayKey: `${y}-${pad(mo)}-${pad(d)}`, dayIndex, minutes: h * 60 + mi, dow };
}

export const keyOfDayIndex = (i) => new Date(i * DAY_MS).toISOString().slice(0, 10);
export const dayIndexOfKey = (k) => Math.floor(Date.parse(`${k}T00:00:00Z`) / DAY_MS);

/// 本地时刻 minutes 是否落在 [start, end) 区间(支持跨午夜,如 23:00–08:00)。start==end 视为不生效。
export function inWindow(minutes, start, end) {
  if (start === end) return false;
  return start < end ? minutes >= start && minutes < end : minutes >= start || minutes < end;
}
