// 唤醒词检测(纯函数,无 I/O)。
//
// 决策:
// - 唤醒词在一句话里**任何位置**精确出现都算(「今天天气怎么样小助手」也行),查询里去掉唤醒词本身。
// - 容错只在**句首区域**(去掉语气词后前 8 个字内)放开,避免句中偶然近似词误触发:
//   * 同音/近音字表(助↔组/主/住/祝,手↔首/守/收 …)算 0 代价;
//   * 长度 ≥3 的唤醒词允许再错 1 个任意字(ASR 偶发错字)。
// - 归一化:去标点/空白、全角转半角、拉丁字母小写;句首语气词(嗯/那个/哎/喂/hey …)跳过。
// - ptt:聊天消息以 `@AI` / `@名字` 开头(大小写不敏感,全角 @ 也认)。

const FILLERS = ['那个', '这个', '就是', '嗯', '呃', '额', '啊', '哎', '诶', '欸', '喂', '哈', '嘿', '哦', '噢', '唉', 'hey', 'hi', 'ok', 'okay'];

/// 常见 ASR 同音/近音混淆(每组内互相替换算 0 代价)。可通过 opts.homophones 追加。
export const DEFAULT_HOMOPHONES = [
  '助组主住祝注著驻铸', '手首守收受寿兽', '小晓笑校孝', '灵零玲铃凌领令', '炉卢芦鲁路陆露',
  '家佳加嘉夹', '爱艾哎碍', '神深身申', '帮邦', '伴半办扮',
];

const isPunctOrSpace = (ch) => /[\s\p{P}\p{S}]/u.test(ch);

/// 全角 → 半角,字母小写。
function foldChar(ch) {
  const c = ch.codePointAt(0);
  let out = ch;
  if (c >= 0xff01 && c <= 0xff5e) out = String.fromCodePoint(c - 0xfee0);
  else if (c === 0x3000) out = ' ';
  return out.toLowerCase();
}

/// 归一化并保留到原文的下标映射:norm[i] 来自 text[map[i]]。
export function normalizeWithMap(text) {
  const chars = [];
  const map = [];
  let i = 0;
  for (const ch of String(text ?? '')) {
    const f = foldChar(ch);
    if (!isPunctOrSpace(f)) { chars.push(f); map.push(i); }
    i += ch.length;
  }
  return { norm: chars.join(''), map };
}

export const normalizeText = (t) => normalizeWithMap(t).norm;

/// 'a,b、c d' → 去重、归一化后的唤醒词表(名字始终在内)。
export function parseWakeWords(name, wakeWords) {
  // 只按标点分隔:空格属于词内(「hey lares」是一个唤醒词)
  const raw = [name, ...String(wakeWords ?? '').split(/[,，、;；\n]+/u)];
  const out = [];
  for (const w of raw) {
    const n = normalizeText(w ?? '');
    if (n.length >= 2 && !out.includes(n)) out.push(n);
  }
  return out.sort((a, b) => b.length - a.length);
}

function homophoneIndex(groups) {
  const idx = new Map();
  groups.forEach((g, gi) => { for (const ch of g) idx.set(ch, gi); });
  return idx;
}

/// window 与 word 等长:返回替换代价(同音 0,其他 1),超过 limit 提前返回 Infinity。
function substitutionCost(window, word, hidx, limit) {
  let cost = 0;
  for (let i = 0; i < word.length; i++) {
    const a = window[i];
    const b = word[i];
    if (a === b) continue;
    const ga = hidx.get(a);
    if (ga !== undefined && ga === hidx.get(b)) continue;
    cost += 1;
    if (cost > limit) return Infinity;
  }
  return cost;
}

/// 跳过句首语气词,返回在 norm 中的起点。
function skipFillers(norm) {
  let p = 0;
  for (let guard = 0; guard < 4; guard++) {
    const f = FILLERS.find((x) => norm.startsWith(x, p));
    if (!f) break;
    p += f.length;
  }
  return p;
}

const LEAD_TRIM_RE = /^[\s\p{P}\p{S}]+/u;
const TAIL_TRIM_RE = /[\s,，、;；:：]+$/u;
const LEAD_FILLER_RE = new RegExp(`^(?:${FILLERS.filter((f) => !/^[a-z]+$/.test(f)).join('|')})[\\s\\p{P}]*`, 'u');

function stripQuery(text, start, end) {
  const before = text.slice(0, start).replace(TAIL_TRIM_RE, '');
  const after = text.slice(end).replace(LEAD_TRIM_RE, '');
  let q = before.replace(LEAD_TRIM_RE, '');
  // 唤醒词前面只剩语气词 → 丢掉
  if (normalizeText(q) && skipFillers(normalizeText(q)) >= normalizeText(q).length) q = '';
  q = q ? (after ? `${q}，${after}` : q) : after;
  for (let i = 0; i < 3; i++) q = q.replace(LEAD_FILLER_RE, '');
  return q.trim();
}

/**
 * @param {string} text ASR 定稿
 * @param {{name:string, wakeWords?:string, homophones?:string[], leadWindow?:number}} opts
 * @returns {{hit:boolean, query:string, word?:string, fuzzy?:boolean}}
 */
export function detectWake(text, opts) {
  const words = parseWakeWords(opts.name, opts.wakeWords);
  const { norm, map } = normalizeWithMap(text);
  if (!norm || !words.length) return { hit: false, query: '' };
  const toOrig = (ni, nj) => [map[ni], nj < map.length ? map[nj] : String(text).length];
  const origEnd = (nj) => map[nj - 1] + [...String(text).slice(map[nj - 1])][0].length;

  // 1) 任意位置精确命中
  for (const w of words) {
    const at = norm.indexOf(w);
    if (at >= 0) {
      const [s] = toOrig(at, at + w.length);
      return { hit: true, query: stripQuery(String(text), s, origEnd(at + w.length)), word: w, fuzzy: false };
    }
  }
  // 2) 句首区域的模糊命中
  const hidx = homophoneIndex([...DEFAULT_HOMOPHONES, ...(opts.homophones ?? [])]);
  const lead = skipFillers(norm);
  const windowEnd = Math.min(norm.length, lead + (opts.leadWindow ?? 8));
  let best = null;
  for (const w of words) {
    const limit = w.length >= 3 ? 1 : 0;
    for (let p = lead; p + w.length <= windowEnd; p++) {
      const cost = substitutionCost(norm.slice(p, p + w.length), w, hidx, limit);
      if (cost === Infinity) continue;
      // 任意错字时要求首字或末字仍然一致(同音也算),再挡一层误报
      // 并且只在句首(跳过语气词后的第一个位置)才允许;同音(cost 0)在整个句首窗口内都行
      if (cost > 0) {
        if (p !== lead) continue;
        const a0 = substitutionCost(norm[p], w[0], hidx, 0) === 0;
        const a1 = substitutionCost(norm[p + w.length - 1], w[w.length - 1], hidx, 0) === 0;
        if (!(a0 && a1)) continue;
      }
      if (!best || cost < best.cost || (cost === best.cost && p < best.p)) best = { w, p, cost };
    }
  }
  if (best) {
    const [s] = toOrig(best.p, best.p + best.w.length);
    return { hit: true, query: stripQuery(String(text), s, origEnd(best.p + best.w.length)), word: best.w, fuzzy: true };
  }
  return { hit: false, query: '' };
}

/// 文字 ptt:`@AI 问题` / `＠小助手 问题`。返回 {hit, query}。
export function detectPtt(text, opts) {
  const t = String(text ?? '').replace(/^\s+/u, '');
  if (!/^[@＠]/u.test(t)) return { hit: false, query: '' };
  const rest = t.slice(1).replace(/^\s+/u, '');
  const names = ['ai', ...[opts.name, ...String(opts.wakeWords ?? '').split(/[,，、;；\n]+/u)]
    .map((n) => String(n ?? '').trim().toLowerCase()).filter(Boolean)]
    .sort((a, b) => b.length - a.length);
  const low = [...rest].map(foldChar).join('');
  for (const n of names) {
    if (!low.startsWith(n)) continue;
    // 拉丁名后面必须是边界,免得 @AIR 也算
    const next = low[n.length];
    if (/[a-z0-9]$/.test(n) && next && /[a-z0-9]/.test(next)) continue;
    const q = rest.slice(n.length).replace(/^[\s,，:：、]+/u, '').trim();
    return { hit: true, query: q };
  }
  return { hit: false, query: '' };
}
