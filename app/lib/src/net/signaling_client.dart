import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/auth_credential.dart';

/// 鉴权阶段:UI 可据此区分「网络抖动」与「口令错了」。
enum AuthPhase {
  /// 尚未连接 / 未开始握手
  idle,

  /// 已连上,等服务端下发 challenge
  awaitingChallenge,

  /// 已按 challenge 算出证明并发出 hello,等 welcome
  proving,

  /// welcome 到手,本连接已鉴权(含 none 模式)
  authenticated,

  /// 口令错/nonce 过期/模式不被接受(close 4401)。**不自动无限重试**。
  failed,

  /// 服务端按 IP 限流(close 4429)。硬退避。
  rateLimited,

  /// 缺凭据:服务器要求鉴权,但本地没填。等用户输入,不去撞墙。
  credentialRequired,
}

/// 鉴权状态快照(给 UI 用的类型化状态,不是一条泛泛的「断开了」)。
@immutable
class AuthStatus {
  const AuthStatus({
    required this.phase,
    this.mode = AuthMode.none,
    this.serverModes = const [],
    this.authRequired = false,
    this.message,
  });

  static const initial = AuthStatus(phase: AuthPhase.idle);

  final AuthPhase phase;

  /// 服务端 welcome 回报的实际鉴权模式
  final AuthMode mode;

  /// 服务端 challenge 广播它接受哪些模式;UI 据此裁剪选项
  final List<String> serverModes;

  /// 服务端是否要求鉴权
  final bool authRequired;

  /// 原始错误码(auth_required / auth_failed / rate_limited / auth_scope ...)
  final String? message;

  bool get isAuthenticated => phase == AuthPhase.authenticated;

  /// 需要用户介入(输口令 / 改设置)才能恢复,重连帮不上忙
  bool get needsUserAction =>
      phase == AuthPhase.failed || phase == AuthPhase.credentialRequired;

  /// 给人看的一句话
  String get label => switch (phase) {
        AuthPhase.idle => '未连接',
        AuthPhase.awaitingChallenge => '正在握手…',
        AuthPhase.proving => '正在验证口令…',
        AuthPhase.authenticated =>
          mode == AuthMode.none ? '已连接(服务器未开鉴权)' : '已验证(${mode.label})',
        AuthPhase.failed => '口令不对,进不去',
        AuthPhase.rateLimited => '尝试太频繁,服务器暂时拒绝了',
        AuthPhase.credentialRequired => '这台服务器需要口令',
      };

  AuthStatus copyWith({
    AuthPhase? phase,
    AuthMode? mode,
    List<String>? serverModes,
    bool? authRequired,
    String? message,
  }) =>
      AuthStatus(
        phase: phase ?? this.phase,
        mode: mode ?? this.mode,
        serverModes: serverModes ?? this.serverModes,
        authRequired: authRequired ?? this.authRequired,
        message: message ?? this.message,
      );
}

/// 建链工厂:默认走真实网络,测试注入假通道(纯内存,不开端口)。
typedef ChannelConnector = WebSocketChannel Function(Uri uri);

/// 取当前凭据。做成回调而不是直接依赖 SettingsStore:
/// 一来避免单测被 shared_preferences 的插件通道拖下水,
/// 二来保证**每条 challenge 到达时现取**,用户改完口令下次重连自然生效。
typedef CredentialSource = AuthCredential Function();

/// presence 信令客户端:与 server/ 的 JSON-over-WebSocket 协议对话。
///
/// 预连接策略(设计.md §8.3-P0):App 启动即 connect,
/// 连上后先收 challenge → 算证明 → hello → welcome,整套握手在启动空闲期跑完;
/// 进房时只需 join -> token 一个往返,保住「点击到听到声音 ≤1.5s」。
///
/// 鉴权(服务端 commit c36e71d):HMAC 挑战应答。nonce 一次性、60s 过期,
/// 因此**每条连接都要用当次 challenge 的 nonce 重新推导证明**,
/// 绝不能缓存证明去重放 —— 那是这套东西最容易写错的地方。
class SignalingClient {
  SignalingClient({
    required String url,
    CredentialSource? credentials,
    ChannelConnector? connector,
    this.userId,
  })  : _url = url,
        _credentials = credentials,
        _connector = connector ?? WebSocketChannel.connect;

  String _url;

  /// 当前信令地址。
  String get url => _url;

  /// 换一台服务器。
  ///
  /// 存在的理由是跨服务器的「我有空」:有人在**别的**服务器上来找我,
  /// 主连接必须切过去才能进那个房间。在此之前换服务器要重启 App。
  ///
  /// 复用 [reconnectWithNewCredential] 的干净重连 —— 它已经处理了
  /// 退避归零、4401 抑制清除、nonce 作废这些事。换地址与换口令在
  /// 「必须从头握手」这一点上是同一回事,不该各写一套。
  set url(String value) {
    if (_url == value) return;
    _url = value;
    if (_disposed) return;
    reconnectWithNewCredential();
  }

  /// 凭据来源;为空视作 none 模式
  CredentialSource? _credentials;

  final ChannelConnector _connector;

  /// 本机用户 id(HMAC 消息体的一部分)。hello() 调用后会被刷新。
  String? userId;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  /// 鉴权状态:UI 可直接 listen,不必从 messages 流里挑
  final ValueNotifier<AuthStatus> authStatus =
      ValueNotifier<AuthStatus>(AuthStatus.initial);

  bool _connected = false;
  bool _disposed = false;
  int _retrySeconds = 1;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _challengeTimer;

  /// 握手是否已完成(welcome 到手)。未完成时除 hello 外一律排队。
  bool _handshakeDone = false;

  /// 本连接收到的 nonce。每次新连接清零,杜绝跨连接复用。
  String? _nonce;

  /// 本连接的 challenge 是否已有结论(收到了 / 或等超时判定为老服务器)。
  /// 在此之前**任何** hello 都不许发出去 —— 抢跑就没有 nonce 可用。
  bool _challengeSettled = false;

  /// 身份信息(不是整条 hello 报文):重连时用**新 nonce** 重新组装,
  /// 而不是把旧 hello(内含旧证明)原样重放 —— 重放必定 auth_failed。
  Map<String, dynamic>? _identity;

  /// circle 模式下要证明的圈子;join 前由上层设定
  String? _authCircleId;

  /// 4401 后已经重试过一次没有(nonce 可能只是睡眠期间正常过期,值得给一次机会;
  /// 但绝不无限重试 —— 服务端 5 分钟 10 次失败就封 IP)
  bool _retriedAfterAuthFailure = false;

  /// 未连接/未握手期间的消息队列,握手完成后按序补发
  final List<Map<String, dynamic>> _outbox = [];

  /// 等服务端 challenge 的最长时间。超时说明对方是不带鉴权的老版本服务器,
  /// 直接发裸 hello 兼容回去(向后兼容,别把老部署逼死)。
  static const challengeTimeout = Duration(seconds: 3);

  /// 4429 硬退避起步值(服务端封禁窗口是 5 分钟)
  static const rateLimitBackoff = Duration(seconds: 60);

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  bool get isConnected => _connected;

  /// 握手完成(可以正常收发业务消息)
  bool get isReady => _connected && _handshakeDone;

  /// 等到握手完成(或超时)。返回是否成功。
  ///
  /// 用途:换服务器之后要等新连接握完手才能进房 ——
  /// 握手未完成时业务消息会被排队,而排队期间若再次重连,那条消息就丢了。
  ///
  /// 实现上轮询 [isReady] 而不是加一个 Completer:重连可能发生任意多次,
  /// 每次都要把 Completer 重建/作废,状态机会多出一堆边界;
  /// 而这里等的是「最终就绪」,轮询足够且不会漏掉中间的反复。
  Future<bool> waitHandshake(Duration timeout) async {
    if (isReady) return true;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (isReady) return true;
    }
    return false;
  }

  AuthStatus get auth => authStatus.value;

  /// circle 模式要证明的圈子。进房前设好,变化时会重连换证明。
  String? get authCircleId => _authCircleId;

  set authCircleId(String? value) {
    if (_authCircleId == value) return;
    _authCircleId = value;
    // circle 模式下换圈 = 换密钥,必须重新握手;其它模式无所谓
    if (_credentialNow().mode == AuthMode.circle) reconnectWithNewCredential();
  }

  AuthCredential _credentialNow() {
    final src = _credentials;
    final base = src == null ? AuthCredential.none : src();
    if (base.mode != AuthMode.circle) return base;

    // 只在调用方没指定圈子时兜底补上 authCircleId。
    //
    // ⚠️ 不要在这里「强制改成 authCircleId」—— copyWith 只换 id 不换口令,
    // 结果会是「拿 A 圈的口令声称要进 B 圈」,比原来更糟。
    // 凭据与圈子必须**成对**取,那是凭据来源(main.dart 的回调)的职责。
    return base.circleId == null
        ? base.copyWith(circleId: _authCircleId)
        : base;
  }

  /// 换凭据来源(设置页改完口令后调用),并立即带新凭据重连。
  void setCredentialSource(CredentialSource? source) {
    _credentials = source;
    reconnectWithNewCredential();
  }

  /// 凭据变了:干净地断开重连,用新凭据重新握手。
  ///
  /// 注意要清掉退避与 4401 抑制 —— 用户刚改了口令,这是一次全新的尝试,
  /// 不该继承上一次失败的惩罚。
  void reconnectWithNewCredential() {
    if (_disposed) return;
    _retrySeconds = 1;
    _retriedAfterAuthFailure = false;
    _closeChannel();
    _connected = false;
    _handshakeDone = false;
    _nonce = null;
    _challengeSettled = false;
    _setAuth(const AuthStatus(phase: AuthPhase.idle));
    connect();
  }

  /// 建立(或重建)长连接。重复调用安全。
  void connect() {
    if (_disposed || _connected) return;
    _reconnectTimer?.cancel();
    // 缺凭据就别连:白撞一次只会把服务端的失败计数往上推,离 4429 更近
    final cred = _credentialNow();
    if (cred.mode != AuthMode.none && !cred.isComplete) {
      _setAuth(auth.copyWith(
        phase: AuthPhase.credentialRequired,
        message: 'auth_required',
      ));
      return;
    }
    final WebSocketChannel channel;
    try {
      channel = _connector(Uri.parse(url));
      _channel = channel;
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    // ready 的失败是**异步**抛出的(域名解析不了/端口被拒/TLS 谈不拢)。
    // 不显式接住就会冒泡成未捕获异常;这里咽掉,真正的处理交给 onDone/onError。
    channel.ready.then<void>((_) {}, onError: (Object _) {});
    _sub = _channel!.stream.listen(
      _onData,
      onError: (_) => _onDisconnected(),
      onDone: _onDisconnected,
      cancelOnError: true,
    );
    _connected = true;
    _handshakeDone = false;
    _nonce = null;
    _challengeSettled = false;
    _setAuth(auth.copyWith(phase: AuthPhase.awaitingChallenge, message: null));

    // 关键:**什么都先不发**。等 challenge 到了,用当次 nonce 算证明再 hello。
    // 老服务器不发 challenge,超时后按无鉴权发裸 hello。
    _challengeTimer?.cancel();
    _challengeTimer = Timer(challengeTimeout, _onChallengeTimeout);
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    final Object? json;
    try {
      json = jsonDecode(data);
    } catch (_) {
      return; // 忽略坏包
    }
    if (json is! Map<String, dynamic>) return;

    // 协议纪律:未知的 t 一律当作「以后可能有用的扩展」原样放行,
    // 既不报错也不依赖到达顺序(服务端加 challenge 时老测试没挂,就是靠这条)。
    switch (json['t']) {
      case 'pong':
        _onPong();
        return; // 心跳回包不外抛
      case 'challenge':
        _onChallenge(json);
        return;
      case 'welcome':
        _onWelcome(json);
      case 'error':
        _onProtocolError(json);
    }
    _messages.add(json);
  }

  void _onChallenge(Map<String, dynamic> msg) {
    _challengeTimer?.cancel();
    final nonce = msg['nonce'] as String?;
    final modes = (msg['modes'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final required = msg['authRequired'] == true;
    _nonce = AuthProof.isValidNonce(nonce) ? nonce : null;
    _challengeSettled = true;
    _setAuth(auth.copyWith(
      phase: AuthPhase.proving,
      serverModes: modes,
      authRequired: required,
      message: null,
    ));
    // challenge 本身也抛给上层(设置页的「测试连接」要看 modes)
    _messages.add(msg);
    _sendHelloWithProof();
  }

  /// 没等到 challenge:按老协议裸发 hello(向后兼容老服务器)
  void _onChallengeTimeout() {
    if (!_connected || _handshakeDone) return;
    _nonce = null;
    _challengeSettled = true;
    _sendHelloWithProof();
  }

  /// 用**当次** nonce 现算证明并发 hello。这是全局唯一的 hello 发出口。
  void _sendHelloWithProof() {
    final identity = _identity;
    if (identity == null) return; // 上层还没调 hello();等它调时会走同一条路
    final msg = Map<String, dynamic>.from(identity);
    final nonce = _nonce;
    final cred = _credentialNow();

    if (nonce != null && cred.mode != AuthMode.none) {
      final authObj = AuthProof.build(
        credential: cred,
        nonce: nonce,
        userId: (msg['userId'] as String?) ?? userId ?? '',
      );
      if (authObj == null) {
        // 凭据不全:停在这儿等用户填,别发一个注定失败的 hello
        _setAuth(auth.copyWith(
          phase: AuthPhase.credentialRequired,
          message: 'auth_required',
        ));
        return;
      }
      msg['auth'] = authObj;
    }
    _rawSend(msg);
  }

  void _onWelcome(Map<String, dynamic> msg) {
    _handshakeDone = true;
    _retrySeconds = 1;
    _retriedAfterAuthFailure = false;
    _setAuth(auth.copyWith(
      phase: AuthPhase.authenticated,
      mode: AuthMode.fromWire(msg['authMode'] as String?),
      message: null,
    ));
    // 握手完成才放行排队消息:提前发会撞 say_hello_first / auth_scope
    _flushOutbox();
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _pingSentAt = DateTime.now();
      _rawSend({'t': 'ping'});
    });
    // 立刻先测一次,别等 20 秒 —— 选主机时要用这个值,
    // 刚连上就得有个数,哪怕不准也好过「未知」。
    _pingSentAt = DateTime.now();
    _rawSend({'t': 'ping'});
  }

  DateTime? _pingSentAt;

  /// 到信令服务器的往返延迟(毫秒)。-1 = 还没测到。
  ///
  /// 用途:多人直连时选主机(`host_election.dart`)。
  /// 这不是真实的点对点延迟 —— 那要先建 N×(N-1)/2 条连接才测得到,
  /// 而建连接正是想避免的。到服务器的往返是个强相关近似:
  /// 网络差的人到哪儿都慢。
  ///
  /// 复用既有的 20 秒心跳,**零额外开销**。
  int latencyMs = -1;

  void _onPong() {
    final sent = _pingSentAt;
    if (sent == null) return;
    _pingSentAt = null;
    final ms = DateTime.now().difference(sent).inMilliseconds;
    // 断线重连期间可能收到迟到的 pong,那个往返包含了重连耗时,
    // 不代表网络质量。给一个上限,超过就当没测到。
    if (ms < 0 || ms > 10000) return;
    latencyMs = ms;
  }

  /// 服务端 error 报文。注意 auth_scope / say_hello_first **不关连接**,
  /// 是单条消息被拒,属于可恢复错误,绝不能当成掉线去触发重连。
  void _onProtocolError(Map<String, dynamic> msg) {
    switch (msg['message']) {
      case 'auth_required':
      case 'auth_failed':
        _setAuth(auth.copyWith(
          phase: AuthPhase.failed,
          message: msg['message'] as String?,
        ));
      case 'rate_limited':
        _setAuth(auth.copyWith(
          phase: AuthPhase.rateLimited,
          message: 'rate_limited',
        ));
      case 'auth_scope':
      case 'say_hello_first':
        // 连接还活着,什么都不做:交给上层按业务处理
        break;
    }
  }

  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(_outbox);
    _outbox.clear();
    for (final msg in pending) {
      _rawSend(msg);
    }
  }

  void _onDisconnected() {
    if (!_connected) return;
    _connected = false;
    _handshakeDone = false;
    _nonce = null;
    _challengeSettled = false;
    _pingTimer?.cancel();
    _challengeTimer?.cancel();
    _sub?.cancel();

    // close code 决定重连策略:4401 是「口令错」(重连无用),
    // 4429 是「被限流」(必须硬退避),其余才是普通抖动。
    final code = _channel?.closeCode;
    _messages.add({'t': '_disconnected', 'closeCode': code});

    if (code == 4401) {
      _onAuthRejected();
      return;
    }
    if (code == 4429) {
      _setAuth(auth.copyWith(
        phase: AuthPhase.rateLimited,
        message: 'rate_limited',
      ));
      _messages.add({'t': '_rate_limited'});
      // 硬退避:服务端封禁窗口 5 分钟,这里从 60s 起步再指数放大
      _retrySeconds = rateLimitBackoff.inSeconds;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(rateLimitBackoff, connect);
      return;
    }
    _scheduleReconnect();
  }

  /// 4401:鉴权被拒。
  ///
  /// 给**恰好一次**重试机会 —— 设备休眠时 nonce 可能正常过期,
  /// 此时重连拿新 nonce 就能成。但第二次还失败就基本是口令错了,
  /// 立刻停止重连并把状态抛给 UI 让用户去改,否则 5 分钟 10 次必然撞上 4429。
  void _onAuthRejected() {
    if (!_retriedAfterAuthFailure) {
      _retriedAfterAuthFailure = true;
      _setAuth(auth.copyWith(phase: AuthPhase.proving, message: 'auth_failed'));
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 1), connect);
      return;
    }
    _setAuth(auth.copyWith(phase: AuthPhase.failed, message: 'auth_failed'));
    _messages.add({'t': '_auth_failed', 'message': 'auth_failed'});
    // 到此为止:不排重连定时器。等用户改口令后 reconnectWithNewCredential() 再来。
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // 指数退避,封顶 16s
    _reconnectTimer = Timer(Duration(seconds: _retrySeconds), connect);
    _retrySeconds = (_retrySeconds * 2).clamp(1, 16);
  }

  void _setAuth(AuthStatus next) {
    if (_disposed) return;
    authStatus.value = next;
  }

  void _rawSend(Map<String, dynamic> msg) => _channel?.sink.add(jsonEncode(msg));

  void _closeChannel() {
    _pingTimer?.cancel();
    _challengeTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void send(Map<String, dynamic> msg) {
    if (msg['t'] == 'hello') {
      // hello 只记身份,证明留到 challenge 到手时现算
      _identity = msg;
      userId = (msg['userId'] as String?) ?? userId;
      if (!_connected) {
        connect(); // 连上并等到 challenge 后会自动补发
      } else if (_challengeSettled) {
        // challenge 已有结论:现在算证明发得出去。
        // 若尚未结论,等 _onChallenge/_onChallengeTimeout 来触发,绝不抢跑。
        _sendHelloWithProof();
      }
      return;
    }
    if (!isReady) {
      _outbox.add(msg);
      connect(); // 懒连接:发送时若未连接则先连,握手完成后补发
      return;
    }
    _rawSend(msg);
  }

  void hello({
    required String userId,
    required String deviceId,
    required String name,
    required String platform,
  }) =>
      send({
        't': 'hello',
        'userId': userId,
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
      });

  void join(String circleId) => send({'t': 'join', 'circleId': circleId});

  /// P0 预热:提前为圈子备好 RTC token
  void prefetchToken(String circleId) =>
      send({'t': 'token_prefetch', 'circleId': circleId});

  void leave() => send({'t': 'leave'});

  void setStatus(String status) => send({'t': 'status', 'status': status});

  /// 挂起「我有空」,对这几个圈子可见。服务端只会接受你有权进的那些。
  void setAvailable(List<String> circleIds) =>
      send({'t': 'available', 'circleIds': circleIds});

  /// 收回「我有空」
  void clearAvailable() => send({'t': 'unavailable'});

  /// 去找某个挂着的人。不给 circleId 时服务端取双方都可见的第一个。
  /// 不给 circleId 时,服务端取双方都可见的第一个圈子。
  void reach(String userId, {String? circleId}) {
    final msg = <String, dynamic>{'t': 'reach', 'userId': userId};
    if (circleId != null) msg['circleId'] = circleId;
    send(msg);
  }

  /// 把点对点连接码转交给同圈的某个人。
  ///
  /// 服务器在这条路径上**只当邮差**:不解析、不存储,只检查「同圈」再转发。
  /// 媒体流随后在两台设备之间直接走,完全不经过服务器。
  ///
  /// 这是「用服务器交换信令」那条路。另一条是用户自己复制连接码
  /// (零服务器),两条路产出的连接码格式完全一样。
  void sendP2PSignal(String toUserId, String payload) =>
      send({'t': 'p2p_signal', 'to': toUserId, 'payload': payload});

  /// 测试注入:模拟收到一条服务器消息
  // ignore: use_setters_to_change_properties
  void testInject(Map<String, dynamic> msg) => _messages.add(msg);

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _challengeTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    authStatus.dispose();
    await _messages.close();
  }
}
