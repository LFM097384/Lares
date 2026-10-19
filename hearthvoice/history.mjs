// 「对方实际听到了什么」:被打断时只把听到的部分记进对话历史。
// 移植自 v2v-lab logic.py(spoken_until_from_playback / messages_as_experienced)。
// 宁可少算:让 AI 以为你听到了一个你其实没听到的问题,比让它重复半句更糟。

import { cleanForSpeech } from './chunker.mjs';

const isSpace = (ch) => /\s/u.test(ch);
const isAlnum = (ch) => /[\p{L}\p{N}]/u.test(ch);
const isWide = (ch) => ch.codePointAt(0) > 0x2e80;

/// 不在拉丁单词中间切:CJK 字各自成词;拉丁词退回到前一个空白(或块首)。
export function backToBoundary(text, pos) {
  pos = Math.max(0, Math.min(pos, text.length));
  if (pos === 0 || pos === text.length) return pos;
  const prev = text[pos - 1];
  const next = text[pos];
  if (isSpace(prev) || isSpace(next)) return pos;
  if (isWide(prev) || isWide(next)) return pos;
  if (!(isAlnum(prev) && isAlnum(next))) return pos;
  let i = pos;
  while (i > 0 && isAlnum(text[i - 1]) && !isWide(text[i - 1])) i -= 1;
  return i;
}

/**
 * @param {string} stored     完整回复(已清洗)
 * @param {string[]} chunks   依次送 TTS 的块
 * @param {number|null} chunkIndex 正在播(或下一个该播)的块
 * @param {number|null} fraction   该块播放进度 0..1
 * @returns {number} stored 中已听到的字符偏移
 */
export function spokenUntilFromPlayback(stored, chunks, chunkIndex, fraction) {
  if (chunkIndex === null || chunkIndex === undefined || !(chunkIndex >= 0)) return 0;
  let f = Number(fraction ?? 0);
  if (!Number.isFinite(f)) f = 0;
  f = Math.max(0, Math.min(1, f));
  let cursor = 0;
  const spans = [];
  for (const raw of chunks) {
    const disp = cleanForSpeech(raw);
    if (!disp) { spans.push([cursor, cursor]); continue; }
    const at = stored.indexOf(disp, cursor);
    if (at < 0) { spans.push([cursor, cursor]); continue; }
    spans.push([at, at + disp.length]);
    cursor = at + disp.length;
  }
  if (chunkIndex >= spans.length) return spans.length ? stored.length : 0;
  const [start, end] = spans[chunkIndex];
  const pos = start + Math.floor((end - start) * f);
  if (pos >= end) return end;
  if (pos > start) {
    const cut = backToBoundary(stored, pos);
    if (cut > start) return cut;
  }
  return chunkIndex > 0 ? spans[chunkIndex - 1][1] : start;
}

/**
 * 由各块的样本数与已播样本数算出 (chunkIndex, fraction)。
 * @param {number[]} chunkSamples 每块音频的总样本数(还没合成完的块给已知部分;未知 = 0)
 * @param {number} played 已经真正播出去的样本数(累计)
 */
export function playbackPosition(chunkSamples, played) {
  let acc = 0;
  for (let i = 0; i < chunkSamples.length; i++) {
    const n = chunkSamples[i];
    if (played < acc + n) return { chunkIndex: i, fraction: n > 0 ? (played - acc) / n : 0 };
    acc += n;
  }
  return { chunkIndex: chunkSamples.length, fraction: 0 };
}

export function splitHeardAndUnsaid(entry) {
  const content = String(entry.content ?? '');
  if (entry.role !== 'assistant' || !entry.interrupted) return [content, ''];
  const su = entry.spokenUntil;
  if (!Number.isInteger(su) || su < 0 || su > content.length) return [content, ''];
  return [content.slice(0, su), content.slice(su)];
}

export function messagesAsExperienced(history) {
  const out = [];
  for (const e of history) {
    const [heard, unsaid] = splitHeardAndUnsaid(e);
    if (unsaid && !heard.trim()) continue;
    out.push({ role: e.role, content: unsaid ? heard : e.content });
  }
  return out;
}

/// 只保留最近 maxTurns 轮(一轮 = user + assistant);开头不留孤立的 assistant。
export class History {
  constructor(maxTurns = 10) {
    this.maxTurns = maxTurns;
    this.items = [];
  }
  addUser(content) { this.items.push({ role: 'user', content }); this._trim(); }
  addAssistant(content, { interrupted = false, spokenUntil } = {}) {
    this.items.push({ role: 'assistant', content, interrupted, ...(interrupted ? { spokenUntil } : {}) });
    this._trim();
  }
  _trim() {
    const max = this.maxTurns * 2;
    if (this.items.length > max) this.items.splice(0, this.items.length - max);
    while (this.items.length && this.items[0].role === 'assistant') this.items.shift();
  }
  messages() { return messagesAsExperienced(this.items); }
  clear() { this.items = []; }
}
