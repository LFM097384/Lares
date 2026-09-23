import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/auth/auth_verifier.dart';
import 'package:lares_app/src/net/signaling_client.dart';
// stream_channel 是 web_socket_channel 的传递依赖,这里只为实现假通道用它的 mixin;
// 不动 pubspec(该文件由他人维护)。
// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 纯内存的假 WebSocket 通道:不开端口、不碰网络,可被 fake_async 完全驱动。
class FakeChannel extends StreamChannelMixin implements WebSocketChannel {
  FakeChannel();

  final _incoming = StreamController<dynamic>(); // 服务端 -> 客户端
  final List<String> sent = []; // 客户端 -> 服务端(已编码)

  int? _closeCode;
  String? _closeReason;
  bool closedByClient = false;

  /// 客户端发出的报文,解码后按序排列
  List<Map<String, dynamic>> get sentJson => [
        for (final s in sent) jsonDecode(s) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> sentOfType(String t) =>
      [for (final m in sentJson) if (m['t'] == t) m];

  /// 模拟服务端下发一条报文
  void serverSend(Map<String, dynamic> msg) {
    if (_incoming.isClosed) return;
    _incoming.add(jsonEncode(msg));
  }

  /// 模拟服务端带 close code 关断
  void serverClose(int code, [String reason = '']) {
    _closeCode = code;
    _closeReason = reason;
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._ch);

  final FakeChannel _ch;

  @override
  void add(dynamic data) {
    if (_ch.closedByClient) return;
    _ch.sent.add(data as String);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _ch.closedByClient = true;
    if (!_ch._incoming.isClosed) await _ch._incoming.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done => _ch._incoming.done;
}

/// 造一个连接工厂:每次 connect 产出一条新的假通道并记录下来,
/// 便于断言「第 N 次连接发了什么」。
class FakeTransport {
  final List<FakeChannel> channels = [];

  FakeChannel get last => channels.last;

  WebSocketChannel connect(Uri uri) {
    final ch = FakeChannel();
    channels.add(ch);
    return ch;
  }
}

const _userId = 'u_liu';
const _nonceA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _nonceB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, dynamic> challenge(String nonce,
        {List<String> modes = const ['token', 'circle'],
        bool authRequired = true}) =>
    {
      't': 'challenge',
      'nonce': nonce,
      'modes': modes,
      'authRequired': authRequired,
    };

SignalingClient makeClient(
  FakeTransport transport, {
  AuthCredential credential = const AuthCredential(
      mode: AuthMode.token, token: 'shared-token'),
}) =>
    SignalingClient(
      url: 'wss://rtc.example.com:8444/ws',
      connector: transport.connect,
      credentials: () => credential,
      userId: _userId,
    );

void sayHello(SignalingClient c) => c.hello(
      userId: _userId,
      deviceId: 'd1',
      name: '刘',
      platform: 'windows',
    );

void main() {
  group('挑战应答握手', () {
    test('连上后先等 challenge,不抢跑发 hello', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        async.flushMicrotasks();

        // challenge 未到:一个字节都不该发出去
        expect(t.last.sent, isEmpty);
        expect(c.auth.phase, AuthPhase.awaitingChallenge);

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        final hellos = t.last.sentOfType('hello');
        expect(hellos, hasLength(1));
        expect(hellos.first['auth']['proof'],
            AuthProof.token(nonce: _nonceA, userId: _userId, token: 'shared-token'));
        c.dispose();
      });
    });

    test('challenge 的 modes / authRequired 会反映到 authStatus 供 UI 裁剪选项', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA, modes: ['token']));
        async.flushMicrotasks();

        expect(c.auth.serverModes, ['token']);
        expect(c.auth.authRequired, isTrue);
        c.dispose();
      });
    });

    test('welcome 到手才算握手完成,并回报 authMode', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        expect(c.isReady, isFalse);

        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        expect(c.isReady, isTrue);
        expect(c.auth.phase, AuthPhase.authenticated);
        expect(c.auth.mode, AuthMode.token);
        c.dispose();
      });
    });

    test('老服务器不发 challenge:超时后裸发 hello,保持向后兼容', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t, credential: AuthCredential.none);
        c.connect();
        sayHello(c);
        async.flushMicrotasks();
        expect(t.last.sent, isEmpty);

        async.elapse(SignalingClient.challengeTimeout + const Duration(seconds: 1));

        final hellos = t.last.sentOfType('hello');
        expect(hellos, hasLength(1));
        expect(hellos.first.containsKey('auth'), isFalse);
        c.dispose();
      });
    });
  });

  group('nonce 单次有效', () {
    test('重连后用新 nonce 重算证明,绝不重放旧证明', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        final firstProof = t.last.sentOfType('hello').first['auth']['proof'];

        // 普通掉线(无 close code)-> 退避重连
        t.last.serverClose(1006);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(t.channels, hasLength(2));

        // 新连接同样先等 challenge
        expect(t.last.sent, isEmpty);
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();

        final secondProof = t.last.sentOfType('hello').first['auth']['proof'];

        expect(secondProof, isNot(firstProof), reason: '重放旧证明会被服务端判 auth_failed');
        expect(secondProof,
            AuthProof.token(nonce: _nonceB, userId: _userId, token: 'shared-token'));
        expect(t.last.sentOfType('hello').first['auth']['nonce'], _nonceB);
        c.dispose();
      });
    });
  });

  group('关闭码驱动的重连策略', () {
    test('4401 只给一次重试机会,之后停止重连并抛出可操作状态', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);

        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        // 第一次 4401:允许重试一次(nonce 可能只是休眠期间正常过期)
        t.last.serverSend({'t': 'error', 'message': 'auth_failed'});
        t.last.serverClose(4401, 'auth_failed');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        expect(t.channels, hasLength(2));

        // 第二次还是 4401:到此为止
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();
        t.last.serverClose(4401, 'auth_failed');
        async.flushMicrotasks();

        // 再等很久也不该有第三条连接 —— 盲目重连只会把 IP 推向 4429
        async.elapse(const Duration(minutes: 5));
        expect(t.channels, hasLength(2), reason: '4401 不得触发无限重连');
        expect(c.auth.phase, AuthPhase.failed);
        expect(c.auth.needsUserAction, isTrue);
        expect(events.any((e) => e['t'] == '_auth_failed'), isTrue);
        c.dispose();
      });
    });

    test('4429 硬退避:一分钟内不再尝试', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        t.last.serverClose(4429, 'rate_limited');
        async.flushMicrotasks();

        expect(c.auth.phase, AuthPhase.rateLimited);

        // 普通退避是 1s 起步;限流必须比它慢得多
        async.elapse(const Duration(seconds: 30));
        expect(t.channels, hasLength(1), reason: '4429 不能按普通退避重试');

        async.elapse(SignalingClient.rateLimitBackoff);
        expect(t.channels, hasLength(2));
        c.dispose();
      });
    });

    test('普通掉线仍按指数退避自动重连', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverClose(1006);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 2));
        expect(t.channels, hasLength(2));
        expect(c.auth.phase, isNot(AuthPhase.failed));
        c.dispose();
      });
    });
  });

  group('auth_scope 是可恢复错误', () {
    test('auth_scope 不关连接、不触发重连、原样抛给上层', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);

        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'circle'});
        async.flushMicrotasks();

        t.last.serverSend({'t': 'error', 'message': 'auth_scope'});
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));

        // 连接还活着,没有新连接,也没有掉线事件
        expect(c.isConnected, isTrue);
        expect(c.isReady, isTrue);
        expect(t.channels, hasLength(1));
        expect(events.any((e) => e['t'] == '_disconnected'), isFalse);
        expect(c.auth.phase, AuthPhase.authenticated);
        // 上层能看到这条错误并自行处理
        expect(
          events.any((e) => e['t'] == 'error' && e['message'] == 'auth_scope'),
          isTrue,
        );
        c.dispose();
      });
    });

    test('say_hello_first 同样不当作掉线', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        t.last.serverSend({'t': 'error', 'message': 'say_hello_first'});
        async.flushMicrotasks();

        expect(c.isConnected, isTrue);
        expect(c.auth.phase, AuthPhase.authenticated);
        c.dispose();
      });
    });
  });

  group('协议健壮性', () {
    test('未知的 t 原样放行,不报错也不依赖消息顺序', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);

        c.connect();
        sayHello(c);
        // 故意把未知消息排在 challenge 之前:顺序不该影响任何事
        t.last.serverSend({'t': 'brand_new_feature', 'x': 1});
        t.last.serverSend(challenge(_nonceA));
        t.last.serverSend({'t': 'another_unknown'});
        async.flushMicrotasks();
        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        expect(events.any((e) => e['t'] == 'brand_new_feature'), isTrue);
        expect(events.any((e) => e['t'] == 'another_unknown'), isTrue);
        expect(c.isReady, isTrue, reason: '未知消息不得打断握手');
        c.dispose();
      });
    });

    test('坏 JSON 与非字符串帧被安静忽略', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last._incoming.add('{ not json');
        t.last._incoming.add(<int>[1, 2, 3]);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        expect(t.last.sentOfType('hello'), hasLength(1));
        c.dispose();
      });
    });

    test('pong 不外抛', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        t.last.serverSend({'t': 'pong'});
        async.flushMicrotasks();

        expect(events.any((e) => e['t'] == 'pong'), isFalse);
        c.dispose();
      });
    });
  });

  group('排队与预连接延迟', () {
    test('握手完成前的业务消息排队,welcome 后按序补发', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        // 启动期就预热 token(main.dart 的真实调用顺序)
        c.prefetchToken('home');
        async.flushMicrotasks();
        expect(t.last.sentOfType('token_prefetch'), isEmpty);

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        // 仍未 welcome:业务消息继续压着,避免撞 say_hello_first
        expect(t.last.sentOfType('token_prefetch'), isEmpty);

        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        expect(t.last.sentOfType('token_prefetch'), hasLength(1));
        c.dispose();
      });
    });

    test('握手完成后 join 直接发出,不额外排队(保住一键进房的一个往返)', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend({'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        final before = t.last.sent.length;
        c.join('home');
        async.flushMicrotasks();

        expect(t.last.sent.length, before + 1, reason: '进房不该再等任何握手');
        expect(t.last.sentOfType('join').single['circleId'], 'home');
        c.dispose();
      });
    });

    test('缺凭据时根本不发起连接,免得白白推高服务端失败计数', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t,
            credential: const AuthCredential(mode: AuthMode.token, token: ''));
        c.connect();
        async.flushMicrotasks();

        expect(t.channels, isEmpty);
        expect(c.auth.phase, AuthPhase.credentialRequired);
        expect(c.auth.needsUserAction, isTrue);
        c.dispose();
      });
    });
  });

  // ⚠️ 这一组盯的是「静默卡死」那一类 bug 里最阴的一条。
  //
  // connect() 在**拨号时**检查凭据齐不齐,而证明要等 challenge 到了才现算
  // (nonce 一次性、60s 过期,只能现算)。两者之间隔着一整个网络往返,
  // 凭据完全可能在这中间变掉:用户正在设置页改口令、安全存储这一次读失败、
  // 或者 authCircleId 被换成了另一个圈子。
  //
  // 于是出现一种谁都接不住的状态:socket **开着**,服务端发完 challenge
  // 就在那儿等 hello,而客户端算不出证明、一声不吭地 return 了。
  // 没有 welcome(服务端在等我们),没有 _disconnected(连接根本没断),
  // 没有 4401(压根没提交过证明)。上层的 _joinCompleter 永远挂着,
  // 界面永远停在「正在进去…」,连「算了」都退不出来。
  group('拨号后凭据失效:算不出证明时必须喊出来', () {
    /// 造一个「拨号时齐、算证明时不齐」的凭据源。
    (SignalingClient, List<Map<String, dynamic>>) clientWithVanishingCred(
      FakeTransport t, {
      required AuthCredential atDial,
      required AuthCredential atProof,
    }) {
      var cred = atDial;
      final c = SignalingClient(
        url: 'wss://rtc.example.com:8444/ws',
        connector: t.connect,
        credentials: () => cred,
        userId: _userId,
      );
      c.connect();
      sayHello(c);
      // 连接已建立(拨号那关过了),此刻把凭据抽走
      cred = atProof;
      final events = <Map<String, dynamic>>[];
      c.messages.listen(events.add);
      return (c, events);
    }

    test('凭据在 challenge 到达前失效:发出 _credential_required,而不是静默', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final (c, events) = clientWithVanishingCred(
          t,
          atDial: const AuthCredential(mode: AuthMode.token, token: 'ok'),
          atProof: const AuthCredential(mode: AuthMode.token, token: ''),
        );

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        final emitted =
            events.where((e) => e['t'] == '_credential_required').toList();
        expect(emitted, hasLength(1),
            reason: '不发这条,上层就永久停在「正在进去…」');
        expect(emitted.single['message'], 'auth_required');
        c.dispose();
      });
    });

    test('喊归喊,authStatus 仍要落到 credentialRequired(既有契约不许回退)', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final (c, _) = clientWithVanishingCred(
          t,
          atDial: const AuthCredential(mode: AuthMode.token, token: 'ok'),
          atProof: const AuthCredential(mode: AuthMode.token, token: ''),
        );

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        expect(c.auth.phase, AuthPhase.credentialRequired);
        expect(c.auth.needsUserAction, isTrue);
        c.dispose();
      });
    });

    test('绝不发一个注定失败的 hello —— 原来那层保护必须留着', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final (c, _) = clientWithVanishingCred(
          t,
          atDial: const AuthCredential(mode: AuthMode.token, token: 'ok'),
          atProof: const AuthCredential(mode: AuthMode.token, token: ''),
        );

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        expect(t.last.sentOfType('hello'), isEmpty,
            reason: '裸 hello 会被服务端判 auth_failed,白推高失败计数');
        expect(t.last.sent, isEmpty);
        c.dispose();
      });
    });

    test('circle 模式换圈换掉了口令,同样喊得出来', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final (c, events) = clientWithVanishingCred(
          t,
          atDial: const AuthCredential(
              mode: AuthMode.circle, passcode: 'p', circleId: 'home'),
          // 换到一个本地没存口令的圈子:isComplete 为假,build 返回 null
          atProof: const AuthCredential(
              mode: AuthMode.circle, passcode: '', circleId: 'work'),
        );

        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();

        expect(events.any((e) => e['t'] == '_credential_required'), isTrue);
        expect(t.last.sentOfType('hello'), isEmpty);
        c.dispose();
      });
    });

    test('凭据好端端的:照常发 hello,一条 _credential_required 都不许冒出来', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = makeClient(t);
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);

        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend(
            {'t': 'welcome', 'userId': _userId, 'authMode': 'token'});
        async.flushMicrotasks();

        expect(events.any((e) => e['t'] == '_credential_required'), isFalse,
            reason: '误报会让能进的房间进不去');
        expect(t.last.sentOfType('hello'), hasLength(1));
        expect(c.isReady, isTrue);
        c.dispose();
      });
    });

    test('同一条连接上 challenge 重发:只喊一次,不刷屏', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final (c, events) = clientWithVanishingCred(
          t,
          atDial: const AuthCredential(mode: AuthMode.token, token: 'ok'),
          atProof: const AuthCredential(mode: AuthMode.token, token: ''),
        );

        // 服务端重发 challenge,外加上层又调了一次 hello ——
        // 两条路都会再走一遍 _sendHelloWithProof
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();
        sayHello(c);
        async.flushMicrotasks();

        expect(events.where((e) => e['t'] == '_credential_required'),
            hasLength(1));
        c.dispose();
      });
    });

    test('但换一条新连接就是新的一次机会,不能被上一条的抑制标记哑掉', () {
      fakeAsync((async) {
        final t = FakeTransport();
        var cred = const AuthCredential(mode: AuthMode.token, token: 'ok');
        final c = SignalingClient(
          url: 'wss://rtc.example.com:8444/ws',
          connector: t.connect,
          credentials: () => cred,
          userId: _userId,
        );
        final events = <Map<String, dynamic>>[];
        c.messages.listen(events.add);

        c.connect();
        sayHello(c);
        cred = const AuthCredential(mode: AuthMode.token, token: '');
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        expect(
            events.where((e) => e['t'] == '_credential_required'), hasLength(1));

        // 用户把口令填回去 -> 干净重连;然后在路上又被抽走一次
        cred = const AuthCredential(mode: AuthMode.token, token: 'ok');
        c.reconnectWithNewCredential();
        async.flushMicrotasks();
        cred = const AuthCredential(mode: AuthMode.token, token: '');
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();

        // 第二次必须照喊:抑制标记若跨连接常驻,这一次进房就又是永久转圈
        expect(
            events.where((e) => e['t'] == '_credential_required'), hasLength(2));
        c.dispose();
      });
    });
  });

  group('换凭据', () {
    test('改口令后干净重连,并用新口令重新推导证明', () {
      fakeAsync((async) {
        final t = FakeTransport();
        var cred =
            const AuthCredential(mode: AuthMode.token, token: 'old-token');
        final c = SignalingClient(
          url: 'wss://rtc.example.com:8444/ws',
          connector: t.connect,
          credentials: () => cred,
          userId: _userId,
        );
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        expect(t.last.sentOfType('hello').first['auth']['proof'],
            AuthProof.token(nonce: _nonceA, userId: _userId, token: 'old-token'));

        // 用户在设置页改了口令
        cred = const AuthCredential(mode: AuthMode.token, token: 'new-token');
        c.reconnectWithNewCredential();
        async.flushMicrotasks();

        expect(t.channels, hasLength(2));
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();

        expect(
          t.last.sentOfType('hello').first['auth']['proof'],
          AuthProof.token(nonce: _nonceB, userId: _userId, token: 'new-token'),
        );
        c.dispose();
      });
    });

    test('4401 停摆后,换凭据能重新唤醒连接', () {
      fakeAsync((async) {
        final t = FakeTransport();
        var cred = const AuthCredential(mode: AuthMode.token, token: 'wrong');
        final c = SignalingClient(
          url: 'wss://x/ws',
          connector: t.connect,
          credentials: () => cred,
          userId: _userId,
        );
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        t.last.serverClose(4401);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();
        t.last.serverClose(4401);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));
        expect(t.channels, hasLength(2));
        expect(c.auth.phase, AuthPhase.failed);

        cred = const AuthCredential(mode: AuthMode.token, token: 'right');
        c.reconnectWithNewCredential();
        async.flushMicrotasks();

        expect(t.channels, hasLength(3), reason: '改完口令要能重新尝试');
        expect(c.auth.phase, isNot(AuthPhase.failed));
        c.dispose();
      });
    });

    test('circle 模式换圈子会带新圈口令重连', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = SignalingClient(
          url: 'wss://x/ws',
          connector: t.connect,
          credentials: () =>
              const AuthCredential(mode: AuthMode.circle, passcode: 'p'),
          userId: _userId,
        );
        c.authCircleId = 'home';
        c.connect();
        sayHello(c);
        t.last.serverSend(challenge(_nonceA));
        async.flushMicrotasks();
        expect(t.last.sentOfType('hello').first['auth']['circleId'], 'home');

        c.authCircleId = 'work';
        async.flushMicrotasks();
        t.last.serverSend(challenge(_nonceB));
        async.flushMicrotasks();

        final auth = t.last.sentOfType('hello').first['auth'];
        expect(auth['circleId'], 'work');
        expect(auth['v'], 2);
        expect(
          auth['proof'],
          AuthProof.circleV2(
              nonce: _nonceB,
              userId: _userId,
              circleId: 'work',
              verifier: deriveAuthVerifier(passcode: 'p', circleId: 'work')),
        );
        c.dispose();
      });
    });
  });
}
