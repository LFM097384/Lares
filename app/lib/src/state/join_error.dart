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

/// 用户能看懂、且长度可控的一句话。
///
/// 写法上守两条:
/// 1. 说**发生了什么**和**能做什么**,不说协议细节;
/// 2. 不出现英文异常类名、不出现堆栈、不出现 URL。
String humanizeJoinError(Object error) {
  // 超时:最常见,且用户完全能理解
  if (error is TimeoutException) {
    return '连了一会儿没连上,网络可能不太稳。等一下再试试?';
  }

  // 域名解析不了 —— 通常是服务器地址填错,或者根本没联网
  if (error is SocketException) {
    final os = error.osError?.errorCode;
    // 11001/-2/-3 是各平台「主机名解析失败」的常见取值
    if (os == 11001 || os == -2 || os == -3 ||
        error.message.contains('Failed host lookup')) {
      return '找不到服务器。检查一下网络,或者服务器地址是不是填错了。';
    }
    return '连不上服务器。可能是网络断了,或者对方暂时不在线。';
  }

  // 证书问题:自建服务器很容易撞到,值得单独说清楚
  if (error is HandshakeException) {
    return '服务器的安全证书有问题,没敢继续连。如果是自建服务器,检查一下证书配置。';
  }

  final text = error.toString();

  // 鉴权失败。服务端用 4401 关闭连接(见 server/src/index.js)
  //
  // 文案刻意说「要口令」而不是「口令不对」:最常见的触发场景是
  // 刚通过邀请链接加了个圈子 —— 链接里**不带口令**(那是有意的,
  // 口令进链接等于把 E2EE 密钥也发出去),所以本地压根没存过口令。
  // 这时候说「口令不对」会让用户去改一个根本不存在的东西。
  if (text.contains('4401') || text.contains('auth_failed') ||
      text.contains('auth_required')) {
    return '这个圈子要口令才能进。问一下拉你进来的人,然后在设置里填上。';
  }

  // 限流:连续输错口令会被临时封
  if (text.contains('4429') || text.contains('rate')) {
    return '试得太频繁,先歇 5 分钟再来。';
  }

  // 服务端没配 LiveKit,或者媒体服务没起来
  if (text.contains('rtc_not_configured') || text.contains('token')) {
    return '服务器还没准备好语音服务。如果是自己搭的,检查一下 LiveKit 配置。';
  }

  // 兜底。**不拼接 $e** —— 那正是当初出事的写法。
  return '没能进去。检查一下网络,或者稍后再试。';
}
