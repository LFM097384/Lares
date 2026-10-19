// L2 affiliation: roster orgs/titles (+fragments), a built-in org/title dictionary,
// and self-affiliation heuristics ("我们部门", "我在X的时候", "as head of X at Y").
//
// Gate v2 "public facts" (opts.allowPublicFacts, default true; false = prototype behaviour, where every
// KNOWN_ORGS hit is redacted):
// Test applied to every generic public entity: CAN IT POINT BACK TO A PARTICIPANT OR THEIR ORG?
//  ALWAYS redacted (participant identity):
//   - roster org + fragments (orgFragments), roster titles, roster `works[]` (with/without 《》) and `publicName`;
//   - a KNOWN_ORGS entry that is contained in a roster org string, or whose abbreviation group
//     (ORG_GROUPS: 清华大学/清华, 中国人民大学/人民大学/人大 …) has a member contained in a roster org;
//   - a KNOWN_ORGS hit in self-affiliation context: 我/我们/咱们/本人 earlier in the SAME clause (≤14 chars,
//     no ，。；！？ in between) with only time adverbs / affiliation verbs between
//     (我们世界银行, 我在清华, 我上个月刚从MD安德森…, 我是从香港中文大学…), English "I worked at / we at / our";
//     plus the prototype SELF regexes (作为X, 我在X的时候, 我们XX部门, as head of…, when I was at…);
//   - a 《title》 (or an English quoted title) in self-reference context: 我那本书/我的书/我写的/我出的/拙作/
//     《X》是我写的 / my book / I wrote / my paper … → [某作品] / "a work".
//  KEPT (world knowledge): other KNOWN_ORGS hits (世界银行的公开报告, CBAM在WTO框架下), 《三体》and other
//   titles, laws/policies (《劳动合同法》), public figures (handled in L1).
// Known gaps / tradeoffs:
//   - "我觉得世界银行…" is kept (opinion verb ≠ affiliation) but "我在读世界银行的报告" is redacted (在 looks
//     like affiliation) — over-redaction is the safe direction.
//   - Self-affiliation stated in a different clause ("世界银行那几年，我…", "我之前，就是在WB") is missed → L3/L4.
//   - A public org mentioned by a participant who works there but whose roster `org` names it differently
//     (e.g. roster "WB" vs text "世界银行") is only caught via ORG_GROUPS; roster orgs should use the full name.
//   - Titles that are not in 《》/quotes ("my book on rural schools") are not detectable as works → L3/L4.
import { localLang } from './l1.mjs';

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const isCJK = (s) => /[\u3400-\u9fff]/.test(s);

export const KNOWN_ORGS = [
  // CN tech / industry
  '腾讯', '阿里巴巴', '阿里云', '阿里', '字节跳动', '字节', '抖音', '百度', '华为', '小米', '京东物流', '京东', '美团外卖', '美团', '饿了么', '拼多多', '滴滴', '快手', '网易', '蚂蚁集团', '蚂蚁金服', '顺丰', '中通', '圆通', '菜鸟', '富士康', '比亚迪', '宁德时代', '蔚来', '小鹏', '理想汽车', '大疆', '中兴', '联想', '用友', '金蝶', '商汤', '科大讯飞', '月之暗面', '智谱', '深度求索', 'DeepSeek', '国家电网', '南方电网', '中石油', '中石化', '中国移动', '中国联通', '中国电信', '宝武', '宝钢', '鞍钢', '首钢', '河钢', '中国钢铁工业协会', '钢协', '高榕', '红杉', '高瓴', 'IDG', '经纬',
  // CN gov / universities / hospitals / media
  '发改委', '商务部', '外交部', '财政部', '工信部', '生态环境部', '人社部', '卫健委', '教育部', '教育局', '海关总署', '条法司', '国务院', '人大', '政协', '社科院', '中科院', '工程院', '清华大学', '清华', '北京大学', '北大', '复旦大学', '复旦', '上海交通大学', '上海交大', '交大', '浙江大学', '浙大', '中国人民大学', '人民大学', '人大', '南京大学', '武汉大学', '中山大学', '香港大学', '港大', '香港中文大学', '港中文', '协和医院', '协和', '华西医院', '华西', '瑞金医院', '瑞金', '湘雅', '301医院', '北医三院', '中日友好医院', '中日医院', '肿瘤医院', '新华社', '人民日报', '央视', '财新', '澎湃', '南方周末', '第一财经', '界面新闻',
  // Global
  'OpenAI', 'DeepMind', 'Google', 'Microsoft', 'Meta', 'Apple', 'Amazon', 'Anthropic', 'NVIDIA', 'Nvidia', 'Tesla', 'CATL', 'Foxconn', 'Mila', 'MIT', 'Stanford', 'Harvard', 'Oxford', 'Cambridge', 'Yale', 'Princeton', 'Berkeley', 'Columbia', 'ETH', 'EPFL', 'Edinburgh', 'MD Anderson', 'MD安德森', 'Mayo Clinic', 'Johns Hopkins', 'Reuters', 'Bloomberg', 'Financial Times', 'FT', 'New York Times', 'NYT', 'Wall Street Journal', 'WSJ', 'BBC', 'CNN', 'Caixin', 'Economist', 'Oxfam', 'UNICEF', 'UNDP', 'World Bank', '世界银行', 'IMF', 'WTO', 'WHO', 'Gates Foundation', 'Ford Foundation', 'Red Cross', '红十字会', 'Greenpeace', '绿色和平', 'Amnesty', 'McKinsey', '麦肯锡', 'BCG', 'Bain', 'Deloitte', 'PwC', 'KPMG', 'EY', 'Goldman Sachs', '高盛', 'Morgan Stanley', '摩根士丹利', 'JPMorgan', 'HSBC', '汇丰', 'Takata', 'DG TAXUD', 'TAXUD', 'European Commission', '欧盟委员会', 'FCDO', 'British Embassy', '英国使馆', '英国驻华使馆', 'Universidad de los Andes', 'Teachers College', '哥伦比亚', '鲁汶大学', '鲁汶', 'KU Leuven', '哈佛', '斯坦福', '牛津', '剑桥', '耶鲁', '麻省理工',
];

export const KNOWN_TITLES = [
  'CEO', 'CFO', 'CTO', 'COO', 'CPO', 'CMO', 'VP', 'SVP', 'EVP', '创始人兼CEO', '创始人', '联合创始人', '董事长', '董事会观察员', '董事', '总裁', '副总裁', '总经理', '副总经理', '销售副总裁', '总监', '项目总监', '财务总监', '经理', '主任医师', '副主任医师', '主治医师', '住院医师', '住院医', '护士长', '科主任', '放疗科副主任', '副主任', '主任', '博导', '副教授', '教授', '讲师', '高级研究员', '研究员', '副研究员', '所长', '副所长', '院长', '副院长', '秘书长', '副秘书长', '理事长', '副理事长', '理事', '主席', '书记', '组长', '拣货组长', '站长', '队长', '骑手队长', '召集人', '项目主任', '合伙人', '劳动法合伙人', '律师', '一等秘书', '二等秘书', '参赞', '大使', '司长', '处长', '局长', '科长', '首席', '高级工程师', '工程师', '记者', '编辑', '主编', '首席记者', '访问学者', '博士后', '博士生', '博士研究生', '硕士生',
  'Chief Executive', 'Managing Director', 'Director', 'Deputy Director', 'Centre Director', 'Center Director', 'Program Officer', 'Programme Officer', 'Senior Fellow', 'Fellow', 'Partner', 'Media Law Partner', 'Associate Professor', 'Assistant Professor', 'Professor', 'Lecturer', 'PhD Candidate', 'PhD Student', 'PhD student', 'Postdoc', 'Research Scientist', 'Staff Research Scientist', 'Senior Research Scientist', 'Engineer', 'Senior Engineer', 'Editor', 'Business Editor', 'Senior Investigative Reporter', 'Investigative Reporter', 'Reporter', 'Correspondent', 'Bureau Chief', 'Fact-Check Lead', 'First Secretary', 'Counsel', 'Outside Counsel', 'General Counsel', 'Board Observer', 'Chair', 'Chairman', 'Chairwoman', 'Treasurer', 'Secretary-General',
];

const ORG_SUFFIX = /(大学|学院|医院|研究院|研究所|研究中心|中心|公司|集团|协会|基金会|事务所|科技|科室|部|所|处|司|局|委员会|服务中心|互助会|（筹）|\(筹\))$/;
const GENERIC = new Set(['中国', '北京', '上海', '深圳', '广州', '国际', '研究', '中心', '大学', '学院', '医院', '公司', '集团', '协会', '科技', '服务', '项目', '财务', '财务部', '项目部', '研究部', '基金会', '乡村', '教育', '新能源', '科学', '医学', '附属', '首都', '国家', '经济', '贸易', '合作', '政策', '气候', '环境', '管理', '公共', '工业', '劳工', '外卖', '物流', '律师', '事务所', '肿瘤', '放射', '诊断', '骑手', '互助会', '深圳骑手', '欧洲', '研究所', '数栈', '龙华']);
const EN_GENERIC = new Set(['The', 'Centre', 'Center', 'Institute', 'University', 'College', 'School', 'Foundation', 'Trust', 'Family', 'Inc', 'Ltd', 'LLP', 'LLC', 'Group', 'Labs', 'Lab', 'AI', 'Power', 'Wire', 'Desk', 'Research', 'Language', 'Evaluation', 'Machine', 'Learning', 'Development', 'Rural', 'Pacific', 'Asia', 'for', 'of', 'and', 'Program', 'Hospital', 'Bureau', 'News', 'Media', 'Global', 'International', 'Partners', 'Capital', 'Ventures', 'Harbor', 'Fund', 'Data', 'Systems', 'Technologies', 'Technology', 'Department', 'English', 'Comparative', 'Literature', 'History', 'Studies', 'Science', 'Sciences', 'Arts', 'Humanities', 'Teaching', 'Law', 'Economics', 'Politics', 'Policy', 'Public', 'Urban', 'Energy', 'Transition', 'Health', 'Medicine', 'Education', 'Social', 'Business', 'Management', 'Engineering', 'Computer', 'Mathematics', 'Physics', 'Chemistry', 'Biology', 'Philosophy', 'Languages', 'Modern', 'National', 'Royal', 'City', 'State', 'New', 'North', 'South', 'East', 'West', 'Central']);

export function orgFragments(org) {
  const out = new Set();
  const s = String(org || '').trim();
  if (!s) return out;
  out.add(s);
  for (const piece of s.split(/[\s()（）/,，、]+/).filter(Boolean)) {
    if (isCJK(piece)) {
      let p = piece; out.add(p);
      // strip suffixes repeatedly: 春晖乡村教育基金会财务部 → 春晖乡村教育基金会 → 春晖乡村教育
      for (let k = 0; k < 3; k++) { const q = p.replace(ORG_SUFFIX, ''); if (q === p || q.length < 2) break; p = q; out.add(p); }
      // split around known boundaries: 中国医学科学院肿瘤医院胸外科 → 中国医学科学院 / 肿瘤医院 / 胸外科
      for (const m of piece.matchAll(/[\u4e00-\u9fff]{2,}?(?:大学|学院|医院|研究院|研究所|基金会|协会|事务所|公司|中心|使馆|站|仓|科|部|处)/g)) out.add(m[0]);
      // leading distinctive 2–4 char brand: 极光数栈科技 → 极光数栈, 极光
      const brand = piece.replace(/^(中国|北京|上海|深圳|广州|首都)/, '').match(/^[\u4e00-\u9fff]{2,4}/);
      if (brand) { out.add(brand[0]); out.add(brand[0].slice(0, 2)); }
    } else {
      if (/^[A-Z&]{2,6}$/.test(piece) && piece !== 'AI' && piece !== 'LLP') out.add(piece); // acronyms
      else if (/^[A-Z][\p{L}'-]{2,}$/u.test(piece) && !EN_GENERIC.has(piece)) out.add(piece);
    }
  }
  // English multi-word org: also the org minus generic tail ("Meridian AI Labs" → "Meridian")
  const en = s.match(/[A-Z][\p{L}'-]+(?:\s+(?:&\s+)?[A-Z][\p{L}'-]+)+/gu) || [];
  for (const e of en) out.add(e);
  // comma-separated sub-units ("Halden University, Centre for Teaching and Learning")
  for (const part of s.split(/\s*[,，;；]\s*/)) if (part.length >= 8 && part !== s) out.add(part.replace(/^the\s+/i, ''));
  for (const f of [...out]) if (GENERIC.has(f) || f.length < 2) out.delete(f);
  return out;
}

// Abbreviation / alias groups among KNOWN_ORGS: if one member is the participant's org, all are.
export const ORG_GROUPS = [
  ['清华大学', '清华'], ['北京大学', '北大', '北医三院'], ['复旦大学', '复旦'], ['上海交通大学', '上海交大', '交大'], ['浙江大学', '浙大'],
  ['中国人民大学', '人民大学', '人大'], ['香港大学', '港大'], ['香港中文大学', '港中文'], ['协和医院', '协和'], ['华西医院', '华西'], ['瑞金医院', '瑞金'],
  ['中日友好医院', '中日医院'], ['阿里巴巴', '阿里云', '阿里', '蚂蚁集团', '蚂蚁金服'], ['字节跳动', '字节', '抖音'], ['京东物流', '京东'], ['美团外卖', '美团'],
  ['中国钢铁工业协会', '钢协'], ['宝武', '宝钢'], ['DG TAXUD', 'TAXUD', 'European Commission', '欧盟委员会'], ['British Embassy', '英国使馆', '英国驻华使馆', 'FCDO'],
  ['World Bank', '世界银行'], ['Greenpeace', '绿色和平'], ['Red Cross', '红十字会'], ['McKinsey', '麦肯锡'], ['Goldman Sachs', '高盛'], ['Morgan Stanley', '摩根士丹利'],
  ['HSBC', '汇丰'], ['MD Anderson', 'MD安德森'], ['Foxconn', '富士康'], ['CATL', '宁德时代'], ['Harvard', '哈佛'], ['Stanford', '斯坦福'], ['Oxford', '牛津'],
  ['Cambridge', '剑桥'], ['Yale', '耶鲁'], ['MIT', '麻省理工'], ['Columbia', '哥伦比亚', 'Teachers College'], ['KU Leuven', '鲁汶大学', '鲁汶'],
  ['Financial Times', 'FT'], ['New York Times', 'NYT'], ['Wall Street Journal', 'WSJ'], ['Caixin', '财新'], ['DeepSeek', '深度求索'], ['NVIDIA', 'Nvidia'],
];

const cache = new WeakMap();
function dicts(roster = []) {
  if (cache.has(roster)) return cache.get(roster);
  const orgs = new Set(), titles = new Set(KNOWN_TITLES), works = new Set();
  const rosterOrgs = roster.map((p) => String(p.org || '')).filter(Boolean);
  const inRoster = (k) => rosterOrgs.some((o) => (isCJK(k) ? o.includes(k) : new RegExp(`(?<![A-Za-z0-9])${esc(k)}(?![A-Za-z0-9])`).test(o)));
  const owned = new Set(KNOWN_ORGS.filter(inRoster));
  for (const g of ORG_GROUPS) if (g.some((k) => owned.has(k) || inRoster(k))) for (const k of g) owned.add(k);
  for (const k of owned) orgs.add(k);
  const pub = new Set(KNOWN_ORGS.filter((k) => !owned.has(k)));
  for (const p of roster) {
    for (const w of p.works || []) {
      const s = String(w).trim(); if (!s) continue;
      works.add(s);
      const inner = s.replace(/^[《「『"“'‘]|[》」』"”'’]$/g, '').trim();
      if (inner.length >= 2) { works.add(`《${inner}》`); works.add(inner); }
    }
    if (p.publicName && String(p.publicName).trim().length >= 2) orgs.add(String(p.publicName).trim()); // pen name etc.
    for (const f of orgFragments(p.org)) orgs.add(f);
    if (p.title) {
      const t = String(p.title).trim();
      titles.add(t);
      for (const part of t.split(/\s*[\/／,，、（）()]\s*|兼/).filter((x) => x.trim().length >= 2)) titles.add(part.trim());
      const core = t.replace(/^(Senior|Staff|Principal|Lead|Deputy|Associate|Assistant|高级|资深|首席|副)\s*/i, '').split(/[,，]/)[0].trim();
      if (core.length >= 2) titles.add(core);
    }
  }
  const mk = (set) => {
    const cj = [...set].filter(isCJK).sort((a, b) => b.length - a.length).map(esc);
    const as = [...set].filter((x) => !isCJK(x)).sort((a, b) => b.length - a.length).map(esc);
    return [cj.length ? new RegExp(cj.join('|'), 'g') : null, as.length ? new RegExp(`(?<![A-Za-z0-9À-ÿ])(?:${as.join('|')})(?![A-Za-z0-9À-ÿ])`, 'g') : null].filter(Boolean);
  };
  for (const k of pub) if (orgs.has(k)) pub.delete(k);
  const d = { org: mk(orgs), title: mk(titles), pub: mk(pub), work: mk(works), pubAll: mk(new Set(KNOWN_ORGS)) };
  cache.set(roster, d);
  return d;
}

// Self-affiliation context immediately before a public-org mention (same clause).
const ZH_FILL = '(?:部门|团队|单位|公司|科室|课题组|组里|这边的人|[0-9一二三四五六七八九十]+年|[0-9]+月|上个月|上周|去年|前年|今年|当年|那年|以前|之前|过去|曾经|曾|刚刚|刚|才|也|还|都|一直|早年|原来|本来|毕业于|就是|是|从|在|去过|去|进了|进|回到|回|来自|离开了|离开|加入了|加入|待过|待|调到|调|结束|读完|读过|访问|进修|实习|任职于|供职于|就职于|工作于|这边|那边|的)';
// subject + ≤5 time-adverb / affiliation-verb tokens, ending right before the org: 我们 / 我在 / 我上个月刚从 / 我是从
const SELF_BEFORE_ZH = new RegExp(`(?:我们|咱们|本人|我)${ZH_FILL}{0,5}$`);
// subject-dropped clause start: "，之前在条法司…" / "以前在X"
const DROPPED_SUBJ_ZH = /^(?:之前|以前|曾经|曾|过去|早年|原来|当年)(?:一直)?(?:在|于|是)$/;
const SELF_BEFORE_EN = /(?:\b(?:I|we)\s+(?:was|were|am|are|have been|had been)?\s*(?:still\s+|once\s+|previously\s+)?(?:work(?:ed|ing)?|used to work|spent \S+ years|joined|left|studied|trained|interned|was based|am based)?\s*(?:at|for|in|with|from)\s+|\bwe\s+at\s+|\b(?:my|our)\s+(?:[\w'’-]+\s+){0,2}(?:at|in|from|with)\s+|\b(?:my|our)\s+)$/i;
function selfContextBefore(text, start) {
  const clauseZh = text.slice(Math.max(0, start - 30), start).split(/[，。；！？,;!?\n]/).pop().replace(/\s+/g, '');
  const tail = clauseZh.slice(-14);
  if (tail && (SELF_BEFORE_ZH.test(tail) || DROPPED_SUBJ_ZH.test(clauseZh))) return true;
  const clauseEn = text.slice(Math.max(0, start - 60), start).split(/[.;!?\n。；！？]/).pop();
  return SELF_BEFORE_EN.test(clauseEn);
}

// Self-referential works: 我那本书《X》, 我写的《X》, 拙作《X》, 《X》是我写的, my book "X", I wrote "X".
const WORK_SELF_BEFORE = /(?:我|本人|我们|咱们)(?:那|这|的|新出的|去年出的|写的|写过的|出的|编的|主编的|翻译的|拍的|发表的|出版的)?(?:那|这)?(?:一|两|几)?(?:本|篇|部|首|份)?(?:书|新书|小说|专著|著作|论文|文章|报告|作品|诗集|电影|纪录片|剧本)?(?:叫|叫做|名叫|是|，|,)?\s*$|拙作\s*$|(?:\bmy|\bour)\s+(?:new\s+|latest\s+|first\s+|last\s+)?(?:book|novel|paper|report|memoir|film|documentary|essay|article)\s*,?\s*(?:called\s+|titled\s+)?$|\bI\s+(?:wrote|published|co-?authored|authored|directed|edited)\s*$/i;
const WORK_SELF_AFTER = /^(?:就|正|也)?是(?:我|本人|我们)(?:写|编|出|翻译|拍|主编|合写|执笔)|^(?:,\s*)?(?:which|that)\s+I\s+(?:wrote|published|authored|co-?authored)/i;
const TITLE_RE = /《[^《》\n]{1,60}》|[“"‘'][A-Z][^“”"‘’'\n]{1,80}[”"’']/g;
const WORK_PH = { zh: '[某作品]', en: 'a work' };


// Self-affiliation patterns (applied first, they consume context words around the org).
const SELF = [
  // 我作为X的Y / 作为X  → 以其职务身份
  ['self', /(?:我|本人)?作为[^，。,；;！？]{1,24}?(?=[，,。；;]|$|我|，)/g, { zh: '以其身份' }],
  ['self', /我(?:以前|之前|曾经|当年)?在[^，。,；;！？]{1,20}?(?:的时候|这些年|那些年|工作|上班|当了?[^，。,；;]{0,10}|带[^，。,；;]{0,8}|干了?[^，。,；;]{0,10}|分管[^，。,；;]{0,10}|负责[^，。,；;]{0,10}|主管[^，。,；;]{0,10})/g, { zh: '一位参与者过往的工作经历中' }],
  ['self', /(?:我们|咱们)(?:这边|那边)?的?[A-Za-z0-9\u4e00-\u9fff]{0,6}?(?:部门|公司|单位|院|所|科室|科|组|团队|中心|基金会|站点|站|仓|学校|实验室|报社|编辑部|律所|协会|医院|研究院|研究所|处|司|局|机构|项目部|财务部)/g, { zh: '[某机构]' }],
  ['self', /(?:以前|之前|曾)在[^，。,；;！？]{1,16}?(?:带|做|当|干|待)[^，。,；;！？]{0,10}/g, { zh: '有过相关从业经历' }],
  ['self', /\b(?:as|As)\s+(?:the\s+|a\s+|an\s+)?(?:person|one|guy|woman|man)\s+(?:running|leading|who runs|who leads|in charge of|responsible for)\s+[^,.;]{1,60}/g, { en: 'In practice' }],
  ['self', /\b(?:as|As)\s+(?:the\s+|a\s+|an\s+|our\s+|their\s+)?(?:head|director|chair|lead|partner|editor|counsel|outside counsel|senior fellow|fellow|member|first secretary|officer|founder|ceo|cfo|cto|professor|reporter)\b[^,.;]{0,50}/gi, { en: 'In their role' }],
  ['self', /\b(?:at|in|on)\s+(?:my|our)\s+(?:firm|company|lab|newsroom|org|organisation|organization|team|centre|center|desk|department|unit|group|trust|foundation|hospital|university|school)\b/gi, { en: 'in their organisation' }],
  ['self', /\b(?:our|my)\s+team\s+at\s+[A-Z][\w&.-]*(?:\s+[A-Z][\w&.-]*)*/g, { en: 'their organisation' }],
  ['self', /\bI(?:'ve| have)\s+(?:chaired|led|run|headed|directed|managed|edited)\s+(?:this|the|our|my)\s+[A-Za-z-]+(?:\s+for\s+\w+\s+years)?/g, { en: 'a participant has relevant leadership experience' }],
  ['self', /\bI'?m\s+(?:up|due|going up)\s+for\s+(?:tenure|promotion|review|tenure review|promotion review)(?:\s+review)?(?:\s+(?:in|this|next)\s+[A-Z]?[a-z]+)?/g, { en: 'a participant faces an upcoming career review' }],
  ['self', /\bwhen I was at\s+[A-Z][\w&.-]*(?:\s+[A-Z][\w&.-]*)*/g, { en: 'in a previous role' }],
  ['self', /\bI (?:joined|work at|work for|worked at|used to work at)\s+[A-Z][\w&.'-]*(?:\s+[A-Z][\w&.'-]*)*/g, { en: 'a participant has a relevant affiliation' }],
];
const PH = { zh: { org: '[某机构]', title: '[某职务]' }, en: { org: 'an organisation', title: 'a role' } };

// ── Self-declared affiliation learning ─────────────────────────────────────────────────────────────
// A participant who says "我在星辰科技负责产品" / "我是张伟，在星辰科技负责产品" / "I work at Starfield Labs"
// has told the room their organisation. Rosters from conferencing hosts (LiveKit) carry only names, so the
// org is not in roster.org and — if it is not in KNOWN_ORGS — would survive L2 wherever it is mentioned
// (e.g. another participant: "星辰科技可真行，项目又延期了"). learnSelfOrgs() extracts such orgs from raw
// text; withLearnedOrgs() folds them into a roster (as extra `org` on the speaker's entry, or a name-less
// entry) so the ordinary roster-org path (orgFragments: 星辰科技 → 星辰) redacts them everywhere.
// Learned KNOWN_ORGS entries (我在腾讯工作) also become roster orgs → redacted everywhere in that session,
// consistent with "a KNOWN org contained in a roster org is always redacted". Weak cues (我们世界银行…,
// past tense "I worked at Google", "我在读世界银行的报告") are NOT learned (per-mention self-context still
// redacts those mentions), so public-fact keeping is unaffected for them.
const ORG_END = /(?:大学|学院|医院|研究院|研究所|研究中心|实验室|中心|公司|集团|协会|学会|基金会|基金|事务所|律所|律师事务所|科技|资本|银行|证券|保险|传媒|网络|智能|电子|汽车|设计院|报社|杂志社|出版社|工作室|工厂|科室|部|局|厅|署|委|院|所|处|司|站|厂|行|社|会|团队|小组)$/;
// strong (multi-char) org endings: required when the cue alone is weak (我是X的 / 我们X公司 / 我们在X)
const ORG_END_STRONG = /(?:大学|学院|医院|研究院|研究所|研究中心|实验室|公司|集团|协会|学会|基金会|事务所|律所|科技|资本|银行|证券|保险|传媒|网络|智能|电子|汽车|设计院|报社|杂志社|出版社|工作室|科室)$/;
const ZH_X = '[A-Za-z0-9\\u4e00-\\u9fff·&]';
const ZH_ADV = '(?:现在|目前|现|一直|主要|平时|这两年|这几年|今年|如今)?';
const ZH_JOB = '(?:负责|工作|上班|任职|就职|供职|担任|当|带|做|管|搞|干|实习|打工|读博|读研|念书|上学|教书|任教)';
const ZH_STOP = new Set(['这边', '那边', '这里', '那里', '这儿', '那儿', '家里', '家', '老家', '外地', '本地', '国外', '海外', '国内', '学校', '单位', '公司里', '一线', '现场', '前线', '后台', '里面', '外面', '周末', '晚上', '白天', '平时', '业余', '那时', '现在', '这家', '那家', '自己', '大家', '团队', '部门', '小组', '杭州', '南京', '成都', '武汉', '西安', '天津', '重庆', '苏州', '香港', '台湾', '美国', '英国', '日本', '南方', '北方', '城里', '农村', '乡下', '市里', '省里', '县里', '这个', '那个', '这行', '行业', '这一行', '互联网', '金融', '体制内', '外企', '国企', '私企', '创业公司', '大厂', '小厂', '项目', '项目组', '课题组', '组里', '组内', '实验', '会上', '线上', '线下', '这次', '那次', '一家', '小公司', '大公司', '科技公司', '互联网公司']);
const ZH_BAD = /的|一家|一个|一所|某|了|着|过|什么|哪|这|那|我|你|他|她|它|们|吗|呢|吧/;
const ZH_VERB_START = /^(?:负责|工作|上班|做|当|带|管|搞|干|读|看|学|准备|考虑|想|写|跑|研究|开发|讨论|聊|说|讲|参加|开会|处理|帮|给|跟|和|与|对|把|被|让|为|从|在|于|去|来|到)/;
const ZH_POS_END = /[上里中下内外时后前边头间]$/;
const EN_X = "[A-Z][\\w&.'’-]*(?:\\s+(?:&\\s+|of\\s+|and\\s+|for\\s+)?[A-Z][\\w&.'’-]*){0,4}";
const EN_ORG_END = /\b(?:Inc|Ltd|LLC|LLP|Corp|Corporation|Company|Co|Group|Labs?|Capital|Ventures|Partners|Bank|University|College|Institute|Hospital|Foundation|Trust|Tech|Technologies|Technology|Systems|Studio|Studios|Media|Consulting|Associates|Agency|Fund|Holdings|Centre|Center|School|Clinic|Press)\.?$/;
const EN_STOP = new Set(['I', 'The', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Home', 'Work', 'English', 'Chinese', 'Christmas', 'Easter']);

function cleanZhOrg(x, { needEnd = false } = {}) {
  let s = String(x || '').trim().replace(/(?:这边|那边|这里|那里|里面|里)$/, '');
  if (s.length < 2 || s.length > 14) return null;
  if (GENERIC.has(s) || ZH_STOP.has(s) || ZH_BAD.test(s) || ZH_VERB_START.test(s)) return null;
  const end = ORG_END.test(s);
  if (end && s.replace(ORG_END, '').length < 2 && !/^[A-Za-z]/.test(s)) return null; // bare "公司" / "银行"
  const head = s.replace(ORG_END, '');
  if (end && (GENERIC.has(head) || ZH_STOP.has(head))) return null; // 科技公司 / 互联网公司
  if (needEnd && !(ORG_END_STRONG.test(s) && s.replace(ORG_END_STRONG, '').length >= 2)) return null;
  if (!end) {
    if (ZH_POS_END.test(s)) return null;
    if (isCJK(s) && s.replace(/[A-Za-z0-9·&]/g, '').length > 8) return null;
  }
  return s;
}
function cleanEnOrg(x, { needEnd = false } = {}) {
  const s = String(x || '').trim().replace(/[.'’]+$/, '').replace(/\s+(?:and|of|for|&)$/i, '');
  if (s.length < 2) return null;
  const words = s.split(/\s+/);
  if (words.every((w) => EN_GENERIC.has(w) || EN_STOP.has(w))) return null;
  if (needEnd && !EN_ORG_END.test(s) && words.length < 2) return null;
  return s;
}

const LEARN_ZH = [
  // 我在X负责 / 我目前在X工作 / 本人就职于X
  [new RegExp(`(?:我|本人)${ZH_ADV}(?:在|于)(${ZH_X}{2,14}?)(?:这边|那边|里)?${ZH_JOB}`, 'g'), {}],
  // 我们在X做… (plural subject: only with an org-like ending)
  [new RegExp(`(?:我们|咱们)${ZH_ADV}(?:在|于)(${ZH_X}{2,14}?)(?:这边|那边|里)?${ZH_JOB}`, 'g'), { needEnd: true }],
  // 我(目前)就职于/任职于/供职于/来自X
  [new RegExp(`(?:我|本人)${ZH_ADV}(?:就职于|任职于|供职于|服务于)(${ZH_X}{2,14})`, 'g'), {}],
  [new RegExp(`(?:我|本人)${ZH_ADV}来自(${ZH_X}{2,14})(?=[，。,.!?！？；;、\\s]|$|的(?:产品|技术|研发|市场|销售|运营|团队|同事|员工))`, 'g'), {}],
  // 我是X的(员工/产品经理/…)  — X must look like an org
  [new RegExp(`(?:我|本人)(?:是|系)(${ZH_X}{2,14}?)的`, 'g'), { needEnd: true }],
  // 我们X公司/团队/… (the suffix noun makes it an org)
  [new RegExp(`(?:我们|咱们)(${ZH_X}{2,10}?(?:公司|集团|律所|实验室|工作室|科技|资本|事务所))(?![A-Za-z0-9\\u4e00-\\u9fff]*(?:公司|集团))`, 'g'), { needEnd: true, plural: true }],
];
// subject dropped after a self-intro clause: "我是张伟，在星辰科技负责产品" / "我叫李雷，目前就职于X"
const DROP_ZH = new RegExp(`^\\s*${ZH_ADV}(?:(?:在|于)(${ZH_X}{2,14}?)(?:这边|那边|里)?${ZH_JOB}|(?:就职于|任职于|供职于|来自)(${ZH_X}{2,14}?)(?=[，。,.!?！？；;、\\s]|$|的|${ZH_JOB}))`);
const INTRO_ZH = /^\s*(?:(?:大家好|各位好|你们好|大家下午好|大家上午好|大家晚上好|hi|hello|嗨|哈喽)[，,!！\s]*)?(?:我|本人)(?:是|叫|姓|名叫|就是)/i;
const LEARN_EN = [
  [new RegExp(`\\bI\\s+(?:currently\\s+|now\\s+|still\\s+)?work(?:s)?\\s+(?:at|for)\\s+(${EN_X})`, 'g'), {}],
  [new RegExp(`\\bI(?:'m|’m|\\s+am)\\s+(?:currently\\s+|now\\s+)?(?:working\\s+(?:at|for)|at|based\\s+at)\\s+(${EN_X})`, 'g'), {}],
  [new RegExp(`\\bI(?:'m|’m|\\s+am)\\s+(?:currently\\s+|now\\s+)?from\\s+(${EN_X})`, 'g'), { needEnd: true }],
  [new RegExp(`\\bI(?:'m|’m|\\s+am)\\s+(?:a|an|the)\\s+(?:[a-z][\\w-]*\\s+){0,3}(?:at|with|for)\\s+(${EN_X})`, 'g'), {}],
  [new RegExp(`\\b(?:[Ww]e|us)\\s+(?:here\\s+)?at\\s+(${EN_X})`, 'g'), {}],
  [new RegExp(`\\b[Hh]ere\\s+at\\s+(${EN_X})`, 'g'), {}],
];

/** Orgs a speaker self-declares in `text` (raw utterance). Returns a de-duplicated array of strings. */
export function learnSelfOrgs(text) {
  text = String(text ?? '');
  const out = new Set();
  const add = (s) => { if (s) out.add(s); };
  for (const [re, o] of LEARN_ZH) for (const m of text.matchAll(re)) {
    if (o.plural && /^(?:这边|那边|这个|那个|整个|自己|大家)/.test(m[1])) continue;
    add(cleanZhOrg(m[1], o));
  }
  for (const sent of text.split(/[。！？!?\n]/)) {
    const clauses = sent.split(/[，,；;]/);
    for (let i = 1; i < clauses.length; i++) {
      if (!clauses.slice(0, i).some((c) => INTRO_ZH.test(c))) continue;
      const m = clauses[i].match(DROP_ZH);
      if (m) add(cleanZhOrg(m[1] || m[2]));
    }
  }
  for (const [re, o] of LEARN_EN) for (const m of text.matchAll(re)) add(cleanEnOrg(m[1], o));
  return [...out];
}

/**
 * Fold learned orgs into a roster. learned: Map<speakerId, Iterable<string>> (or an array of strings for
 * an anonymous source). Members get them appended to `org` ("，"-joined, so orgFragments splits them);
 * learned orgs of ids not in the roster become a name-less entry { id, org }. Returns a NEW array
 * (or the same roster if nothing was learned).
 */
export function withLearnedOrgs(roster = [], learned) {
  const map = Array.isArray(learned) ? new Map([['\u0000learned', learned]]) : (learned instanceof Map ? learned : new Map());
  const extra = new Map();
  for (const [id, orgs] of map) { const xs = [...(orgs || [])].filter(Boolean); if (xs.length) extra.set(String(id), xs); }
  if (!extra.size) return roster;
  const out = (roster || []).map((p) => {
    const xs = extra.get(String(p.id));
    if (!xs) return p;
    extra.delete(String(p.id));
    const cur = p.org ? [String(p.org)] : [];
    return { ...p, org: [...new Set([...cur, ...xs])].join('，') };
  });
  for (const [id, xs] of extra) out.push({ id, org: xs.join('，') });
  return out;
}

export function detectAffiliation(text, roster = [], { allowPublicFacts = true } = {}) {
  text = String(text ?? '');
  const spans = [];
  SELF.forEach(([kind, re, rep], pri) => { for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind, match: m[0], rep, pri }); });
  const own = learnSelfOrgs(text); // a self-declaration in this very text redacts the org throughout it
  if (own.length) roster = withLearnedOrgs(roster, own);
  const d = dicts(roster);
  // Participant works (roster) and self-referential titles → [某作品]
  for (const re of d.work) for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'work', match: m[0], pri: 40 });
  for (const m of text.matchAll(TITLE_RE)) {
    const before = text.slice(Math.max(0, m.index - 24), m.index), after = text.slice(m.index + m[0].length, m.index + m[0].length + 24);
    if (WORK_SELF_BEFORE.test(before) || WORK_SELF_AFTER.test(after)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'work', match: m[0], pri: 40 });
  }
  for (const re of d.org) for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'org', match: m[0], pri: 50 });
  // Generic public orgs: kept unless prototype mode or self-affiliation context.
  for (const re of d.pub) for (const m of text.matchAll(re)) {
    if (!allowPublicFacts || selfContextBefore(text, m.index)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'org', match: m[0], pri: 50 });
  }
  // titles: skip 董事/理事 when part of 董事会/理事会 ("the board" is not a role)
  for (const re of d.title) for (const m of text.matchAll(re)) if (!(isCJK(m[0]) && text[m.index + m[0].length] === '会')) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'title', match: m[0], pri: 60 });
  spans.sort((a, b) => a.start - b.start || a.pri - b.pri || (b.end - b.start) - (a.end - a.start));
  const out = [];
  for (const s of spans) {
    const last = out[out.length - 1];
    if (last && s.start < last.end) { if (s.end > last.end && s.kind === last.kind && s.kind !== 'self') { last.end = s.end; last.match = text.slice(last.start, s.end); } continue; }
    out.push(s);
  }
  return out;
}

export function redactAffiliation(text, roster = [], opts = {}) {
  text = String(text ?? '');
  const spans = detectAffiliation(text, roster, opts);
  let out = '', pos = 0;
  for (const s of spans) {
    const lang = localLang(text, s.start, s.end);
    let ph;
    if (s.kind === 'self') ph = s.rep[lang] ?? s.rep.zh ?? s.rep.en ?? PH[lang].org;
    else if (s.kind === 'work') ph = WORK_PH[/[\u3400-\u9fff《》]/.test(s.match) ? 'zh' : lang];
    else ph = PH[lang][s.kind];
    out += text.slice(pos, s.start) + ph;
    pos = s.end;
  }
  out += text.slice(pos);
  return out.replace(/(\[某机构\])(?:的?\s*\1)+/g, '$1').replace(/(\[某职务\])(?:\s*\1)+/g, '$1').replace(/\b(an organisation)(?:\s+\1)+/g, '$1');
}
