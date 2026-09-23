import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/auth_credential.dart';
import '../auth/auth_verifier.dart';
import 'server_profile.dart';
import 'signaling_client.dart';

/// 「测试连接」的结论。分得细是有意的:
/// 一个打错的口令如果只表现为「进不去房间」,用户永远不知道该改哪儿。
enum ConnectionTestOutcome {
  /// 地址本身就不合法(scheme 错、没主机名……),压根没发起连接
  invalidUrl,

  /// 连不上:域名解析失败 / 端口不通 / TLS 握手失败
  unreachable,

  /// 连上了,但服务端要鉴权而本地没配凭据
  credentialMissing,

  /// 连上了,口令不对(close 4401)
  authFailed,

  /// 连上了,但被限流挡住(close 4429)
  rateLimited,

  /// 连上且鉴权通过(或服务端本来就不鉴权)
  ok,

  /// 连上了但服务端迟迟不回,超时
  timeout,
}

/// 拨测结论对应的**文案语义 key**。
///
/// 为什么不能直接用 [ConnectionTestOutcome]:两者不是一一对应。
/// 同一个 `unreachable` 结论,底下有「域名查不到」「超时」「服务端提前断开」
/// 好几种说法;`credentialMissing` 也分「压根没填」和「填了一半」。
/// 结论是给**代码**判断用的(`isOk` / `needsCredentialFix`),
/// 这个枚举才是给**文案**查表用的。
///
/// 按 `docs/l10n-guide.md`:模型只存语义 key,翻译查表放 UI 层,
/// 不把 `BuildContext` 渗进这个纯网络逻辑文件。
enum ConnectionTestMessage {
  /// 地址本身不合法。`messageArg` = 校验器给出的原因。
  invalidUrl,

  /// 连不上,且能说清是哪种网络故障。详情见 [ConnectionTestResult.networkError]。
  unreachableNetwork,

  /// 连不上这个地址(超时,且从没收到过 challenge)
  unreachableTimeout,

  /// 连不上这个地址(连接直接断了,没有更多信息)
  unreachablePlain,

  /// 握手上了但服务端迟迟不回
  timeoutNoResponse,

  /// 握手上了但服务端提前断开
  disconnectedEarly,

  /// 服务端要鉴权,本地压根没配凭据
  credentialMissingNotSet,

  /// 配了凭据但填得不全(推不出证明)
  credentialIncomplete,

  /// 连上了,这台服务器没开鉴权
  okNoAuth,

  /// 连上了且口令验证通过。占位符取 [ConnectionTestResult.authMode],
  /// 由 UI 层翻译成本地语言 —— 不走 `messageArg`。
  okAuthed,

  /// 能连上,但口令不对
  authFailed,

  /// 被限流挡住
  rateLimited,
}

/// 底层网络故障的**语义 key**。[NetworkErrorKind.other] 之外都能翻译。
enum NetworkErrorKind {
  /// 域名解析失败
  hostLookup,

  /// 端口没开放 / 连接被拒
  refused,

  /// 连接超时
  timedOut,

  /// TLS 证书验证失败
  certificate,

  /// 认不出来的异常 —— 只能把原始文本透给用户,无法翻译。
  /// 详情在 [ConnectionTestResult.messageArg]。
  other,
}

/// 测试结果:结论 + 一句人话 + 服务端广播的可用模式。
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.outcome,
    required this.message,
    required this.messageCode,
    this.messageArg,
    this.networkError,
    this.serverModes = const [],
    this.authRequired = false,
    this.authMode = AuthMode.none,
    this.elapsed,
  });

  final ConnectionTestOutcome outcome;

  /// 直接显示给用户的说明。
  ///
  /// ⚠️ **待迁移的遗留中文**。新代码请改用 [messageCode] + [messageArg]
  /// 在 UI 层查表;这里保留是为了让尚未改造的调用方
  /// (`ui/server_settings_section.dart`)继续编译。
  final String message;

  /// 文案语义 key —— UI 层据此查 ARB,取代 [message]。
  final ConnectionTestMessage messageCode;

  /// 填进 [messageCode] 对应文案占位符的值。
  ///
  /// - [ConnectionTestMessage.invalidUrl] → 地址校验失败的原因
  /// - [ConnectionTestMessage.unreachableNetwork] 且
  ///   [networkError] 为 [NetworkErrorKind.other] → 原始异常文本
  ///
  /// [ConnectionTestMessage.okAuthed] 的占位符不走这里 —— 鉴权模式名
  /// 本身也要翻译,UI 层直接拿 [authMode] 查自己的表,
  /// 别把 `AuthMode.label` 的中文塞进来。
  final String? messageArg;

  /// [messageCode] 为 [ConnectionTestMessage.unreachableNetwork] 时的故障分类。
  final NetworkErrorKind? networkError;

  /// 服务端 challenge 广播的可用鉴权模式(UI 据此裁剪选项)
  final List<String> serverModes;

  final bool authRequired;

  /// 鉴权成功时服务端 welcome 回报的实际模式
  final AuthMode authMode;

  final Duration? elapsed;

  bool get isOk => outcome == ConnectionTestOutcome.ok;

  /// 是否属于「用户得去改点什么」而不是「网络问题」
  bool get needsCredentialFix =>
      outcome == ConnectionTestOutcome.authFailed ||
      outcome == ConnectionTestOutcome.credentialMissing;
}

/// 把底层异常归到一个**可翻译的类别**上。
///
/// 认不出来时落到 [NetworkErrorKind.other] —— 那种情况只能把原始文本
/// 透给用户(见 [rawNetworkErrorText]),没有别的办法:errno 和堆栈
/// 不可能预先翻译。归类逻辑与 [briefNetworkError] 保持一致。
NetworkErrorKind classifyNetworkError(Object e) {
  final text = e.toString();
  if (text.contains('Failed host lookup') || text.contains('nodename')) {
    return NetworkErrorKind.hostLookup;
  }
  if (text.contains('refused') || text.contains('拒绝')) {
    return NetworkErrorKind.refused;
  }
  if (text.contains('timed out') || text.contains('超时')) {
    return NetworkErrorKind.timedOut;
  }
  if (text.contains('CERTIFICATE') || text.contains('HandshakeException')) {
    return NetworkErrorKind.certificate;
  }
  return NetworkErrorKind.other;
}

/// [NetworkErrorKind.other] 时透给用户的原始文本(只取第一行,不带堆栈)。
String rawNetworkErrorText(Object e) => e.toString().split('\n').first;

/// 把底层异常压成一句人话。原始文本里带 errno、地址、堆栈,对用户没有意义。
///
/// ⚠️ **待迁移的遗留中文**。新代码请用 [classifyNetworkError] 拿语义 key,
/// 在 UI 层查表;这里保留是为了让 [ConnectionTestResult.message] 继续可用。
String briefNetworkError(Object e) => switch (classifyNetworkError(e)) {
      NetworkErrorKind.hostLookup => '找不到这个域名',
      NetworkErrorKind.refused => '对方端口没有开放',
      NetworkErrorKind.timedOut => '连接超时',
      NetworkErrorKind.certificate => '证书验证失败(wss 需要有效证书)',
      NetworkErrorKind.other => rawNetworkErrorText(e),
    };

/// 一次性拨测:用**独立的临时连接**验证地址与口令。
///
/// 为什么不复用 App 的常驻连接:那条连接是 P0 预连接,进房靠它省掉一个往返。
/// 拿它去试一个可能是错的口令,轻则打断预连接、重则把失败计数推向 4429,
/// 得不偿失。这里开一条用完即关的短连接,对常驻连接零影响。
class ConnectionTester {
  ConnectionTester({ChannelConnector? connector, this.timeout = const Duration(seconds: 8)})
      : _connector = connector ?? WebSocketChannel.connect;

  final ChannelConnector _connector;
  final Duration timeout;

  Future<ConnectionTestResult> test({
    required String url,
    required AuthCredential credential,
    required String userId,
  }) async {
    final validation = ServerProfile.validateUrl(url);
    if (!validation.isValid) {
      return ConnectionTestResult(
        outcome: ConnectionTestOutcome.invalidUrl,
        message: '地址有问题:${validation.error}',
        messageCode: ConnectionTestMessage.invalidUrl,
        messageArg: validation.error,
      );
    }

    final watch = Stopwatch()..start();
    final done = Completer<ConnectionTestResult>();
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    Timer? timer;
    var sawChallenge = false;
    var modes = const <String>[];
    var authRequired = false;

    void finish(ConnectionTestResult r) {
      if (done.isCompleted) return;
      timer?.cancel();
      sub?.cancel();
      channel?.sink.close();
      done.complete(ConnectionTestResult(
        outcome: r.outcome,
        message: r.message,
        messageCode: r.messageCode,
        messageArg: r.messageArg,
        networkError: r.networkError,
        serverModes: r.serverModes.isEmpty ? modes : r.serverModes,
        authRequired: r.authRequired || authRequired,
        authMode: r.authMode,
        elapsed: watch.elapsed,
      ));
    }

    final WebSocketChannel opened;
    try {
      opened = _connector(Uri.parse(validation.normalized!));
      channel = opened;
    } catch (e) {
      return ConnectionTestResult(
        outcome: ConnectionTestOutcome.unreachable,
        message: '连不上:${briefNetworkError(e)}',
        messageCode: ConnectionTestMessage.unreachableNetwork,
        networkError: classifyNetworkError(e),
        messageArg: rawNetworkErrorText(e),
        elapsed: watch.elapsed,
      );
    }
    // ready 失败(域名解析不了/端口被拒/TLS 谈不拢)是**异步**抛出的:
    // 不接住就会变成未捕获异常,把一次正常的「连不上」升级成崩溃。
    unawaited(opened.ready.then<void>((_) {}, onError: (Object e) {
      finish(ConnectionTestResult(
        outcome: ConnectionTestOutcome.unreachable,
        message: '连不上:${briefNetworkError(e)}',
        messageCode: ConnectionTestMessage.unreachableNetwork,
        networkError: classifyNetworkError(e),
        messageArg: rawNetworkErrorText(e),
      ));
    }));

    timer = Timer(timeout, () {
      finish(ConnectionTestResult(
        outcome: sawChallenge
            ? ConnectionTestOutcome.timeout
            : ConnectionTestOutcome.unreachable,
        message: sawChallenge ? '服务器没有回应(超时)' : '连不上这个地址(超时)',
        messageCode: sawChallenge
            ? ConnectionTestMessage.timeoutNoResponse
            : ConnectionTestMessage.unreachableTimeout,
      ));
    });

    sub = channel.stream.listen(
      (data) async {
        if (data is! String) return;
        final Object? json;
        try {
          json = jsonDecode(data);
        } catch (_) {
          return;
        }
        if (json is! Map<String, dynamic>) return;

        switch (json['t']) {
          case 'challenge':
            sawChallenge = true;
            modes = (json['modes'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false);
            authRequired = json['authRequired'] == true;
            final nonce = json['nonce'] as String?;
            final hello = <String, dynamic>{
              't': 'hello',
              'userId': userId,
              'deviceId': 'conn-test',
              'name': '连接测试',
              'platform': 'test',
            };
            if (authRequired && credential.mode == AuthMode.none) {
              finish(const ConnectionTestResult(
                outcome: ConnectionTestOutcome.credentialMissing,
                message: '服务器要求口令,但这里还没填',
                messageCode: ConnectionTestMessage.credentialMissingNotSet,
              ));
              return;
            }
            if (nonce != null && credential.mode != AuthMode.none) {
              // circle 模式发 v2:先在后台算 verifier(Argon2,不卡 UI),
              // 与正式连接共用同一份缓存 —— 测完连接后真进圈不必再算一遍。
              String? verifier;
              final cid = credential.circleId ?? '';
              if (credential.mode == AuthMode.circle &&
                  cid.isNotEmpty &&
                  credential.passcode.isNotEmpty) {
                final cache = SignalingClient.defaultVerifierCache;
                verifier = cache != null
                    ? await cache.get(cid, credential.passcode)
                    : await deriveAuthVerifierAsync(
                        passcode: credential.passcode, circleId: cid);
                if (done.isCompleted) return;
              }
              final authObj = AuthProof.build(
                credential: credential,
                nonce: nonce,
                userId: userId,
                verifier: verifier,
              );
              if (authObj == null) {
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.credentialMissing,
                  message: '口令还没填完整',
                  messageCode: ConnectionTestMessage.credentialIncomplete,
                ));
                return;
              }
              hello['auth'] = authObj;
            }
            channel?.sink.add(jsonEncode(hello));
          case 'welcome':
            final mode = AuthMode.fromWire(json['authMode'] as String?);
            finish(ConnectionTestResult(
              outcome: ConnectionTestOutcome.ok,
              message: mode == AuthMode.none
                  ? '连上了,这台服务器没开鉴权'
                  : '连上了,口令验证通过(${mode.label})',
              messageCode: mode == AuthMode.none
                  ? ConnectionTestMessage.okNoAuth
                  : ConnectionTestMessage.okAuthed,
              authMode: mode,
            ));
          case 'error':
            switch (json['message']) {
              case 'auth_failed':
              case 'auth_required':
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.authFailed,
                  message: '能连上,但口令不对',
                  messageCode: ConnectionTestMessage.authFailed,
                ));
              case 'rate_limited':
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.rateLimited,
                  message: '试得太频繁,服务器暂时拒绝了(等几分钟再试)',
                  messageCode: ConnectionTestMessage.rateLimited,
                ));
            }
          // 未知 t:忽略,不依赖消息顺序
        }
      },
      onError: (Object e) => finish(ConnectionTestResult(
        outcome: ConnectionTestOutcome.unreachable,
        message: '连不上:${briefNetworkError(e)}',
        messageCode: ConnectionTestMessage.unreachableNetwork,
        networkError: classifyNetworkError(e),
        messageArg: rawNetworkErrorText(e),
      )),
      onDone: () {
        // 没等到结论就断了:用 close code 兜底判断
        final code = channel?.closeCode;
        finish(ConnectionTestResult(
          outcome: switch (code) {
            4401 => ConnectionTestOutcome.authFailed,
            4429 => ConnectionTestOutcome.rateLimited,
            _ => sawChallenge
                ? ConnectionTestOutcome.timeout
                : ConnectionTestOutcome.unreachable,
          },
          message: switch (code) {
            4401 => '能连上,但口令不对',
            4429 => '试得太频繁,服务器暂时拒绝了(等几分钟再试)',
            _ => sawChallenge ? '服务器提前断开了连接' : '连不上这个地址',
          },
          messageCode: switch (code) {
            4401 => ConnectionTestMessage.authFailed,
            4429 => ConnectionTestMessage.rateLimited,
            _ => sawChallenge
                ? ConnectionTestMessage.disconnectedEarly
                : ConnectionTestMessage.unreachablePlain,
          },
        ));
      },
      cancelOnError: true,
    );

    return done.future;
  }
}
