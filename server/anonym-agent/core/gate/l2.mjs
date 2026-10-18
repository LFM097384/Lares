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

export function detectAffiliation(text, roster = [], { allowPublicFacts = true } = {}) {
  text = String(text ?? '');
  const spans = [];
  SELF.forEach(([kind, re, rep], pri) => { for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind, match: m[0], rep, pri }); });
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
