// 费用护栏:每小时(滑动窗口)/ 每天(本地日、按圈持久化)回答次数上限,回复长度截断,用量记账。
// 纯逻辑 + 同步文件读写;时钟可注入。

import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import path from 'node:path';

const HOUR_MS = 3_600_000;

/// 本地日 'YYYY-MM-DD'。tzOffsetMin 不给则用系统时区。
export function localDay(t, tzOffsetMin) {
  const off = tzOffsetMin ?? -new Date(t).getTimezoneOffset();
  return new Date(t + off * 60_000).toISOString().slice(0, 10);
}

/// 由回复字数上限推 max_tokens:中文约 1 token/字,留 1.5 倍余量给标点和英文。
export function maxTokensFor(maxReplyChars) {
  return Math.max(32, Math.ceil(maxReplyChars * 1.5) + 16);
}

/// 截到 maxChars 以内;尽量在最后一个句末/逗号处收住,否则硬截并补「…」。
export function truncateReply(text, maxChars) {
  const s = String(text ?? '');
  const chars = [...s];
  if (chars.length <= maxChars) return s;
  const head = chars.slice(0, maxChars).join('');
  const m = head.match(/^[\s\S]*[。！？!?…](?=[^。！？!?…]*$)/u);
  if (m && [...m[0]].length >= maxChars * 0.5) return m[0];
  const c = head.match(/^[\s\S]*[，,、；;](?=[^，,、；;]*$)/u);
  if (c && [...c[0]].length >= maxChars * 0.6) return c[0].replace(/[，,、；;]$/u, '…');
  return [...head].slice(0, maxChars - 1).join('') + '…';
}

export class CostGuard {
  /**
   * @param {object} o
   * @param {() => number} [o.now]
   * @param {string|null} [o.usageFile] LARES_AI_USAGE_FILE
   * @param {number} [o.tzOffsetMin]
   * @param {{maxTurnsPerHour:number, maxTurnsPerDay:number, maxReplyChars:number}} o.config
   * @param {(ev:object) => void} [o.emit] stdout 事件(usage / cap_reached)
   */
  constructor({ now = Date.now, usageFile = null, tzOffsetMin, config, emit = () => {} }) {
    this.now = now;
    this.usageFile = usageFile;
    this.tz = tzOffsetMin;
    this.config = config;
    this.emit = emit;
    this.hour = []; // 时间戳
    this.data = { days: {} };
    this._load();
  }

  setConfig(config) { this.config = config; }

  _load() {
    if (!this.usageFile) return;
    try {
      const j = JSON.parse(readFileSync(this.usageFile, 'utf8'));
      if (j && typeof j === 'object' && j.days && typeof j.days === 'object') this.data = { days: j.days };
      // 重启后每小时窗口也能续上
      if (Array.isArray(j?.recent)) this.hour = j.recent.filter((t) => Number.isFinite(t));
    } catch { /* 没有或坏了:从零开始 */ }
  }

  _save() {
    if (!this.usageFile) return;
    const days = Object.keys(this.data.days).sort();
    while (days.length > 14) delete this.data.days[days.shift()]; // 只留两周
    const body = JSON.stringify({ days: this.data.days, recent: this.hour }, null, 0);
    try {
      mkdirSync(path.dirname(this.usageFile), { recursive: true });
      const tmp = `${this.usageFile}.${process.pid}.tmp`;
      writeFileSync(tmp, body);
      renameSync(tmp, this.usageFile);
    } catch (e) {
      process.stderr.write(`[ai-voice] 写用量文件失败: ${e.message}\n`);
    }
  }

  _today() {
    const k = localDay(this.now(), this.tz);
    this.data.days[k] ??= { turns: 0, llmIn: 0, llmOut: 0, ttsChars: 0, asrSec: 0 };
    return this.data.days[k];
  }

  _pruneHour() {
    const cutoff = this.now() - HOUR_MS;
    while (this.hour.length && this.hour[0] <= cutoff) this.hour.shift();
  }

  turnsToday() { return this._today().turns; }

  /// 能不能再开一轮?{ok:true} | {ok:false, reason:'hourly'|'daily', retryInMs?}
  check() {
    this._pruneHour();
    if (this._today().turns >= this.config.maxTurnsPerDay) return { ok: false, reason: 'daily' };
    if (this.hour.length >= this.config.maxTurnsPerHour) {
      return { ok: false, reason: 'hourly', retryInMs: this.hour[0] + HOUR_MS - this.now() };
    }
    return { ok: true };
  }

  /// 记一轮(真正开始调 LLM 时)。返回记账后是否已经到了每日上限。
  recordTurn() {
    this._pruneHour();
    this.hour.push(this.now());
    const d = this._today();
    d.turns += 1;
    this._save();
    const dailyReached = d.turns >= this.config.maxTurnsPerDay;
    if (dailyReached) this.emit({ ev: 'cap_reached', scope: 'daily', turns: d.turns, day: localDay(this.now(), this.tz) });
    return { dailyReached };
  }

  /// 用量:{llmIn, llmOut, ttsChars, asrSec}(缺省为 0)
  addUsage(u) {
    const d = this._today();
    const add = { llmIn: u.llmIn ?? 0, llmOut: u.llmOut ?? 0, ttsChars: u.ttsChars ?? 0, asrSec: u.asrSec ?? 0 };
    if (!add.llmIn && !add.llmOut && !add.ttsChars && !add.asrSec) return;
    d.llmIn += add.llmIn;
    d.llmOut += add.llmOut;
    d.ttsChars += add.ttsChars;
    d.asrSec = Math.round((d.asrSec + add.asrSec) * 10) / 10;
    this.emit({ ev: 'usage', ...add, asrSec: Math.round(add.asrSec * 10) / 10, day: localDay(this.now(), this.tz), total: { ...d } });
    this._save();
  }

  get maxTokens() { return maxTokensFor(this.config.maxReplyChars); }
}
