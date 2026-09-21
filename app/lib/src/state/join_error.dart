/// 把进房失败的异常翻译成人话。
///
/// 为什么要单独一个文件:这是纯函数,可以直接在 `flutter test` 里穷举各种
/// 异常形态,不需要真的连一次失败的网络。
///
/// 纪律:**用户永远不该看到 `toString()` 的原始异常。**
/// 曾经的实现是 `errorMessage = '进房失败:$e'`,于是屏幕上出现过
/// 「进房失败:ClientException with SocketException: Connection...」——
/// 既看不懂,又因为长度不可控把布局撑爆(右上角 2014px 溢出警示条)。
///
/// 原始异常不是不要,而是**去它该去的地方**:`debugPrint` 到日志。
library;

import 'dart:async';
import 'dart:io';

/// 进房失败的**种类**。
///
/// 为什么要有它:`humanizeJoinError` 产出的是给人看的散文,
/// UI 想据此决定「该不该显示口令输入框」就只能去匹配那句话的文字 ——
/// 那是本地化的死路(换成英文界面立刻失效),也经不起一次文案润色。
///
/// 所以把「判定」与「措辞」拆成两个纯函数,共用同一套判据:
/// [classifyJoinError] 回答**是什么**,[humanizeJoinError] 回答**怎么说**。
/// 两者都是纯函数,可以在 `flutter test` 里穷举,不必真的连一次失败的网络。
enum JoinErrorKind {
  /// 要口令 / 口令不对(服务端 close 4401)。**只有这一种该弹口令输入框。**
  needsPasscode,

  /// 试得太频繁被临时封(4429)。此时再填口令也没用,得先等。
  rateLimited,

  /// 服务端没配 LiveKit 之类:媒体服务没起来。填口令无济于事。
  serverNotReady,

  /// 网络层问题:超时、DNS、证书。
  network,

  /// 其余一概归此。
  unknown,
}

/// 网络类失败的细分。只在本文件内部用来决定措辞,不对外暴露 ——
/// 对调用方来说「超时」与「证书错」都是 [JoinErrorKind.network],
/// 都不该弹口令框,这才是它们需要知道的那一位信息。
enum _NetworkFlavor { timeout, hostLookup, refused, certificate }

/// 判定进房失败属于哪一类。
///
/// 这是**唯一**的判据来源:[humanizeJoinError] 也走它,
/// 所以「判定」和「措辞」不可能各自漂移 —— 分成两套 if 链写过一版,
/// 那正是「文案改了但 UI 判断没跟上」这类 bug 的温床。
JoinErrorKind classifyJoinError(Object error) => _classify(error).$1;

/// 内部判定:返回种类 + 网络细分(仅 network 时非空)。
(JoinErrorKind, _NetworkFlavor?) _classify(Object error) {
  // 超时:最常见,且用户完全能理解
  if (error is TimeoutException) {
    return (JoinErrorKind.network, _NetworkFlavor.timeout);
  }

  // 域名解析不了 —— 通常是服务器地址填错,或者根本没联网
  if (error is SocketException) {
    final os = error.osError?.errorCode;
    // 11001/-2/-3 是各平台「主机名解析失败」的常见取值
    final lookup = os == 11001 ||
        os == -2 ||
        os == -3 ||
        error.message.contains('Failed host lookup');
    return (
      JoinErrorKind.network,
      lookup ? _NetworkFlavor.hostLookup : _NetworkFlavor.refused,
    );
  }

  // 证书问题:自建服务器很容易撞到,值得单独说清楚
  if (error is HandshakeException) {
    return (JoinErrorKind.network, _NetworkFlavor.certificate);
  }

  final text = error.toString();

  // 鉴权失败。服务端用 4401 关闭连接(见 server/src/index.js)
  if (text.contains('4401') ||
      text.contains('auth_failed') ||
      text.contains('auth_required')) {
    return (JoinErrorKind.needsPasscode, null);
  }

  // 限流:连续输错口令会被临时封
  if (text.contains('4429') || text.contains('rate')) {
    return (JoinErrorKind.rateLimited, null);
  }

  // 媒体流在房间里断了,且用缓存 token 也没能接回来。
  //
  // 归到 network/refused 而不是新造一种:对用户而言这就是「连不上了」,
  // 而那句现成的文案(网络断了 / 对方暂时不在线)说的正是这件事。
  // 少一条文案就少一次翻译,也少一个会与分类漂移的地方。
  //
  // ⚠️ 必须排在下面 rtc_not_configured 那条之前 —— 那条用 contains
  // 匹配,'rtc_dropped' 不含它,但顺序写反了以后加规则就容易互相吃掉。
  if (text.contains('rtc_dropped')) {
    return (JoinErrorKind.network, _NetworkFlavor.refused);
  }

  // 服务端没配 LiveKit,或者媒体服务没起来
  if (text.contains('rtc_not_configured') || text.contains('token')) {
    return (JoinErrorKind.serverNotReady, null);
  }

  return (JoinErrorKind.unknown, null);
}

// ── 文案常量 ──
//
// 抽成常量不是为了复用,而是为了让下面的 [kindOfJoinMessage] 能做**精确**
// 反查。否则那个函数就得去猜句子里有没有「口令」二字 —— 那种写法会在
// 第一次润色文案时悄悄失灵,而失灵的表现是「该弹的口令框不弹了」。

const String _msgTimeout = '连了一会儿没连上,网络可能不太稳。等一下再试试?';
const String _msgHostLookup = '找不到服务器。检查一下网络,或者服务器地址是不是填错了。';
const String _msgRefused = '连不上服务器。可能是网络断了,或者对方暂时不在线。';
const String _msgCertificate = '服务器的安全证书有问题,没敢继续连。如果是自建服务器,检查一下证书配置。';

/// 文案刻意说「要口令」而不是「口令不对」:最常见的触发场景是刚通过邀请链接
/// 加了个圈子 —— 链接里**不带口令**(那是有意的,口令进链接等于把 E2EE
/// 密钥也发出去),所以本地压根没存过口令。说「不对」会让用户去改一个
/// 根本不存在的东西。
///
/// 末句说「在下面填上」而不是「在设置里填上」:房内现在就有补填入口。
const String _msgNeedsPasscode = '这个圈子要口令才能进。问一下拉你进来的人,然后在下面填上。';
const String _msgRateLimited = '试得太频繁,先歇 5 分钟再来。';
const String _msgServerNotReady = '服务器还没准备好语音服务。如果是自己搭的,检查一下 LiveKit 配置。';
const String _msgUnknown = '没能进去。检查一下网络,或者稍后再试。';

/// 用户能看懂、且长度可控的一句话。
///
/// 写法上守两条:
/// 1. 说**发生了什么**和**能做什么**,不说协议细节;
/// 2. 不出现英文异常类名、不出现堆栈、不出现 URL。
String humanizeJoinError(Object error) {
  final (kind, flavor) = _classify(error);
  return switch (kind) {
    JoinErrorKind.network => switch (flavor!) {
        _NetworkFlavor.timeout => _msgTimeout,
        _NetworkFlavor.hostLookup => _msgHostLookup,
        _NetworkFlavor.refused => _msgRefused,
        _NetworkFlavor.certificate => _msgCertificate,
      },
    JoinErrorKind.needsPasscode => _msgNeedsPasscode,
    JoinErrorKind.rateLimited => _msgRateLimited,
    JoinErrorKind.serverNotReady => _msgServerNotReady,
    // 兜底。**不拼接 $e** —— 那正是当初出事的写法。
    JoinErrorKind.unknown => _msgUnknown,
  };
}

/// 从[humanizeJoinError] 产出的句子反查它的种类。
///
/// ## 为什么需要「反查」这么别扭的东西
///
/// `RoomController` 的失败出口 `_failJoin` 只记下了humanize 之后的句子,
/// 没有留下种类。而那个函数是刚修好「卡死在正在进去…」那个 bug 的地方,
/// 已有测试覆盖,不宜再动 —— 所以改为在 `errorMessage` 的赋值处反查,
/// 既拿到了种类,又一个字都不用改那条失败路径。
///
/// 精确相等匹配(而非包含匹配):句子是上面那组常量之一,
/// 对不上就老实返回 null,绝不猜。别处直接赋的自定义文案
/// (跨服务器失败、敲门超时)就会落到 null,而它们本来也不该弹口令框。
JoinErrorKind? kindOfJoinMessage(String? message) => switch (message) {
      _msgTimeout || _msgHostLookup || _msgRefused || _msgCertificate =>
        JoinErrorKind.network,
      _msgNeedsPasscode => JoinErrorKind.needsPasscode,
      _msgRateLimited => JoinErrorKind.rateLimited,
      _msgServerNotReady => JoinErrorKind.serverNotReady,
      _msgUnknown => JoinErrorKind.unknown,
      _ => null,
    };
