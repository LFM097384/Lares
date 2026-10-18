// L1 deterministic PII: regex + roster dictionaries.
// Placeholders are deliberately un-numbered: "[参与者]" / "a participant" — numbering
// would let a reader link claims made by the same person.
//
// Tradeoffs (documented):
// - Chinese honorific matching only fires for surnames of roster members (陈总, 老陈, 小郭).
//   "总体/总结/总之…" are excluded by a negative lookahead after 总.
// - Third-party Chinese names are only caught in strong contexts (name + title like 副总/校长/老师,
//   title + name, 患者/病例是/叫 + name, X先生/X女士). Bare unknown names in free text are missed (→ L3).
// - English third parties: "Mr./Ms./Dr./Prof. X" and "<common first name> <Capitalised>".
// - ASCII roster aliases are matched case-sensitively on word boundaries so that "Grant" (a surname)
//   does not destroy "grant" (money). All-caps short aliases (JG, MH) need whole-word matches.
// - Bare years ("2019"), months ("6月"), quarters (Q3) are kept; month+day is treated as an exact date.
//
// Gate v2 public facts (opts.allowPublicFacts, default true; false = prototype behaviour):
// - World knowledge is not de-identified: a third-party name is KEPT when it is cheaply recognisable as a
//   public figure — it is in the small PUBLIC_FIGURES list, or it is used authorially
//   (刘慈欣老师写的 / X著 / X的《…》 / X在《…》 / 《…》的作者X / author X).
// - Private third parties in strong contexts (患者赵立新, 李卫东副总, Dr. Okafor) are still redacted.
// - Roster names / aliases / publicName are ALWAYS redacted, even if they collide with a public figure
//   (if a participant IS the public figure, the name points back to them).
// - Gaps: a private person mentioned authorially ("我同事王强写的报告") is kept as if public; a public
//   figure in a strong private-looking context not covered above (e.g. "马化腾总") is redacted.

const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const CJK = '\\u3400-\\u9fff';
const isCJK = (s) => /[\u3400-\u9fff]/.test(s);

export const SURNAMES = '王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师和仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩明佘池查麻苑迟邝';
const COMPOUND = ['欧阳', '司马', '上官', '诸葛', '东方', '慕容', '夏侯', '皇甫', '尉迟', '公孙', '令狐', '端木', '司徒', '长孙'];
// Words that look like surname+given but are common vocabulary (avoid nuking ideas).
const NOT_NAMES = new Set(['成本', '高层', '方面', '方案', '高管', '江湖', '金额', '全部', '全国', '时间', '明年', '安全', '文件', '应该', '和他', '和她', '和我', '和你', '和刘', '和陈', '师傅', '程序', '项目', '商务', '管理', '路线', '宁可', '向他', '于是', '同事', '许多', '单位', '连续', '包括', '关于', '常规', '康复', '史上', '席位', '车间', '平台', '强制', '万家', '万元', '伍佰', '黎明', '华东', '华南', '华北', '高校', '高于', '戴着', '田野', '邓氏', '白天', '左右', '毛利', '党委', '柏林', '谷歌', '曲线', '景气', '万亿', '钱款', '宋体', '叶片', '牛市', '马上', '朱红', '孙子', '贺词', '雷达', '龙头', '齐全', '周期', '周末', '周边', '周内', '周三', '周一', '周二', '周四', '周五', '周六', '周日', '林业', '黄金', '苏州', '江苏', '杨浦', '陆续', '何况', '何时', '余额', '余下', '程度', '金融', '石油', '董事', '武汉', '沈阳', '温度', '温州', '常州', '许可', '宁德', '韩国', '申请', '申报', '曹操', '彭博', '罗马', '冯唐', '邱园', '施工', '乔布', '严重', '严格', '凌晨', '解决', '解释', '解约', '解读', '管道', '盛行', '应对', '应用', '杜绝', '卫生', '童工', '尚未', '甘肃', '柯林', '宫颈', '冷链', '经理', '卢布', '吉林', '房地', '房租', '房子', '时候', '时长', '时点', '党员', '明确', '明显', '明天', '明白', '和解', '查验', '查到', '查明', '查询', '池子', '简单', '简历', '项下', '连接', '车辆', '车队', '谷底', '甄别', '仲裁', '商量', '商家', '商户', '全职', '全额', '全面', '边界', '边际', '师资', '左侧', '包装', '包含', '卜算', '费用', '费率', '席间', '晏起', '米兰', '宗旨', '桂林', '应收', '应付', '佟丽', '虞城', '沙特', '荣誉', '寇准', '郎中', '巩固', '麻烦', '迟到', '苑里', '和平', '时代', '安排', '安装', '安徽', '江西', '向前', '向下', '向上', '方法', '方式', '方向', '方便', '高度', '高峰', '高级', '高效', '高于', '石家', '万一', '文化', '文本', '文章', '文档', '易于', '于此', '常委', '戴维', '庞大', '鲁棒', '倪匡', '申明', '欧洲', '欧盟', '欧元', '欧美', '关键', '关系', '关注', '关联', '兰州', '焦虑', '焦点', '俞敏', '左边', '柳州', '祝贺', '包括', '宁愿', '尚且', '符合', '舒适', '纪律', '纪要', '梅毒', '童年', '毕业', '单独', '单元', '单价', '季度', '霍乱', '涂层', '成为', '成功', '成熟', '成员', '成立', '成长', '成交', '苗头', '谷物', '盛大', '曲折', '翁婿', '路径', '路由', '游戏', '辛苦', '蒙古', '华为', '华人', '喻义', '祁连', '蒲公', '房间', '滕州', '屈服', '饶恕', '艾滋', '尤其', '阳性', '时间', '穆斯', '农村', '农民', '农业', '司法', '卓越', '古代', '吉祥', '缪斯', '车型', '项目', '连锁', '麦当', '褚橙', '娄底', '窦性', '戚继', '岑参', '景区', '党支', '宫外', '费城', '卜卦', '冷却', '冷静', '席卷', '卫星', '米饭', '柏油', '宗教', '瞿秋', '桂花', '全球', '佟佳', '应届', '臧否', '闵行', '苟且', '邬斯', '边缘', '卞之', '姬妾', '师范', '和谐', '仇恨', '栾川', '隋朝', '商业', '商品', '刁难', '沙龙', '荣获', '巫术', '寇仇', '桑拿', '郎平', '甄嬛', '丛林', '仲夏', '虞姬', '敖包', '巩俐', '明星', '佘山', '池塘', '查看', '麻醉', '苑囿', '迟早', '邝氏']);

const CN_HONORIFIC = '(?:总(?![体结之共量额数部是算计价值裁监经共务]|的来)|老师(?!们)|老板|老师傅|师傅|哥|姐|工(?![作资厂人程具业])|博士|博(?![客物士弈])|医生|大夫|主任|主席|教授|律师|书记|记者|编辑|同学|院长|局长|处长|处(?![理于在罚])|所长|经理|会计|组长|队长|站长|校长|部长|科长|秘书长|女士|先生|副总|董|总监)';
const THIRD_TITLE = '(?:副总|总经理|总监|校长|处长|局长|科长|部长|厅长|院长|主任|老师|医生|大夫|教授|律师|经理|书记|董事长|博士|先生|女士|师傅|站长|厂长|主管|同学|记者|编辑|会计)';
const THIRD_PREFIX = '(?:患者|病人|病例是|病人是|叫做|名叫|叫|副总|总经理|校长|处长|局长|主任|经理|主管|联系人|对接人|同事|老板|厂长|董事长|记者|律师)';

const FIRST_NAMES = 'James John Robert Michael William David Richard Joseph Thomas Charles Christopher Daniel Matthew Anthony Mark Donald Steven Paul Andrew Joshua Kenneth Kevin Brian George Edward Ronald Timothy Jason Jeffrey Ryan Jacob Gary Nicholas Eric Jonathan Stephen Larry Justin Scott Brandon Benjamin Samuel Frank Gregory Raymond Alexander Patrick Jack Dennis Jerry Tyler Aaron Henry Adam Peter Nathan Zachary Kyle Walter Harold Jeremy Ethan Carl Keith Roger Gerald Christian Terry Sean Arthur Austin Noah Lawrence Jesse Joe Bryan Billy Jordan Albert Dylan Bruce Willie Gabriel Alan Juan Logan Wayne Ralph Roy Eugene Randy Vincent Russell Louis Philip Bobby Johnny Bradley Hugo Oliver Lucas Leo Max Felix Omar Ahmed Mohammed Ali Raj Rahul Arjun Vikram Hiroshi Kenji Takeshi Mary Patricia Jennifer Linda Elizabeth Barbara Susan Jessica Sarah Karen Nancy Lisa Betty Margaret Sandra Ashley Kimberly Emily Donna Michelle Dorothy Carol Amanda Melissa Deborah Stephanie Rebecca Sharon Laura Cynthia Kathleen Amy Shirley Angela Helen Anna Brenda Pamela Nicole Emma Samantha Katherine Christine Debra Rachel Catherine Carolyn Janet Ruth Maria Heather Diane Virginia Julie Joyce Victoria Olivia Kelly Christina Lauren Joan Evelyn Judith Megan Cheryl Andrea Hannah Martha Jacqueline Frances Gloria Ann Teresa Kathryn Sara Janice Jean Alice Madison Doris Abigail Julia Judy Grace Denise Amber Marilyn Beverly Danielle Theresa Sophia Marie Diana Brittany Natalie Isabella Charlotte Rose Alexis Kayla Priya Ananya Aisha Fatima Mei Yuki Sophie Chloe Claire Lucy Zoe Mia Nina Ingrid Astrid Elena Sofia Lena Clara Paula Laila Tina Jenny Vivian Cindy Wendy Peggy Fiona Eva Irene Iris'.split(' ');

const PH = {
  zh: { name: '[参与者]', third: '[某人]', phone: '[电话]', email: '[邮箱]', idcard: '[证件号]', bankcard: '[账号]', url: '[链接]', handle: '[账号]', address: '[地址]', date: '[日期]' },
  en: { name: 'a participant', third: 'someone', phone: '[phone]', email: '[email]', idcard: '[ID number]', bankcard: '[account]', url: '[link]', handle: '[handle]', address: '[address]', date: '[date]' },
};

export function localLang(text, start, end) {
  const w = text.slice(Math.max(0, start - 24), Math.min(text.length, end + 24));
  const cjk = (w.match(/[\u3400-\u9fff]/g) || []).length;
  const en = (w.match(/[A-Za-z]{2,}/g) || []).length;
  return cjk >= en * 1.5 ? 'zh' : 'en';
}

export function splitCnName(name) {
  for (const c of COMPOUND) if (name.startsWith(c) && name.length > c.length) return [c, name.slice(c.length)];
  return [name[0], name.slice(1)];
}

// Build per-roster name patterns (cached per roster object).
const cache = new WeakMap();
function rosterPatterns(roster = []) {
  if (cache.has(roster)) return cache.get(roster);
  const cn = new Set(), asciiCI = new Set(), asciiCS = new Set(), surnames = new Set();
  for (const p of roster) {
    for (const v of [p.name, ...(p.aliases || []), ...(p.publicName ? [p.publicName] : [])]) {
      if (!v) continue;
      const s = String(v).trim();
      if (isCJK(s)) {
        if (s.length >= 2) cn.add(s);
        // A bare Chinese full name: derive surname / given name.
        if (s === p.name && /^[\u4e00-\u9fff]{2,4}$/.test(s)) {
          const [sur, given] = splitCnName(s);
          surnames.add(sur);
          if (given.length >= 2) cn.add(given);
        }
        const m = s.match(/^(老|小)([\u4e00-\u9fff])$/); if (m) surnames.add(m[2]);
        continue;
      }
      // ASCII / Latin name
      const parts = s.split(/\s+/).filter(Boolean);
      if (parts.length > 1) asciiCI.add(s);
      for (const part of parts) {
        if (/^(Dr|Prof|Mr|Ms|Mrs|Miss)\.?$/i.test(part)) continue;
        // Lower-case parts of multi-word aliases ("the Chair" → "the") are vocabulary, not names.
        if (part.length >= 2 && !(parts.length > 1 && /^[a-z]/.test(part))) asciiCS.add(part);
      }
      if (/^(Dr|Prof|Mr|Ms|Mrs)\.?\s/i.test(s)) asciiCI.add(s);
    }
    // Western full name -> Dr./Mr./Ms./Prof. + surname
    if (p.name && !isCJK(p.name)) {
      const last = p.name.trim().split(/\s+/).pop();
      for (const t of ['Dr', 'Prof', 'Mr', 'Ms', 'Mrs']) asciiCI.add(`${t}. ${last}`), asciiCI.add(`${t} ${last}`);
    }
  }
  const list = [];
  const sur = [...surnames].map(esc).join('|');
  if (sur) {
    list.push(new RegExp(`(?:${sur})${CN_HONORIFIC}`, 'g'));
    list.push(new RegExp(`[老小](?:${sur})(?![时学区组数部件型]|师)`, 'g'));
  }
  const cnSorted = [...cn].sort((a, b) => b.length - a.length).map(esc);
  if (cnSorted.length) list.push(new RegExp(cnSorted.join('|'), 'g'));
  const ci = [...asciiCI].sort((a, b) => b.length - a.length).map(esc);
  if (ci.length) list.push(new RegExp(`(?<![A-Za-z0-9À-ÿ])(?:${ci.join('|')})(?![A-Za-z0-9À-ÿ])`, 'gi'));
  const cs = [...asciiCS].sort((a, b) => b.length - a.length).map(esc);
  if (cs.length) list.push(new RegExp(`(?<![A-Za-z0-9À-ÿ_@.])(?:${cs.join('|')})(?:'s|’s)?(?![A-Za-z0-9À-ÿ_])`, 'g'));
  cache.set(roster, list);
  return list;
}

const SUR_CLASS = `[${SURNAMES}]`;
const PATTERNS = [
  ['email', /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g],
  ['url', /\bhttps?:\/\/[^\s，。、；）)]+|\bwww\.[^\s，。、；）)]+|\b(?:[a-z0-9-]+\.)+(?:com|org|net|cn|io|uk|edu|gov|me|ai|co|info|dev|app|hk|tw)(?:\/[\w\-./?%&=#~+]*)?(?![\w@])/gi],
  ['handle', /(?<![\w.@])@[A-Za-z0-9_\u4e00-\u9fff][\w.\u4e00-\u9fff]*[\w\u4e00-\u9fff]|(?<![\w.@])@[A-Za-z0-9_\u4e00-\u9fff]/g],
  // Usernames in metadata/account context: "author 'zlei'", "username: jdoe", 用户名是 zlei.
  ['handle', /(?<=\b(?:author|username|user name|login|account|user id|userid|creator)\s*[:=]?\s*['"‘“]?)[A-Za-z][A-Za-z0-9_.-]{1,31}(?=['"’”])|(?<=\b(?:username|login|user id|userid)\s*[:=]?\s*)[A-Za-z][A-Za-z0-9_.-]{1,31}|(?<=(?:作者名|用户名|账号|登录名|创建者)(?:是|为|:|：)?\s*['"‘“「]?)[A-Za-z][A-Za-z0-9_.-]{1,31}/gi],
  ['idcard', /(?<!\d)[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?![\dA-Za-z])|(?<!\d)[1-9]\d{7}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}(?!\d)/g],
  ['bankcard', /(?<!\d)(?:\d{4}[ -]?){3,4}\d{1,4}(?!\d)/g],
  ['phone', /(?:\+?86[\s-]?)?(?<!\d)1[3-9]\d[\s-]?\d{4}[\s-]?\d{4}(?!\d)|\+\d{1,3}[\s-]?\(?\d{1,4}\)?(?:[\s-]?\d{2,4}){2,3}(?!\d)|(?<![\d-])\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?!\d)|(?<![\d-])0\d{2,3}-\d{7,8}(?!\d)/g],
  ['address', new RegExp(`(?:[${CJK}]{2,7}?(?:省|自治区|市|新区|区|县|乡|镇|村|街道|大道|街|路|巷|弄|胡同|园区|里))+(?:[甲乙丙]?[0-9一二三四五六七八九十]+(?:号院|号楼|号|栋|幢|单元|室|层|楼|区))*(?:[0-9]{2,4})?`, 'g')],
  ['address', new RegExp(`[${CJK}]{1,6}(?:区|县|市)[${CJK}]{1,8}?[甲乙丙]?[0-9]{1,5}号(?:院|楼)?`, 'g')],
  ['phone', /(?<![\d-])0\d{4}\s\d{3}\s\d{3}(?!\d)|(?<![\d-])0\d{2,4}\s\d{3,4}\s\d{4}(?!\d)/g], // UK-style landlines
  ['address', /\b(?:Room|Rm\.?|Office|Suite)\s+\d[\w.-]*(?:,\s*(?:[A-Z][\w'-]+\s+){1,3}(?:Building|Hall|House|Tower|Centre|Center|Block|Wing))?/g],
  ['address', /\b\d{1,5}\s+(?:[A-Z][a-z]+\s){1,3}(?:St|Street|Rd|Road|Ave|Avenue|Blvd|Boulevard|Lane|Ln|Way|Drive|Dr|Court|Place|Square)\b\.?|\b[\p{Lu}][\p{L}]+(?:strasse|straße|gasse|weg|platz|laan|straat)\s+\d+[a-z]?(?:,\s*\d{4,5}\s+[\p{Lu}][\p{L}]+)?/gu],
  ['date', /(?:上|下|这|本)个?月(?:0?[1-9]|[12]\d|3[01])(?:日|号)/g],
  ['date', /(?<!\d)(?:19|20)\d{2}[-/.](?:0?[1-9]|1[0-2])[-/.](?:0?[1-9]|[12]\d|3[01])(?!\d)|(?:(?:19|20)\d{2}年)?(?<!\d)(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12]\d|3[01])(?:日|号)|\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+(?:19|20)\d{2})?\b|\b\d{1,2}(?:st|nd|rd|th)?\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b(?:\s+(?:19|20)\d{2})?|(?<![\d.])(?:0?[1-9]|1[0-2])\/(?:0?[1-9]|[12]\d|3[01])(?![\d/.%])/g],
];

const ADDR_LEAD = /^(?:住在|住|地址是|地址|位于|寄到|搬到|送到|在|到|是|去|从|的)+/;
const ADMIN_UNITS = /(省|自治区|市|区|县|乡|镇|村|街道|街|路|巷|弄|胡同|园区|里)/g;

// Small, deliberately conservative list of public figures commonly cited in discussions.
export const PUBLIC_FIGURES = [
  '鲁迅', '胡适', '钱钟书', '杨绛', '沈从文', '巴金', '老舍', '金庸', '莫言', '余华', '刘慈欣', '王小波', '张爱玲', '路遥', '贾平凹', '韩寒', '郭敬明', '钱学森', '袁隆平', '屠呦呦', '杨振宁', '李政道', '施一公', '饶毅', '马云', '马化腾', '任正非', '雷军', '李彦宏', '张一鸣', '刘强东', '董明珠', '王兴', '黄峥', '梁文锋', '费孝通', '吴敬琏', '林毅夫', '张五常', '孔子', '老子', '孟子', '庄子', '司马迁', '毛泽东', '邓小平', '孙中山',
  'Elon Musk', 'Steve Jobs', 'Bill Gates', 'Jeff Bezos', 'Mark Zuckerberg', 'Sam Altman', 'Warren Buffett', 'Barack Obama', 'Donald Trump', 'Joe Biden', 'Angela Merkel', 'Emmanuel Macron', 'Adam Smith', 'John Maynard Keynes', 'Milton Friedman', 'Karl Marx', 'Max Weber', 'George Orwell', 'Noam Chomsky', 'Yuval Noah Harari', 'Daniel Kahneman', 'Geoffrey Hinton', 'Yann LeCun', 'Yoshua Bengio', 'Alan Turing', 'Albert Einstein', 'Thomas Piketty', 'Joseph Stiglitz', 'Paul Krugman', 'Greta Thunberg', 'Jane Austen', 'William Shakespeare',
];
const PUBLIC_SET = new Set(PUBLIC_FIGURES);
const AUTHORIAL_AFTER = new RegExp(`^(?:${THIRD_TITLE})?(?:写的|写过|所写|所著|著|编著|主编的|的《|在《|的书|的小说|的著作|的作品|的名言|的名著|说过|曾说|曾经说|有句话|有本书)`);
const AUTHORIAL_BEFORE = /(?:《[^》]{1,40}》的?(?:作者|译者|导演)|作者是?|\bauthor\s+|\bwritten by\s+|\bby\s+)$/i;

function isPublicFigure(text, start, end, nameOnly) {
  if (PUBLIC_SET.has(nameOnly)) return true;
  if (AUTHORIAL_AFTER.test(text.slice(end, end + 12)) || AUTHORIAL_AFTER.test(text.slice(start + nameOnly.length, start + nameOnly.length + 12))) return true;
  if (AUTHORIAL_BEFORE.test(text.slice(Math.max(0, start - 30), start))) return true;
  return /^(?:'s|’s)?\s+(?:book|novel|bestseller|memoir)\b|^,?\s+(?:the\s+)?author\s+of\b/i.test(text.slice(end, end + 24));
}

function thirdPartyNames(text, { allowPublicFacts = true } = {}) {
  const out = [];
  const add = (start, match, nameOnly = match) => {
    if (allowPublicFacts && isPublicFigure(text, start, start + match.length, String(nameOnly).replace(/^(?:Mr|Ms|Mrs|Miss|Dr|Prof)\.?\s+/, ''))) return;
    out.push({ start, end: start + match.length, kind: 'third', match });
  };
  // Name + title: 李卫东副总, 杨秀英校长, 刘广平老师, 李处长
  const reA = new RegExp(`(${SUR_CLASS}[${CJK}]{0,2}?)(?=${THIRD_TITLE})`, 'g');
  for (const m of text.matchAll(reA)) {
    const nm = m[1];
    if (nm.length >= 2 && NOT_NAMES.has(nm.slice(0, 2))) continue;
    if (nm.length >= 2 && /[的了是在和与跟对把被给向就都也还又说讲找请让问]/.test(nm.slice(1))) continue;
    if (m.index > 0 && /[\u4e00-\u9fff]/.test(text[m.index - 1]) && nm.length === 1 && !/[的和跟与找问请让给叫是位]/.test(text[m.index - 1])) continue;
    const title = text.slice(m.index + nm.length).match(new RegExp(`^${THIRD_TITLE}`))[0];
    add(m.index, nm + (nm.length === 1 ? title : ''), nm);
  }
  // Title/context + name: 质量副总刘振华, 患者赵立新, 病例是赵立新
  const reB = new RegExp(`(?<=${THIRD_PREFIX})(${SUR_CLASS}[${CJK}]{1,2})`, 'g');
  for (const m of text.matchAll(reB)) { if (!NOT_NAMES.has(m[1].slice(0, 2))) add(m.index, m[1]); }
  // Honorific western: Mr. Smith / Dr. Okafor
  for (const m of text.matchAll(/\b(?:Mr|Ms|Mrs|Miss|Dr|Prof)\.?\s+[A-Z][\p{L}'-]+/gu)) add(m.index, m[0]);
  // Common first name + Capitalised surname (+ optional middle/last: "Yuval Noah Harari")
  const fn = new RegExp(`\\b(?:${FIRST_NAMES.join('|')})\\s+[A-Z][\\p{L}'-]+(?:\\s+[A-Z][\\p{L}'-]+)?`, 'gu');
  for (const m of text.matchAll(fn)) {
    let match = m[0];
    if (/\bthe\s+$/i.test(text.slice(Math.max(0, m.index - 4), m.index))) continue; // "the Russell Group" is not a person
    // Only keep the 3rd capitalised token when the 3-token form is a known public figure.
    if (match.split(/\s+/).length === 3 && !PUBLIC_SET.has(match)) match = match.split(/\s+/).slice(0, 2).join(' ');
    add(m.index, match);
  }
  // Direct address: "Thanks, Qiuping" / "Sorry, Maggie" — the addressee is an attendee (or someone in the room).
  for (const m of text.matchAll(/\b(?:Thanks|Thank you|Cheers|Sorry|Hi|Hey|Right|Yes|No|Well|OK|Okay),\s+([A-Z][a-z]{2,})\b(?!\s+[A-Z])/g)) {
    if (/^(?:All|Everyone|Everybody|Team|Guys|Folks|Both|Again|Though|Then|There|That|This|The|We|They|And|But|So|Indeed|Sure|Fine|Agreed)$/.test(m[1])) continue;
    out.push({ start: m.index + m[0].length - m[1].length, end: m.index + m[0].length, kind: 'third', match: m[1] });
  }
  // Public figures not matched by any pattern above are simply never redacted (they are not roster tokens).
  return out;
}

export function detectPII(text, roster = [], { allowPublicFacts = true } = {}) {
  text = String(text ?? '');
  const spans = [];
  PATTERNS.forEach(([kind, re], pri) => {
    for (const m of text.matchAll(re)) {
      let start = m.index, match = m[0];
      if (kind === 'url') match = match.replace(/[.,;:!?'")\]]+$/, '');
      if (kind === 'handle') match = match.replace(/\.+$/, '');
      if (kind === 'address' && isCJK(match)) {
        const lead = match.match(ADDR_LEAD); if (lead) { start += lead[0].length; match = match.slice(lead[0].length); }
        const units = (match.match(ADMIN_UNITS) || []).length;
        const hasNum = /[0-9一二三四五六七八九十]+(号|栋|幢|单元|室)/.test(match);
        if (!(hasNum || units >= 3)) continue;
        if (!hasNum && /(?:思|道|线|套|门|出|网|半|走|进|心|马|一)路|(?:这|那|哪|心|市|城|家|夜)里/.test(match) && units <= 3) continue; // 思路/市里 are words
      }
      if (kind === 'bankcard' && match.replace(/\D/g, '').length < 16) continue;
      if (!match) continue;
      spans.push({ start, end: start + match.length, kind, match, pri });
    }
  });
  for (const re of rosterPatterns(roster)) for (const m of text.matchAll(re)) spans.push({ start: m.index, end: m.index + m[0].length, kind: 'name', match: m[0], pri: 20 });
  for (const s of thirdPartyNames(text, { allowPublicFacts })) spans.push({ ...s, pri: 30 });
  // Resolve overlaps: earlier start wins, then higher priority (lower number), then longer.
  spans.sort((a, b) => a.start - b.start || a.pri - b.pri || (b.end - b.start) - (a.end - a.start));
  const out = [];
  for (const s of spans) {
    const last = out[out.length - 1];
    if (last && s.start < last.end) {
      if (s.pri < last.pri && s.end - s.start >= last.end - last.start) out[out.length - 1] = s; // stronger kind fully covering
      else if (s.end > last.end && s.pri === last.pri) last.end = s.end, last.match = text.slice(last.start, s.end);
      continue;
    }
    out.push(s);
  }
  return out.map(({ start, end, kind, match }) => ({ start, end, kind, match }));
}

export function redactPII(text, roster = [], opts = {}) {
  text = String(text ?? '');
  const spans = detectPII(text, roster, opts);
  let out = '', pos = 0;
  for (const s of spans) {
    const lang = localLang(text, s.start, s.end);
    let ph = PH[lang][s.kind] || PH[lang].name;
    // English placeholders at sentence start get capitalised.
    if (lang === 'en' && /^[a-z]/.test(ph) && /(^|[.!?]\s+)$/.test(out + text.slice(pos, s.start))) ph = ph[0].toUpperCase() + ph.slice(1);
    out += text.slice(pos, s.start) + ph;
    pos = s.end;
  }
  out += text.slice(pos);
  return out.replace(/a participant's/g, "a participant's").replace(/(\[[^\]]+\])(?:\s*\1)+/g, '$1');
}
