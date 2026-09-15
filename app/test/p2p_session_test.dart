import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:lares_app/src/p2p/connect_code.dart';
import 'package:lares_app/src/p2p/p2p_session.dart';

/// 点对点会话的状态机测试。
///
/// 不碰真实 WebRTC(测试环境没有原生层),只验那几件会真出错的事:
///   1. 连接码必须包含 ICE 候选 —— 取的是收集完成后的 SDP,不是 createOffer 那份
///   2. 贴错码要报人话,不能静默
///   3. 连不上时要**如实失败**,而且提示要指向 TURN
void main() {
  late _FakePc pc;

  P2PSession make({IceConfig ice = const IceConfig()}) {
    pc = _FakePc();
    return P2PSession(
      ice: ice,
      factory: (_) async => pc,
      microphone: () async => _FakeStream(),
      gatherTimeout: const Duration(milliseconds: 50),
    );
  }

  group('ICE 配置', () {
    test('默认不内置任何 STUN —— 那是隐形的外部依赖', () {
      const ice = IceConfig();
      expect(ice.isEmpty, isTrue);
      final cfg = ice.toRtcConfiguration();
      expect(cfg['iceServers'], isEmpty,
          reason: '内置 Google STUN 与「不依赖任何人」的初衷相悖');
    });

    test('填了 STUN/TURN 会进配置', () {
      const ice = IceConfig(
        stunUrls: ['stun:stun.example.com:3478'],
        turn: TurnConfig(
          url: 'turn:turn.example.com:3478',
          username: 'u',
          credential: 'p',
        ),
      );
      final servers = ice.toRtcConfiguration()['iceServers'] as List;
      expect(servers, hasLength(2));
      expect(servers[1]['username'], 'u');
    });
  });

  group('发起方', () {
    test('生成的连接码取自 ICE 收集完成后的 SDP', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();

      expect(s.phase, P2PPhase.waitingForPeer);
      expect(s.localCode, startsWith('LARES-O1:'));
      // 关键:必须是 getLocalDescription() 那份(带候选),
      // 不是 createOffer() 返回的那份(没候选,对方拿到也连不上)
      final decoded = decodeConnectCode(s.localCode!);
      expect(decoded.sdp, contains('a=candidate'),
          reason: '不含候选的连接码是废的');
    });

    test('麦克风在 createOffer 之前就加进去了', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();
      expect(pc.addTrackCalls, greaterThan(0),
          reason: '没有音频轨的话,连上了也听不见');
      expect(pc.addTrackBeforeOffer, isTrue,
          reason: 'createOffer 之后再加轨,SDP 里就没有它');
    });

    test('贴入对方的应答码后进入 connecting', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();
      final answer = encodeConnectCode(
          ConnectCodeKind.answer, 'v=0\r\na=candidate:x\r\n');
      await s.acceptRemoteCode(answer);
      expect(s.phase, P2PPhase.connecting);
    });

    test('贴反了(贴成发起码)要明确报错', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();
      await s.acceptRemoteCode(
          encodeConnectCode(ConnectCodeKind.offer, 'v=0\r\n'));
      expect(s.phase, P2PPhase.failed);
      expect(s.failure, contains('贴反'));
    });
  });

  group('应答方', () {
    test('贴入发起码后生成应答码', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.acceptRemoteCode(
          encodeConnectCode(ConnectCodeKind.offer, 'v=0\r\na=x\r\n'));
      expect(s.phase, P2PPhase.waitingForPeer);
      expect(s.localCode, startsWith('LARES-A1:'));
    });

    test('粘了一段普通文字,报人话而不是崩', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.acceptRemoteCode('你好在吗');
      expect(s.phase, P2PPhase.failed);
      expect(s.failure, isNotNull);
      expect(s.failure, isNot(contains('Exception')));
    });
  });

  group('连接状态', () {
    test('连上了就是 connected', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();
      pc.emitState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      expect(s.isConnected, isTrue);
    });

    test('⚠️ 连不上时如实失败,且没配 TURN 时提示指向 TURN', () async {
      final s = make();
      addTearDown(s.dispose);
      await s.createOffer();
      pc.emitState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      expect(s.phase, P2PPhase.failed);
      expect(s.failure, contains('中继'),
          reason: '约 20-30% 的 NAT 组合穿不过去,要告诉用户出路');
    });

    test('配了 TURN 还失败,提示要不一样', () async {
      final s = make(
        ice: const IceConfig(
          turn: TurnConfig(url: 'turn:x', username: 'u', credential: 'p'),
        ),
      );
      addTearDown(s.dispose);
      await s.createOffer();
      pc.emitState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      expect(s.failure, contains('中继服务器可能也不通'));
    });
  });

  group('ICE 收集超时', () {
    test('永远不报 complete 时,到点用已有候选继续', () async {
      pc = _FakePc(neverComplete: true);
      final s = P2PSession(
        factory: (_) async => pc,
        microphone: () async => _FakeStream(),
        gatherTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(s.dispose);
      await s.createOffer();
      // 没卡死,照样出码 —— 某些网络下 complete 永远不来
      expect(s.localCode, isNotNull);
      expect(s.phase, P2PPhase.waitingForPeer);
    });
  });
}

/// 假的 PeerConnection:不碰原生层。
class _FakePc implements RTCPeerConnection {
  _FakePc({this.neverComplete = false});

  final bool neverComplete;
  int addTrackCalls = 0;
  bool addTrackBeforeOffer = false;
  bool _offered = false;

  @override
  void Function(RTCIceGatheringState)? onIceGatheringState;
  @override
  void Function(RTCPeerConnectionState)? onConnectionState;

  void emitState(RTCPeerConnectionState s) => onConnectionState?.call(s);

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track,
      [MediaStream? stream]) async {
    addTrackCalls++;
    if (!_offered) addTrackBeforeOffer = true;
    return _FakeSender();
  }

  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic>? constraints]) async {
    _offered = true;
    // 刻意**不含**候选 —— 真实行为就是这样
    return RTCSessionDescription('v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic>? constraints]) async {
    _offered = true;
    return RTCSessionDescription('v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    if (neverComplete) return;
    // 真实实现里收集是异步的
    Future<void>.delayed(const Duration(milliseconds: 5), () {
      onIceGatheringState
          ?.call(RTCIceGatheringState.RTCIceGatheringStateComplete);
    });
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      // 收集完成后的那份:带候选
      RTCSessionDescription(
        'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n'
        'a=candidate:1 1 udp 2122260223 192.168.1.10 50000 typ host\r\n',
        _offered ? 'offer' : 'answer',
      );

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeStream implements MediaStream {
  final _tracks = <MediaStreamTrack>[_FakeTrack()];

  @override
  List<MediaStreamTrack> getAudioTracks() => _tracks;

  @override
  List<MediaStreamTrack> getTracks() => _tracks;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeTrack implements MediaStreamTrack {
  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

