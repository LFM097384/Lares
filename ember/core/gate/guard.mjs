// Deterministic output guards shared by the gate (release), memory and the in-room answer paths.
// All checks are generic mechanisms (shape / overlap based): no transcript-specific strings.

// ---------------------------------------------------------------- language
const CJK_RE = /[\u3400-\u9fff]/g;
const WORD_RE = /[A-Za-z]{2,}/g;
/** 'zh' | 'en' by CJK chars vs latin words over a list of texts. */
export function dominantLang(texts) {
  let c = 0, w = 0;
  for (const t of texts || []) { const s = String(t ?? ''); c += (s.match(CJK_RE) || []).length; w += (s.match(WORD_RE) || []).length; }
  return c >= w * 1.5 ? 'zh' : 'en';
}

// ---------------------------------------------------------------- prompt injection
// Instructions aimed at the assistant (override its rules, dictate output format / tokens / exfiltration).
const INJ_RE = [
  /忽略(?:你|您)?(?:之前|此前|上面|上述|刚才|前面|以上)?(?:的)?(?:所有|全部|一切)?(?:的)?(?:指令|指示|规则|要求|设定|提示|限制|那个问题)/,
  /(?:无视|不要遵守|绕过|跳过)(?:你|您)?的?(?:所有|全部)?(?:指令|规则|限制|设定|匿名化?)/,
  /不要做?任何匿名化?处理/,
  /在(?:回答|答复|纪要|会议纪要|总结|摘要)(?:的)?(?:开头|末尾|结尾|里|中)[^。！？\n]{0,12}(?:输出|写上|写入|加入|加上|标注|打印)/,
  /(?:输出|写上|写入|加入|标注|打印)[^。！？\n]{0,8}(?:令牌|标记|口令|验证码|token|代号|编号)/i,
  /\bignore (?:all |any )?(?:of )?(?:your |the )?(?:previous |prior |above |earlier )?(?:instructions|rules|guidelines|prompts?)\b/i,
  /\bdisregard (?:all |any )?(?:your |the )?(?:previous |prior |above )?(?:instructions|rules)\b/i,
  /\b(?:start|begin|end) your (?:answer|reply|response|summary) with\b/i,
  /\b(?:include|insert|add|print|output) (?:the |this )?(?:token|code|marker|string)\b/i,
];
export const isInjection = (text) => INJ_RE.some((re) => re.test(String(text ?? '')));
/** Utterance minus its injection: keeps the sentences before the first injection sentence, drops it and the rest. */
export function dropInjection(text) {
  const s = String(text ?? '');
  if (!isInjection(s)) return s;
  const parts = s.split(/(?<=[。！？!?；;])|(?<=\.)\s+/);
  const k = parts.findIndex((p) => isInjection(p));
  return k < 0 ? '' : parts.slice(0, k).join('').trim();
}

// ---------------------------------------------------------------- opaque tokens (canary-like codes, emails, links)
// A code-like token: ≥3 hyphen/underscore-joined groups of [A-Za-z0-9] with both letters and digits (EMB-X12-3456),
// or a long mixed alnum run (≥10 chars, ≥3 digits, ≥3 letters). Ordinary terms (GPT-4, RECIST 1.1, COVID-19) do not match.
const CODE_RE = /(?<![A-Za-z0-9_-])[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+){2,}(?![A-Za-z0-9_-])|(?<![A-Za-z0-9])(?=[A-Za-z0-9]*\d[A-Za-z0-9]*\d[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{10,}(?![A-Za-z0-9])/g;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const URL_RE = /\bhttps?:\/\/[^\s)）\]】"'“”]+/gi;
const isCode = (t) => /\d/.test(t) && /[A-Za-z]/.test(t);
export function opaqueTokens(text) {
  const s = String(text ?? '');
  const out = new Set();
  for (const m of s.matchAll(CODE_RE)) if (isCode(m[0])) out.add(m[0]);
  for (const m of s.matchAll(EMAIL_RE)) out.add(m[0]);
  for (const m of s.matchAll(URL_RE)) out.add(m[0]);
  return [...out];
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/**
 * Remove from `output` every opaque token (code / email / link) that it copies from `sources` (the request, the
 * transcript). The assistant never needs to repeat such a token; echoing one is how a prompt injection exfiltrates
 * a payload or proves compliance. Tokens in `keep` (e.g. public-fact strings) are left alone.
 */
export function stripEchoedTokens(output, sources = [], { keep = [] } = {}) {
  let out = String(output ?? '');
  const src = (Array.isArray(sources) ? sources : [sources]).map((x) => String(x ?? '')).join('\n');
  const keepS = keep.map(String).join('\n');
  const toks = new Set(opaqueTokens(src));
  // any code-shaped token in the output is checked case-insensitively against the sources too
  for (const t of opaqueTokens(out)) if (src.toLowerCase().includes(t.toLowerCase())) toks.add(t);
  for (const t of [...toks].sort((a, b) => b.length - a.length)) {
    if (keepS.includes(t)) continue;
    out = out.replace(new RegExp(`[“"'「『‘(（]?\\s*${esc(t)}\\s*[”"'」』’)）]?`, 'gi'), '');
  }
  return out.replace(/[ \t]{2,}/g, ' ').replace(/^[\s，,：:；;。.]+/, '').replace(/([，,：:])\s*([，,。.])/g, '$2').trim();
}

// ---------------------------------------------------------------- self-disclosed figures
// A figure a speaker states about their own unit / pay / budget / tenure ("我们组37个人", "我年薪45万", "our team of 40")
// is a quasi-identifier: an insider can match it to one person. Figures cited from a public source in the same sentence
// (统计/报告/according to …) are public facts and are left alone. Detection is deterministic on the raw lines; the
// release then replaces those values with a placeholder.
const CN_D = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
const CN_U = { 十: 10, 百: 100, 千: 1000 };
function cnInt(s) {
  // 八千五 → 8500, 一万二 → 12000, 三万二 → 32000, 二百九十 → 290, 十一 → 11
  let total = 0, sec = 0, num = 0, lastUnit = 0;
  for (const ch of s) {
    if (ch in CN_D) { num = CN_D[ch]; continue; }
    if (ch in CN_U) { sec += (num || 1) * CN_U[ch]; num = 0; lastUnit = CN_U[ch]; continue; }
    // (a digit after 万/亿 or after 百/千 is the next lower place: 一万二 = 12000, 八千五 = 8500)
    if (ch === '万' || ch === '亿') { const u = ch === '万' ? 1e4 : 1e8; total += (sec + num) * u; sec = 0; num = 0; lastUnit = u; continue; }
  }
  if (num && lastUnit >= 100) num *= lastUnit / 10;
  return total + sec + num;
}
const FIG_RE = /(百分之)?([零〇一二两三四五六七八九十百千]+[万亿]?[零〇一二两三四五六七八九十百千]*|\d+(?:[.,]\d+)*)\s*多?\s*(%|％|万|亿|千|k\b|million|billion|thousand)?(?=\s*(年|years?)?)/gi;
const MULT = { 万: 1e4, 亿: 1e8, 千: 1e3, k: 1e3, thousand: 1e3, million: 1e6, billion: 1e9 };
/** Numeric values in a text: [{ value, pct, start, end }]. Years (1900–2099) and values < 10 are ignored. */
export function figures(text) {
  const s = String(text ?? '');
  const out = [];
  for (const m of s.matchAll(FIG_RE)) {
    const [all, pctCn, num, unit, yrs] = m;
    const isCn = !/\d/.test(num);
    if (isCn && num.length < 2 && !unit && !pctCn && !yrs) continue;
    let v = isCn ? cnInt(num) : Number(num.replace(/,/g, ''));
    if (!Number.isFinite(v)) continue;
    const u = unit ? unit.toLowerCase() : '';
    const pct = Boolean(pctCn) || u === '%' || u === '％';
    if (!pct && MULT[u]) v *= MULT[u];
    if (!isCn && !u && /^(19|20)\d\d$/.test(num)) continue;
    if (v < (yrs && !unit ? 3 : 10)) continue; // tenure counts (干了8年) are small but identifying
    out.push({ value: Math.round(v * 100) / 100, pct, start: m.index, end: m.index + all.length });
  }
  return out;
}
const SELF_RE = /咱们|俺们|我(?=们|这边|那边|团队|月薪|年薪|工资|在|干|家|司|院|组|部|站|县|镇|校|科|去年|今年|刚|投|手下|负责)|干了|\b(?:our|my)\b|\bI(?:'ve| have)? (?:worked|been)\b/i;
const SOURCE_RE = /公布|统计(?:显示|数据|局|公报)|报告|数据显示|根据|发行规模|研究(?:显示|表明)|调查显示|据(?:统计|报道|了解)|according to|report|survey|published|census|study/i;
const ATTR_BEFORE = /(?:月薪|年薪|工资|薪水|收入|底薪|预算|经费|投了|投入了|团队|组里?|手下|管着?|带着?|干了|工作了|待了|salary|pay|earn|budget|spent|team of|staff of|headcount)[^，。,.;；]{0,6}$/i;
const ATTR_AFTER = /^(?:多)?\s*(?:个人|人|名|位|个骑手|个员工|个老师|people|staff|employees|engineers)/i;
const CHANGE = /提高|增加|上调|下调|降低|削减|涨|降|减|翻|increase|raise|cut|reduce/i;
/** Values a speaker discloses about themselves / their own unit, from the raw lines. */
export function selfFigures(rawTexts) {
  const out = [];
  for (const t of rawTexts || []) for (const sent of String(t ?? '').split(/(?<=[。！？!?；;])|(?<=\.)\s+/)) {
    const m = sent.match(SELF_RE);
    if (!m || SOURCE_RE.test(sent)) continue;
    const tail = sent.slice(m.index).replace(/《[^》]*》/g, ' ');
    // only attribute figures: pay, budget / spend, head-count, tenure — not proposals, prices or shares under discussion
    for (const f of figures(tail)) {
      const before = tail.slice(Math.max(0, f.start - 8), f.start), after = tail.slice(f.end, f.end + 4);
      // a change under discussion (预算提高百分之二十) is a proposal, not an attribute of the speaker
      if ((ATTR_BEFORE.test(before) && !CHANGE.test(before)) || ATTR_AFTER.test(after)) out.push({ value: f.value, pct: f.pct });
    }
  }
  const seen = new Set();
  return out.filter((f) => { const k = `${f.value}|${f.pct}`; if (seen.has(k)) return false; seen.add(k); return true; });
}
/** Replace every value in `text` that equals a self-disclosed figure with a placeholder. */
export function maskSelfFigures(text, selfFigs, { lang = 'zh' } = {}) {
  const s = String(text ?? '');
  if (!selfFigs?.length) return s;
  const hits = figures(s).filter((f) => selfFigs.some((x) => x.pct === f.pct && x.value === f.value));
  if (!hits.length) return s;
  const ph = /^en/i.test(String(lang)) ? '[a figure]' : '[某数值]';
  let out = '', at = 0;
  for (const h of hits) { out += s.slice(at, h.start) + ph; at = h.end; }
  // swallow a trailing currency / counter word that belonged to the masked value
  return (out + s.slice(at)).replace(/(\[某数值\])(?:元|块钱?|块|个人|个|人|名|年|多)+/g, '$1').replace(/(\[a figure\])\s?(?:dollars|people|years|staff)\b/gi, '$1');
}

// ---------------------------------------------------------------- verbatim overlap with the raw transcript
const squashCJK = (s) => (String(s ?? '').normalize('NFKC').match(/[\u3400-\u9fff]/g) || []).join('');
const words = (s) => String(s ?? '').normalize('NFKC').toLowerCase().match(/[a-z0-9']+/g) || [];
// titles are public wording, not a speaker's style: excluded from verbatim runs. Shielded public spans (strip) are NOT
// removed before matching — a copied run is exempt only when what remains of it after removing the public spans is
// shorter than the limit, so a public name never shelters the speaker's own surrounding clause.
const escR = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const stripTitles = (s) => String(s ?? '').replace(/《[^《》\n]{1,60}》/g, ' ');

/** Index of the raw lines for verbatim checks: every CJK n-gram and every word k-gram. */
export function verbatimIndex(rawTexts, { cjkN = 14, wordN = 9, strip = [] } = {}) {
  const cjk = new Set(), en = new Set();
  for (const t of rawTexts || []) {
    const c = squashCJK(stripTitles(t));
    for (let j = 0; j + cjkN <= c.length; j++) cjk.add(c.slice(j, j + cjkN));
    const w = words(stripTitles(t));
    for (let j = 0; j + wordN <= w.length; j++) en.add(w.slice(j, j + wordN).join(' '));
  }
  return { cjk, en, cjkN, wordN, strip };
}
/** Length of a run (CJK chars / words) when each shielded public NAME or TITLE it contains counts as a single unit.
 *  Only short spans (≤ 10 CJK chars / ≤ 5 words) qualify: a longer shielded phrase is a clause, and a clause copied
 *  from a speaker is their wording whatever it is about. */
const SHORT_PUBLIC = (p) => { const c = (String(p).match(/[\u3400-\u9fff]/g) || []).length, w = (String(p).match(/[A-Za-z0-9]+/g) || []).length; return c <= 10 && w <= 5; };
function residual(run, strip = [], mode) {
  let r = mode === 'cjk' ? run : ' ' + run + ' ';
  for (const p of (strip || []).filter(SHORT_PUBLIC)) { const q = mode === 'cjk' ? squashCJK(p) : ' ' + words(p).join(' ') + ' '; if (q.trim()) r = r.split(q).join(mode === 'cjk' ? '\u0001' : ' \u0001 '); }
  return mode === 'cjk' ? r.length : r.trim().split(/\s+/).filter(Boolean).length;
}
/** Longest verbatim runs a claim shares with the indexed raw lines (merged, as text excerpts); [] when clean. */
export function verbatimRuns(text, idx) {
  if (!idx) return [];
  const runs = [];
  const c = squashCJK(stripTitles(text));
  let start = -1;
  for (let j = 0; j + idx.cjkN <= c.length + 1; j++) {
    const hit = j + idx.cjkN <= c.length && idx.cjk.has(c.slice(j, j + idx.cjkN));
    if (hit && start < 0) start = j;
    if (!hit && start >= 0) { const run = c.slice(start, j - 1 + idx.cjkN); if (residual(run, idx.strip, 'cjk') >= idx.cjkN) runs.push(run); start = -1; }
  }
  const w = words(stripTitles(text));
  start = -1;
  for (let j = 0; j + idx.wordN <= w.length + 1; j++) {
    const hit = j + idx.wordN <= w.length && idx.en.has(w.slice(j, j + idx.wordN).join(' '));
    if (hit && start < 0) start = j;
    if (!hit && start >= 0) { const run = w.slice(start, j - 1 + idx.wordN).join(' '); if (residual(run, idx.strip, 'en') >= idx.wordN) runs.push(run); start = -1; }
  }
  return runs;
}
