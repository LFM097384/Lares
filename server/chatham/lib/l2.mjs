// L2 affiliation: roster orgs/titles (+fragments), a built-in org/title dictionary,
// and self-affiliation heuristics ("我们部门", "我在X的时候", "as head of X at Y").
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
const EN_GENERIC = new Set(['The', 'Centre', 'Center', 'Institute', 'University', 'College', 'School', 'Foundation', 'Trust', 'Family', 'Inc', 'Ltd', 'LLP', 'LLC', 'Group', 'Labs', 'Lab', 'AI', 'Power', 'Wire', 'Desk', 'Research', 'Language', 'Evaluation', 'Machine', 'Learning', 'Development', 'Rural', 'Pacific', 'Asia', 'for', 'of', 'and', 'Program', 'Hospital', 'Bureau', 'News', 'Media', 'Global', 'International', 'Partners', 'Capital', 'Ventures', 'Harbor', 'Fund', 'Data', 'Systems', 'Technologies', 'Technology']);

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
  for (const f of [...out]) if (GENERIC.has(f) || f.length < 2) out.delete(f);
  return out;
}

const cache = new WeakMap();
function dicts(roster = []) {
  if (cache.has(roster)) return cache.get(roster);
  const orgs = new Set(KNOWN_ORGS), titles = new Set(KNOWN_TITLES);
  for (const p of roster) {
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
  const d = { org: mk(orgs), title: mk(titles) };
  cache.set(roster, d);
  return d;
}

// Self-affiliation patterns (applied first, they consume context words around the org).
const SELF = [
  // 我作为X的Y / 作为X  → 以其职务身份
  ['self', /(?:我|本人)?作为[^，。,；;！？]{1,24}?(?=[，,。；;]|$|我|，)/g, { zh: '以其身份' }],
  ['self', /我(?:以前|之前|曾经|当年)?在[^，。,；;！？]{1,20}?(?:的时候|这些年|那些年|工作|上班|当了?[^，。,；;]{0,10}|带[^，。,；;]{0,8}|干了?[^，。,；;]{0,10})/g, { zh: '一位参与者过往的工作经历中' }],
  ['self', /(?:我们|咱们)(?:这边|那边)?的?[A-Za-z0-9\u4e00-\u9fff]{0,6}?(?:部门|公司|单位|院|所|科室|科|组|团队|中心|基金会|站点|站|仓|学校|实验室|报社|编辑部|律所|协会|医院|研究院|研究所|处|司|局|机构|项目部|财务部)/g, { zh: '[某机构]' }],
  ['self', /(?:以前|之前|曾)在[^，。,；;！？]{1,16}?(?:带|做|当|干|待)[^，。,；;！？]{0,10}/g, { zh: '有过相关从业经历' }],
  ['self', /\b(?:as|As)\s+(?:the\s+|a\s+|an\s+)?(?:person|one|guy|woman|man)\s+(?:running|leading|who runs|who leads|in charge of|responsible for)\s+[^,.;]{1,60}/g, { en: 'In practice' }],
  ['self', /\b(?:as|As)\s+(?:the\s+|a\s+|an\s+|our\s+|their\s+)?(?:head|director|chair|lead|partner|editor|counsel|outside counsel|senior fellow|fellow|member|first secretary|officer|founder|ceo|cfo|cto|professor|reporter)\b[^,.;]{0,50}/gi, { en: 'In their role' }],
  ['self', /\b(?:at|in|on)\s+(?:my|our)\s+(?:firm|company|lab|newsroom|org|organisation|organization|team|centre|center|desk|department|unit|group|trust|foundation|hospital|university|school)\b/gi, { en: 'in their organisation' }],
  ['self', /\b(?:our|my)\s+team\s+at\s+[A-Z][\w&.-]*(?:\s+[A-Z][\w&.-]*)*/g, { en: 'their organisation' }],
  ['self', /\bwhen I was at\s+[A-Z][\w&.-]*(?:\s+[A-Z][\w&.-]*)*/g, { en: 'in a previous role' }],
  ['self', /\bI (?:joined|work at|work for|worked at|used to work at)\s+[A-Z][\w&.'-]*(?:\s+[A-Z][\w&.'-]*)*/g, { en: 'a participant has a relevant affiliation' }],
];
const PH = { zh: { org: '[某机构]', title: '[某职务]' }, en: { org: 'an organisation', title: 'a role' } };

export function detectAffiliation(text, roster = []) {
  text = String(text ?? '');
  const spans = [];
  SELF.forEach(([kind, re, rep], pri) => { for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind, match: m[0], rep, pri }); });
  const d = dicts(roster);
  for (const re of d.org) for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'org', match: m[0], pri: 50 });
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

export function redactAffiliation(text, roster = []) {
  text = String(text ?? '');
  const spans = detectAffiliation(text, roster);
  let out = '', pos = 0;
  for (const s of spans) {
    const lang = localLang(text, s.start, s.end);
    let ph;
    if (s.kind === 'self') ph = s.rep[lang] ?? s.rep.zh ?? s.rep.en ?? PH[lang].org;
    else ph = PH[lang][s.kind];
    out += text.slice(pos, s.start) + ph;
    pos = s.end;
  }
  out += text.slice(pos);
  return out.replace(/(\[某机构\])(?:的?\s*\1)+/g, '$1').replace(/(\[某职务\])(?:\s*\1)+/g, '$1').replace(/\b(an organisation)(?:\s+\1)+/g, '$1');
}
