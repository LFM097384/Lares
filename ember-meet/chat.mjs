// ember-meet · 会议聊天的「新消息」跟踪(纯 Node)。
// 输入:页面探针给的聊天快照 [{key, author, text, mine}](文档顺序,虚拟列表可能只含一部分)。
// 输出:第一次见到的消息,去掉:进会前就有的历史(baseline)、自己发的(mine / 作者名是自己 / 与刚发过的文字相同)。
import { normalizeName, cmpKey } from './captions.mjs';

export class ChatTracker {
  /**
   * @param {object} [o]
   * @param {string} [o.selfName]     炉灵在会里的显示名
   * @param {number} [o.echoMs]       自己发出的文字在这段时间内出现在列表里 → 当回声丢掉
   */
  constructor({ selfName = '', echoMs = 120_000, max = 2000 } = {}) {
    this.self = normalizeName(selfName).toLowerCase();
    this.echoMs = echoMs;
    this.max = max;
    this.seen = new Set();
    this.order = [];
    this.sent = []; // [{k, at}]
    this.based = false;
  }

  /// 进会后第一次读到的列表 = 历史,不当命令处理
  baseline(items) { for (const it of items ?? []) this._mark(it); this.based = true; }

  /// 炉灵自己刚发了一条(sendChat 成功后调用),用于回声过滤
  noteSent(text, now = Date.now()) {
    this.sent.push({ k: cmpKey(text), at: now });
    this.sent = this.sent.filter((s) => now - s.at < this.echoMs);
  }

  /** @returns {{key:string, author:string, text:string}[]} */
  update(items, now = Date.now()) {
    if (!this.based) { this.baseline(items); return []; }
    const out = [];
    for (const it of items ?? []) {
      if (!it || !it.text || this.seen.has(String(it.key))) continue;
      this._mark(it);
      const author = normalizeName(it.author);
      if (it.mine || (author && author.toLowerCase() === this.self)) continue;
      const k = cmpKey(it.text);
      const echo = this.sent.findIndex((s) => s.k === k && now - s.at < this.echoMs);
      if (echo >= 0 && !author) { this.sent.splice(echo, 1); continue; }
      if (!author) continue; // 看不出是谁发的:不能当命令(签名按人计数)
      out.push({ key: String(it.key), author, text: String(it.text) });
    }
    return out;
  }

  _mark(it) {
    const k = String(it.key);
    if (this.seen.has(k)) return;
    this.seen.add(k);
    this.order.push(k);
    if (this.order.length > this.max) this.seen.delete(this.order.shift());
  }
}
