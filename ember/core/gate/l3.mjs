// L3: de-attributing rewrite. Input clusters are ALREADY L1+L2 redacted.
import { chatJSON } from './llm.mjs';

export const SYSTEM_PROMPT = (maxQuoteChars) => `You are the rewrite stage of a de-identification filter ("Rule-inspired" tier) for a private discussion circle.
You receive topic clusters of anonymous, already-redacted discussion fragments. Placeholders such as [参与者] [某机构] [某职务] [电话] [邮箱] [链接] [账号] [地址] [日期] "a participant" "an organisation" "a role" are deliberate; never try to restore what they hide.
Produce a digest that keeps the IDEAS but makes it impossible for a reader who knows the attendee list (names, organisations, job titles) to tell who said what.

HARD RULES
1. No person names, nicknames, organisation names, job titles or roles that point to a person. Never write "a participant who is a doctor", "the CFO said", "the person managing the budget argued", "someone from the union".
2. No first person (我/我们/I/we/my/our) and no direct address. Write impersonal statements: "有观点认为……", "另有观点反驳……", "It was argued that…", "A counter-view held that…".
3. Remove domain-insider framing that reveals the speaker's job: rephrase "as the person running sales, quarterly targets…" into the bare idea ("sales targets are set per seat…"). Topic framing like "from a finance perspective" is acceptable only if it does not single anyone out. Institutional position cues also reveal the speaker's employer: reporting lines ("向省发改委汇报", "I'll take this to the Dean"), "不代表市里/本单位正式立场", "our department's budget", offers to pay / sign / fund on behalf of an organisation, and short-form references to a unit that is evidently the speaker's own ("funded by the Centre", "平台这边可以给流量", "我们社" → "funded centrally", "可由分发渠道提供流量", "出版方"). Generalise them ("需与上级口径对齐", "讨论内容不代表任何机构的正式立场", "one view offered to pre-fund the pilot if a five-year operating agreement were signed").
4. Self-revealing life facts (career length, previous employers, recent graduation, being the first/only X, family events, children, pregnancy, hometown, health, travel plans, start dates) must be generalised to a vague category ("prior relevant experience", "a personal commitment") or omitted unless essential to an idea.
5. Neutral, plain paraphrase. Destroy each speaker's style: drop fillers, catchphrases and verbal habits (e.g. 说白了, 坦率讲, 本质上, honestly, bottom line, frankly, you know). Do not copy any run longer than ${maxQuoteChars} characters (CJK) or about 12 words (English) from the input; restructure sentences.
6. Do not reveal how many people held a view, who agreed or disagreed with whom, who proposed or who will do an action item, or the order of speaking. Action items become impersonal: "待办：……" / "Action: …".
7. Preserve every substantive argument, every non-identifying number (money, percentages, quantities, durations, deadlines), every decision, disagreement and action item. Merge duplicates; never invent facts, numbers or conclusions not present in the input.
8. Contact details, links and private third-party details must not appear even if a placeholder is missing.
9. Write in the dominant language of the input (if most fragments are Chinese, write Chinese; keep standard technical terms like ARR, NRR, SaaS).
10. Topic titles must be neutral (no names/orgs). Each claim is one self-contained sentence.
11. PUBLIC FACTS. World knowledge is not identifying and must be kept with its names and titles intact: published works and their authors (e.g. 《三体》是刘慈欣写的, Orwell's essay), public figures' public acts and statements, public institutions' public policies and reports (世界银行的公开报告, WTO rules), laws, regulations and official documents. Never generalise them ("《三体》" must NOT become "某作品", "刘慈欣" must NOT become "某作者"). Exceptions: if a placeholder already hides it ([某作品] [某机构] [参与者] …) keep the placeholder; if the text says the speaker wrote/owns/works at it (my book, 我那本书, 我们XX), it is participant identity: generalise it ("一部作品", "某机构"). Keep public names EXACTLY as written in the input, in their original language and form: do not translate them and do not expand or abbreviate them ("World Health Organization" stays "World Health Organization" even in a Chinese digest, "EU AI Act" stays "EU AI Act", "住建部" stays "住建部"); you may add a translation in parentheses after the original, e.g. "Alternative Fuels Infrastructure Regulation（欧盟替代燃料基础设施条例）". Mark kept world-knowledge claims with flag "public-fact".
12. TONE. Sarcasm, 阴阳怪气, irony, backhanded praise (明褒实贬), rhetorical questions, mock enthusiasm, catchphrases, dialect / 方言腔 (粤语, 东北话 …) and signature rhetoric identify speakers. Rewrite every such fragment as a neutral propositional statement that keeps the stance DIRECTION (support / doubt / oppose) and STRENGTH (mild / clear / strong) — e.g. 「真是好方案，再拍脑袋几次公司就上市了」→「有观点对该方案的决策依据表示明显怀疑」; "Oh brilliant, another committee" → "One view strongly doubted the value of another committee". Never quote, echo or paraphrase-with-the-same-image the sarcastic phrase. Mark such claims with flag "tone-neutralised".
   Stance vocabulary — pick the verb by what the speaker DOES, not by how sarcastic it sounds:
   - oppose = rejects or argues against the target (says it is wrong, unnecessary, unfair, unworkable, harmful, too low/high): write 「有观点反对……」「有观点认为……不合理/不可行/没有必要」, "One view opposed …", "It was argued that … is unnecessary / unfair / unworkable".
   - doubt = questions whether it will work or is true, is sceptical but does not reject it outright: 「有观点质疑……能否……」「对……表示怀疑」, "One view doubted whether …".
   - support = agrees / endorses.
   Strength: 1 = mild (gentle aside, light irony, "I'd just note"), 2 = clear (ordinary sarcasm, a pointed objection), 3 = strong (emphatic, repeated, contemptuous). Do not inflate: a single ironic aside is mild or clear, not strong. Express strength with plain intensity words (略有/明确/强烈; mildly/clearly/strongly).
   Keep the stance and its stated reasons and numbers TOGETHER in the same claim: 「有观点明确反对"普通读者不挑翻译"的说法，理由是去年有机翻版因质量差在豆瓣仅得2.9分」 — not a bare "某人表示怀疑" line with the reason in a different claim. A neutralised claim must still name its target (what is opposed/doubted) concretely.
13. Classify each claim: "decision" (agreed / decided / resolved), "todo" (action item), "fact" (public world fact, number or external information), else "idea".

OUTPUT: only JSON of the form {"sections":[{"topic":"...","claims":[{"text":"...","kind":"idea|decision|todo|fact","flags":["public-fact"|"tone-neutralised"]}]}]}.`;

// ---------- mock (deterministic, offline) ----------
// Mock cannot truly paraphrase: it only rule-rewrites pronouns, strips tics and chops long runs.
const TICS_ZH = ['说白了', '坦率讲', '坦白说', '我插一句', '你知道吧', '讲真', '其实吧', '本质上'];
const TICS_EN = ['frankly speaking', 'frankly', 'you know', 'basically', 'bottom line', 'honestly', 'to be fair', 'i mean', 'like'];
const QUASI = [
  [/(刚从[^，。,.;；]{0,20}毕业|刚刚?毕业|[^，。,.;；]{0,10}博士答辩[^，。,.;；]{0,10})/g, '近期完成了学业'],
  [/(第一个女[\u4e00-\u9fa5]{1,6}|唯一一个[\u4e00-\u9fa5]{1,8}|第一位女[\u4e00-\u9fa5]{1,6})/g, '具有少见的经历'],
  [/[^，。,.;；!?！？]*(孩子|双胞胎|老婆|老公|怀孕|陪产假|产假|女儿|儿子)[^，。,.;；!?！？]*/g, '提及家庭情况'],
  [/(?:I|a participant) (?:covered|reported on|worked on) [^,.;]{1,40} for (?:\d+|\w+) years/gi, 'a participant has prior relevant experience'],
  [/(?:I|a participant) (?:spent|worked) (?:\d+|\w+) years (?:at|in|with) [^,.;]{1,40}/gi, 'a participant has prior relevant experience'],
  [/\b(?:my|their) (?:kids?|children|twins|wife|husband|pregnan\w*)[^,.;]*/gi, 'mentions family circumstances'],
  [/(我|一位参与者)?老家在[\u4e00-\u9fa5A-Za-z]{1,10}/g, '提及家乡'],
  [/(我|一位参与者)?(做了|干了)[一二三四五六七八九十\d]+年[\u4e00-\u9fa5]{0,8}/g, '有相关从业经历'],
];
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Sarcasm markers / dialect particles stripped by the mock (the LLM path rewrites them properly).
export const TONE_MARKERS_ZH = ['呵呵', '可真行', '真是厉害了', '真是厉害', '可真是', '佩服佩服', '勇气可嘉', '真是高明', '咋整', '嘛呢', '可不咋的', '老鼻子', '整明白', '瞅瞅', '大伙儿', '俺们', '俺', '侬', '阿拉', '唔系', '冇', '咗', '嘅', '我哋', '佢', '细个', '喺'];
export const TONE_MARKERS_EN = ['oh brilliant', 'oh great', 'splendid', 'marvellous', 'wonderful', 'what a joy', 'yeah right'];
const TONE_ZH_SRC = TONE_MARKERS_ZH.map(esc).join('|');
const TONE_EN_SRC = `(^|[\\s,.;!?])(?:${TONE_MARKERS_EN.map(esc).join('|')})(?=[\\s,.;!?]|$)`;

export function hasToneMarker(s) {
  const t = String(s);
  return new RegExp(TONE_ZH_SRC).test(t) || new RegExp(TONE_EN_SRC, 'i').test(t);
}

// Heuristic kind (used by the mock and as fallback when the LLM omits / garbles it).
export function claimKind(text, flags = []) {
  const s = String(text);
  if (/^\s*(?:待办|Action\b|TODO\b)|待办[：:]/i.test(s)) return 'todo';
  if (/决定|决议|议定|一致同意|\bagreed\b|\bdecided\b|\bresolved\b|\bdecision/i.test(s)) return 'decision';
  if (flags.includes('public-fact')) return 'fact';
  return 'idea';
}

export function mockRewriteSegment(seg, maxQuoteChars = 20) {
  let s = String(seg);
  s = s.replace(new RegExp(TONE_ZH_SRC, 'g'), '').replace(new RegExp(`${TONE_EN_SRC}[,!.]?`, 'gi'), '$1');
  for (const t of TICS_ZH) s = s.split(t).join('');
  s = s.replace(/[，,]?\s*(哈|嘛|呢)(?=[，。！？,.!?\s]|$)/g, '');
  for (const t of TICS_EN) s = s.replace(new RegExp(`(^|[\\s,.;])${esc(t)}(?=[\\s,.;!?]|$)[,]?`, 'gi'), '$1');
  // first person -> third
  s = s.replace(/我们/g, '与会方').replace(/咱们/g, '与会方').replace(/我/g, '一位参与者');
  s = s.replace(/\bI'm\b/g, 'a participant is').replace(/\bI've\b/g, 'a participant has').replace(/\bI'd\b/g, 'a participant would')
    .replace(/\bI'll\b/g, 'a participant will').replace(/\bI\b/g, 'a participant').replace(/\bme\b/gi, 'a participant')
    .replace(/\b(my|our)\b/gi, 'their').replace(/\bwe\b/gi, 'participants').replace(/\bus\b/gi, 'participants');
  for (const [re, rep] of QUASI) s = s.replace(re, rep);
  s = s.replace(/\s{2,}/g, ' ').replace(/^[\s，,。.;；]+/, '').replace(/([，,])\s*[，,]+/g, '$1').replace(/\s*,\s*([.!?])/g, '$1').replace(/^a participant/, 'A participant').trim();
  return chop(s, maxQuoteChars);
}

const cjkLen = (s) => (s.match(/[\u3400-\u9fff]/g) || []).length;
const enWords = (s) => (s.match(/[A-Za-z0-9'’-]+/g) || []).length;
const tooLong = (s, n) => cjkLen(s) > n || enWords(s) > 12;

// Split at punctuation; hard-cut any clause still too long; rejoin with "；" so no source run is copied whole.
function chop(s, n) {
  if (!tooLong(s, n)) return s;
  const parts = s.split(/(?<=[，。；！？、,.;!?:：—])\s*/).map((p) => p.trim()).filter(Boolean);
  const out = [];
  for (let p of parts) {
    p = p.replace(/[，。；！？、,.;!?:：—]+$/, '');
    while (tooLong(p, n)) {
      if (cjkLen(p) > n) { const half = Math.ceil(p.length / 2); out.push(p.slice(0, half)); p = p.slice(half); }
      else { const w = p.split(/\s+/); out.push(w.slice(0, 10).join(' ')); p = w.slice(10).join(' '); }
    }
    if (p) out.push(p);
  }
  const isZh = cjkLen(s) >= enWords(s);
  return out.join(isZh ? '；' : '; ') + (isZh ? '。' : '.');
}

// ---------- entry ----------
const KINDS = new Set(['idea', 'decision', 'todo', 'fact']);
const FLAGS = new Set(['public-fact', 'tone-neutralised']);

// Normalises an LLM claim (object or legacy string) into { text, kind, flags[] }.
export function normClaim(x) {
  if (x == null) return null;
  const o = typeof x === 'string' ? { text: x } : x;
  const text = String(o.text ?? '').trim();
  if (!text) return null;
  const flags = [...new Set((Array.isArray(o.flags) ? o.flags : []).map(String).filter((f) => FLAGS.has(f)))];
  const kind = KINDS.has(o.kind) ? o.kind : claimKind(text, flags);
  return { text, kind, flags };
}

// rewrite(clusters, { llm, stats, lang, maxQuoteChars }) -> [{ topic, claims:[{ text, kind, flags[] }] }]
// llm == null → deterministic mock.
export async function rewrite(clusters, { llm = null, stats, lang, maxQuoteChars = 20 } = {}) {
  if (!llm) {
    return clusters.map((c) => ({
      topic: c.topic,
      claims: c.segments.map((g) => {
        const tone = hasToneMarker(g);
        const text = mockRewriteSegment(g, maxQuoteChars);
        if (!text || !text.replace(/[\s。.；;]/g, '')) return null;
        const flags = tone ? ['tone-neutralised'] : [];
        return { text, kind: claimKind(text, flags), flags };
      }).filter(Boolean),
    }));
  }
  const input = clusters.map((c, k) => `## Cluster ${k + 1}: ${c.topic}\n` + c.segments.map((g) => `- ${g}`).join('\n')).join('\n\n');
  const user = `Dominant language hint: ${lang || 'infer from input'}.\nMax verbatim run: ${maxQuoteChars} chars.\n\nFRAGMENTS:\n${input}\n\nReturn the JSON digest now.`;
  const { data } = await chatJSON(llm, [{ role: 'system', content: SYSTEM_PROMPT(maxQuoteChars) }, { role: 'user', content: user }], { stats, temperature: 0.3 });
  const sections = Array.isArray(data?.sections) ? data.sections : [];
  return sections
    .map((s) => ({ topic: String(s.topic || '').trim() || 'Discussion', claims: (Array.isArray(s.claims) ? s.claims : []).map(normClaim).filter(Boolean) }))
    .filter((s) => s.claims.length);
}
