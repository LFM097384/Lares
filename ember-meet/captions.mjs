// ember-meet · 字幕去重状态机(纯 Node,无 DOM、无计时器;时间由调用方传入,测试可控)。
//
// 输入:平台字幕区的「快照」—— 文档顺序的条目数组 [{key, speaker, text}]。
//   key     = 页面脚本给每个字幕 DOM 节点分的编号(同一节点就地改字 → key 不变)
//   speaker = 当前显示的说话人;text = 当前显示的文字
// 平台(Teams 等)会就地改写同一条字幕:逐词变长、改标点、偶尔整句改写;虚拟列表还会把同一句换个新节点重渲染。
// 逐次变化都发出去就是噪音,所以每句只在「定稿」时发一次:
//   · 不是最后一条(已被新条目取代)且 supersededMs 内没再变  → 定稿
//   · 是最后一条,且 stableMs 内没再变                         → 定稿
//   · 从快照里消失:先进 limbo;supersededMs 内若出现同一说话人、文字以它开头的新节点 → 新节点继承它(重渲染);
//     否则定稿(滚出窗口)
//   · flush()(离会)                                            → 未发的全部定稿
// 已发过的条目又变长:只把多出来的尾巴当新的一句;变成另一句(改写)→ 丢弃,不重复发。
// 内容去重:最近发过的 (说话人, 规范化文字) 不再发。自己的名字(炉灵)永不发。

export const DEFAULTS = Object.freeze({ stableMs: 3500, supersededMs: 1200, minChars: 2, recent: 64 });

/// 显示名规范化:去掉平台加的身份后缀(访客 / 未验证 / 外部 …)、零宽 / 方向控制字符、多余空白。
const SUFFIX = /\s*[（(]\s*(?:guest|访客|訪客|來賓|来宾|unverified|未验证|未驗證|external|外部|anonymous|匿名|organi[sz]er|组织者|組織者|presenter|演示者)\s*[)）]\s*$/i;
export function normalizeName(name) {
  let s = String(name ?? '').replace(/[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  for (let i = 0; i < 3 && SUFFIX.test(s); i++) s = s.replace(SUFFIX, '').trim();
  return s;
}

export const normText = (t) => String(t ?? '').replace(/\s+/g, ' ').trim();
/// 比较用:小写、去空白和标点(平台改标点不算改内容)
export const cmpKey = (t) => normText(t).toLowerCase().replace(/[\s,.!?;:，。！？；：、"'“”‘’…·()（）[\]【】-]+/g, '');

export class CaptionTracker {
  /**
   * @param {object} [o]
   * @param {(u:{speaker:string,text:string,key:string,at:number,reason:string})=>void} [o.onFinal]
   * @param {string[]} [o.ignoreSpeakers]
   * @param {number} [o.stableMs] [o.supersededMs] [o.minChars] [o.recent]
   */
  constructor({ onFinal = () => {}, ignoreSpeakers = [], ...opts } = {}) {
    this.o = { ...DEFAULTS, ...opts };
    this.onFinal = onFinal;
    this.ignore = new Set(ignoreSpeakers.map((n) => normalizeName(n).toLowerCase()).filter(Boolean));
    this.entries = new Map(); // key → {speaker, text, changedAt, emittedText|null}
    this.limbo = []; // [{entry, goneAt}]
    this.recent = [];
    this.lastKey = null;
    this.stats = { snapshots: 0, emitted: 0, deltas: 0, dupes: 0, rewrites: 0, adopted: 0, ignored: 0 };
  }

  /** 喂一次快照,返回本次定稿的话语(同时逐条回调 onFinal)。 */
  update(snapshot, now) {
    this.stats.snapshots++;
    const out = [];
    const list = (Array.isArray(snapshot) ? snapshot : []).filter((e) => e && e.key != null && normText(e.text));
    const seen = new Set(list.map((e) => String(e.key)));
    // 先把消失的节点放进 limbo,同一快照里的新节点才能继承它(重渲染常在两次轮询之间完成)
    for (const [key, cur] of this.entries) {
      if (seen.has(key)) continue;
      this.entries.delete(key);
      this.limbo.push({ key, entry: cur, goneAt: now }); // 已发完的也进 limbo:重渲染时被继承就不会重复发
    }
    for (const e of list) {
      const key = String(e.key);
      const speaker = normalizeName(e.speaker);
      const text = normText(e.text);
      let cur = this.entries.get(key);
      if (!cur) {
        cur = this._adopt(speaker, text) ?? { speaker, text, changedAt: now, emittedText: null };
        if (cur.text !== text) { cur.text = text; cur.changedAt = now; }
        if (speaker) cur.speaker = speaker;
        this.entries.set(key, cur);
        continue;
      }
      if (cur.text !== text || (speaker && cur.speaker !== speaker)) {
        cur.text = text;
        if (speaker) cur.speaker = speaker;
        cur.changedAt = now;
      }
    }
    this.lastKey = list.length ? String(list[list.length - 1].key) : null;
    this._sweep(now, out);
    return out;
  }

  /** 没有新快照时按时间推进(定时器调用)。 */
  tick(now) { const out = []; this._sweep(now, out); return out; }

  /** 离会:所有未发的定稿。 */
  flush(now = Date.now()) {
    const out = [];
    for (const l of this.limbo) this._finalise(l.key, l.entry, now, 'flush', out);
    for (const [key, cur] of this.entries) this._finalise(key, cur, now, 'flush', out);
    this.limbo = [];
    this.entries.clear();
    return out;
  }

  /// 重渲染:limbo 里同一说话人、文字是新文字前缀(或相同)的条目 → 新节点继承它
  _adopt(speaker, text) {
    const k = cmpKey(text);
    for (let i = this.limbo.length - 1; i >= 0; i--) {
      const { entry } = this.limbo[i];
      if (speaker && entry.speaker && entry.speaker !== speaker) continue;
      if (k.startsWith(cmpKey(entry.text))) { this.limbo.splice(i, 1); this.stats.adopted++; return entry; }
    }
    return null;
  }

  _sweep(now, out) {
    this.limbo = this.limbo.filter((l) => {
      if (now - l.goneAt < this.o.supersededMs) return true;
      this._finalise(l.key, l.entry, now, 'gone', out);
      return false;
    });
    for (const [key, cur] of this.entries) {
      const idle = now - cur.changedAt;
      const isLast = key === this.lastKey;
      if ((!isLast && idle >= this.o.supersededMs) || (isLast && idle >= this.o.stableMs)) this._finalise(key, cur, now, isLast ? 'stable' : 'superseded', out);
    }
  }

  _finalise(key, cur, now, reason, out) {
    if (cur.emittedText === cur.text) return;
    let text = cur.text;
    if (cur.emittedText !== null) {
      if (cmpKey(cur.text).startsWith(cmpKey(cur.emittedText))) { text = tailAfter(cur.text, cur.emittedText); this.stats.deltas++; } else { this.stats.rewrites++; cur.emittedText = cur.text; return; }
    }
    cur.emittedText = cur.text;
    text = normText(text);
    if (cmpKey(text).length < this.o.minChars) return;
    if (!cur.speaker || this.ignore.has(cur.speaker.toLowerCase())) { this.stats.ignored++; return; }
    const rk = `${cmpKey(cur.speaker)}\u0000${cmpKey(text)}`;
    if (this.recent.includes(rk)) { this.stats.dupes++; return; }
    this.recent.push(rk);
    if (this.recent.length > this.o.recent) this.recent.shift();
    const u = { speaker: cur.speaker, text, key, at: now, reason };
    this.stats.emitted++;
    out.push(u);
    try { this.onFinal(u); } catch { /* 消费方出错不影响状态机 */ }
  }
}

/// full 以 prefix 开头(忽略空白 / 标点差异)时,返回 full 中 prefix 之后的部分。
export function tailAfter(full, prefix) {
  const target = cmpKey(prefix).length;
  let n = 0;
  for (let i = 0; i < full.length; i++) {
    if (n >= target) return full.slice(i).replace(/^[\s,.!?;:，。！？；：、]+/, '');
    n += cmpKey(full[i]).length;
  }
  return '';
}
