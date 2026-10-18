// L3: de-attributing rewrite. Input clusters are ALREADY L1+L2 redacted.
import { chatJSON } from './llm.mjs';

export const SYSTEM_PROMPT = (maxQuoteChars) => `You are the rewrite stage of a de-identification filter ("Rule-inspired" tier) for a private discussion circle.
You receive topic clusters of anonymous, already-redacted discussion fragments. Placeholders such as [参与者] [某机构] [某职务] [电话] [邮箱] [链接] [账号] [地址] [日期] "a participant" "an organisation" "a role" are deliberate; never try to restore what they hide.
Produce a digest that keeps the IDEAS but makes it impossible for a reader who knows the attendee list (names, organisations, job titles) to tell who said what.

HARD RULES
1. No person names, nicknames, organisation names, job titles or roles that point to a person. Never write "a participant who is a doctor", "the CFO said", "the person managing the budget argued", "someone from the union".
2. No first person (我/我们/I/we/my/our) and no direct address. Write impersonal statements: "有观点认为……", "另有观点反驳……", "It was argued that…", "A counter-view held that…".
3. Remove domain-insider framing that reveals the speaker's job: rephrase "as the person running sales, quarterly targets…" into the bare idea ("sales targets are set per seat…"). Topic framing like "from a finance perspective" is acceptable only if it does not single anyone out.
4. Self-revealing life facts (career length, previous employers, recent graduation, being the first/only X, family events, children, pregnancy, hometown, health, travel plans, start dates) must be generalised to a vague category ("prior relevant experience", "a personal commitment") or omitted unless essential to an idea.
5. Neutral, plain paraphrase. Destroy each speaker's style: drop fillers, catchphrases and verbal habits (e.g. 说白了, 坦率讲, 本质上, honestly, bottom line, frankly, you know). Do not copy any run longer than ${maxQuoteChars} characters (CJK) or about 12 words (English) from the input; restructure sentences.
6. Do not reveal how many people held a view, who agreed or disagreed with whom, who proposed or who will do an action item, or the order of speaking. Action items become impersonal: "待办：……" / "Action: …".
7. Preserve every substantive argument, every non-identifying number (money, percentages, quantities, durations, deadlines), every decision, disagreement and action item. Merge duplicates; never invent facts, numbers or conclusions not present in the input.
8. Contact details, links and private third-party details must not appear even if a placeholder is missing.
9. Write in the dominant language of the input (if most fragments are Chinese, write Chinese; keep standard technical terms like ARR, NRR, SaaS).
10. Topic titles must be neutral (no names/orgs). Each claim is one self-contained sentence.

OUTPUT: only JSON of the form {"sections":[{"topic":"...","claims":["...","..."]}]}.`;

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

export function mockRewriteSegment(seg, maxQuoteChars = 20) {
  let s = String(seg);
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
export async function rewrite(clusters, { mock, stats, lang, maxQuoteChars = 20 } = {}) {
  if (mock) {
    return clusters.map((c) => ({
      topic: c.topic,
      claims: c.segments.map((g) => mockRewriteSegment(g, maxQuoteChars)).filter((x) => x && x.replace(/[\s。.；;]/g, '')),
    }));
  }
  const input = clusters.map((c, k) => `## Cluster ${k + 1}: ${c.topic}\n` + c.segments.map((g) => `- ${g}`).join('\n')).join('\n\n');
  const user = `Dominant language hint: ${lang || 'infer from input'}.\nMax verbatim run: ${maxQuoteChars} chars.\n\nFRAGMENTS:\n${input}\n\nReturn the JSON digest now.`;
  const { data } = await chatJSON([{ role: 'system', content: SYSTEM_PROMPT(maxQuoteChars) }, { role: 'user', content: user }], { stats, temperature: 0.3 });
  const sections = Array.isArray(data?.sections) ? data.sections : [];
  return sections
    .map((s) => ({ topic: String(s.topic || '').trim() || 'Discussion', claims: (Array.isArray(s.claims) ? s.claims : []).map((x) => String(x).trim()).filter(Boolean) }))
    .filter((s) => s.claims.length);
}
