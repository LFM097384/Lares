import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/auth_credential.dart';
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

/// 测试结果:结论 + 一句人话 + 服务端广播的可用模式。
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.outcome,
    required this.message,
    this.serverModes = const [],
    this.authRequired = false,
    this.authMode = AuthMode.none,
    this.elapsed,
  });

  final ConnectionTestOutcome outcome;

  /// 直接显示给用户的说明
  final String message;

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
        serverModes: r.serverModes.isEmpty ? modes : r.serverModes,
        authRequired: r.authRequired || authRequired,
        authMode: r.authMode,
        elapsed: watch.elapsed,
      ));
    }

    try {
      channel = _connector(Uri.parse(validation.normalized!));
    } catch (e) {
      return ConnectionTestResult(
        outcome: ConnectionTestOutcome.unreachable,
        message: '连不上:$e',
        elapsed: watch.elapsed,
      );
    }

    timer = Timer(timeout, () {
      finish(ConnectionTestResult(
        outcome: sawChallenge
            ? ConnectionTestOutcome.timeout
            : ConnectionTestOutcome.unreachable,
        message: sawChallenge ? '服务器没有回应(超时)' : '连不上这个地址(超时)',
      ));
    });

    sub = channel.stream.listen(
      (data) {
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
              ));
              return;
            }
            if (nonce != null && credential.mode != AuthMode.none) {
              final authObj = AuthProof.build(
                credential: credential,
                nonce: nonce,
                userId: userId,
              );
              if (authObj == null) {
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.credentialMissing,
                  message: '口令还没填完整',
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
              authMode: mode,
            ));
          case 'error':
            switch (json['message']) {
              case 'auth_failed':
              case 'auth_required':
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.authFailed,
                  message: '能连上,但口令不对',
                ));
              case 'rate_limited':
                finish(const ConnectionTestResult(
                  outcome: ConnectionTestOutcome.rateLimited,
                  message: '试得太频繁,服务器暂时拒绝了(等几分钟再试)',
                ));
            }
          // 未知 t:忽略,不依赖消息顺序
        }
      },
      onError: (Object e) => finish(ConnectionTestResult(
        outcome: ConnectionTestOutcome.unreachable,
        message: '连不上:$e',
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
        ));
      },
      cancelOnError: true,
    );

    return done.future;
  }
}
