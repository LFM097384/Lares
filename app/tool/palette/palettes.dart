// 名画配色候选集 —— 纯 Dart,不 import flutter,方便 `dart run` 直接算对比度。
//
// 纪律:本目录下所有文件都是**离线设计工具**,不参与 app 构建,
// 也绝不修改 lib/ 下任何东西(尤其不动 tokens.dart)。
//
// 每套方案给出与 LaresColors 暗色部分一一对应的 token 全集:
//   bg / surface / surfaceHigh / brand / 4 个状态色 / textPrimary / textSecondary
//
// 颜色一律写成 0xAARRGGBB(全不透明),与 Flutter Color 构造口径一致。

/// 一套完整的暗色 token。
class Palette {
  const Palette({
    required this.id,
    required this.name,
    required this.source,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.brand,
    required this.onBrand,
    required this.textPrimary,
    required this.textSecondary,
    required this.statusFree,
    required this.statusBusy,
    required this.statusEars,
    required this.statusAway,
    required this.temperament,
    required this.weakness,
  });

  /// 输出文件名前缀,如 `rembrandt`。
  final String id;

  /// 中文方案名。
  final String name;

  /// 取色来源(画作)。
  final String source;

  final int bg;
  final int surface;
  final int surfaceHigh;

  /// 品牌色:主按钮底色 + 语音波纹 + 未读圆点。
  final int brand;

  /// 品牌色上的前景文字色(主按钮文字)。
  final int onBrand;

  final int textPrimary;
  final int textSecondary;

  final int statusFree; // 随时聊
  final int statusBusy; // 在忙
  final int statusEars; // 耳朵在
  final int statusAway; // 有事先走

  final String temperament;
  final String weakness;

  /// 品牌色的 20% 淡色(自己发的消息底色),对应 LaresColors.emberSoft。
  int get brandSoft => (brand & 0x00FFFFFF) | 0x33000000;

  Map<String, int> get textTokens => <String, int>{
        'textPrimary': textPrimary,
        'textSecondary': textSecondary,
      };

  Map<String, int> get statusTokens => <String, int>{
        'free 随时聊': statusFree,
        'busy 在忙': statusBusy,
        'ears 耳朵在': statusEars,
        'away 有事先走': statusAway,
      };

  Map<String, int> get allTokens => <String, int>{
        'bg': bg,
        'surface': surface,
        'surfaceHigh': surfaceHigh,
        'brand': brand,
        'onBrand': onBrand,
        'textPrimary': textPrimary,
        'textSecondary': textSecondary,
        'statusFree': statusFree,
        'statusBusy': statusBusy,
        'statusEars': statusEars,
        'statusAway': statusAway,
      };
}

/// 现有配色,作为对照组一起渲染 —— 没有基线的对比图没有意义。
const Palette baseline = Palette(
  id: 'baseline',
  name: '余烬(现有基线)',
  source: '现有 app/lib/src/theme/tokens.dart',
  bg: 0xFF121016,
  surface: 0xFF1C1922,
  surfaceHigh: 0xFF26222E,
  brand: 0xFFFF8A5C,
  onBrand: 0xFF1A120C,
  textPrimary: 0xFFF2EEE9,
  textSecondary: 0xFF9A93A3,
  statusFree: 0xFF6FD08C,
  statusBusy: 0xFFE8B45A,
  statusEars: 0xFF6FA8D0,
  statusAway: 0xFF6E6878,
  temperament: '深夜里一炉将熄未熄的炭火:温度不高,但确实还在。',
  weakness: '灰紫底偏中性,除品牌橙外整体缺记忆点;away 的灰紫几乎沉进背景,'
      '「有事先走」在网格里几乎读不出来。',
);

/// 1. 伦勃朗《夜巡》(1642)—— 深橄榄褐底,金褐光从暗处涌出。
const Palette rembrandt = Palette(
  id: 'rembrandt',
  name: '夜巡',
  source: '伦勃朗《夜巡》(1642),阿姆斯特丹国立博物馆',
  bg: 0xFF141109,
  surface: 0xFF1E1A10,
  surfaceHigh: 0xFF2B2417,
  brand: 0xFFEFAE46,
  onBrand: 0xFF1B1204,
  textPrimary: 0xFFF7EDD8,
  textSecondary: 0xFFB6A98D,
  statusFree: 0xFFB9CF73,
  statusBusy: 0xFFE0824D,
  statusEars: 0xFF8FBDDD,
  statusAway: 0xFF8E8371,
  temperament: '画室里最后一盏灯还亮着,人影从褐色的暗处一个个走出来。',
  weakness: '整屏偏黄褐,长时间看容易觉得「旧」甚至「脏」;'
      '品牌金与 busy 橙同属暖色区,主按钮和「在忙」环在余光里会撞。',
);

/// 2. 梵高《罗讷河上的星夜》(1888)—— 钴蓝夜色 + 煌黄灯火。
const Palette vanGogh = Palette(
  id: 'vangogh',
  name: '星夜',
  source: '梵高《罗讷河上的星夜》(1888),奥赛美术馆',
  bg: 0xFF0B1124,
  surface: 0xFF141C33,
  surfaceHigh: 0xFF1F2946,
  brand: 0xFFF5C542,
  onBrand: 0xFF161003,
  textPrimary: 0xFFEEF2FA,
  textSecondary: 0xFFA3B2D0,
  statusFree: 0xFF75D8B5,
  statusBusy: 0xFFF09A5A,
  statusEars: 0xFF81A8E4,
  statusAway: 0xFF757F9E,
  temperament: '河对岸的煤气灯在水里抖成一条金线,天还是蓝的,人还没散。',
  weakness: '蓝底最「冷」,与「炉火」的品牌内核有内在张力;'
      'ears 蓝与 away 灰蓝同处蓝区,且都落在蓝背景上,弱光环境下需靠亮度而非色相区分。',
);

/// 3. 维梅尔《戴珍珠耳环的少女》(1665)—— 深黑背景 + 青金石蓝 + 赭石黄。
const Palette vermeer = Palette(
  id: 'vermeer',
  name: '珍珠',
  source: '维梅尔《戴珍珠耳环的少女》(1665),莫瑞泰斯皇家美术馆',
  bg: 0xFF0A0A0D,
  surface: 0xFF141419,
  surfaceHigh: 0xFF1F1F27,
  brand: 0xFFE9AE4A,
  onBrand: 0xFF181104,
  textPrimary: 0xFFF1EBE1,
  textSecondary: 0xFFA09CA8,
  statusFree: 0xFF80CAAC,
  statusBusy: 0xFFDC7F68,
  statusEars: 0xFF739EE0,
  statusAway: 0xFF7E7A88,
  temperament: '一张脸从纯黑里浮出来,只有耳垂上那一点光是活的。',
  weakness: '背景近乎纯黑,OLED 上省电但会让「炉火围坐」的暖意流失,'
      '偏冷清、偏美术馆;深黑底上白字在夜里反而容易产生光晕(halation)。',
);

/// 4. 自选:亨利·卢梭《沉睡的吉普赛人》(1897)—— 沙漠月夜,狮子守在熟睡者身旁。
///
/// 选它的理由(见报告):主题上它几乎是「守护」的字面图解 —— 一个在路上的人
/// 睡着了,一头狮子站在旁边不走;色彩上它占的是**青绿 + 暖沙**这块前三套都没碰的
/// 地界,而画中那件条纹长袍本身就提供了四个互不相同的色带,天然适合做状态色。
const Palette rousseau = Palette(
  id: 'rousseau',
  name: '狮守',
  source: '亨利·卢梭《沉睡的吉普赛人》(1897),纽约现代艺术博物馆',
  bg: 0xFF0A1417,
  surface: 0xFF121F23,
  surfaceHigh: 0xFF1C2C31,
  brand: 0xFFEFAC66,
  onBrand: 0xFF16110A,
  textPrimary: 0xFFEBF1EF,
  textSecondary: 0xFF9AAFAD,
  statusFree: 0xFF76CC9E,
  statusBusy: 0xFFE08A6E,
  statusEars: 0xFF75A0CC,
  statusAway: 0xFF7C8A90,
  temperament: '月亮很高,狮子不吼也不走,就站在那儿等你睡醒。',
  weakness: '青绿底在低品质屏幕上容易偏「医院绿」;'
      'free 的绿与背景同属冷绿区,状态环在暗处的跳脱度不如暖底方案。',
);

/// 渲染与体检的全集(基线排第一,方便左右对照)。
const List<Palette> allPalettes = <Palette>[
  baseline,
  rembrandt,
  vanGogh,
  vermeer,
  rousseau,
];
