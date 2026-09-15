/// 点对点直连会话:不经过任何 SFU,音频在两台设备之间直接走。
///
/// ## 与主链路的关系
///
/// 这是一条**独立**的路径,不走 LiveKit —— 因为 `Room.connect(url, token)`
/// 必须连一台 SFU,没有 P2P 模式(已核对 livekit_client 2.12.0 源码)。
/// 所以这里直接用 `flutter_webrtc` 的裸 `RTCPeerConnection`。
///
/// 代价要说清楚:建在 LiveKit 之上的功能(文字/图片消息、E2EE、录音)
/// 在这条路径下都**不可用**,除非各自重写。
/// 这条路解决的是「一台服务器都没有时还能说上话」,不是取代主链路。
///
/// ## 那个绕不开的事实
///
/// 「无服务器」在 WebRTC 里有三层,只有信令这层能真正做到零服务器:
///
/// | 需要什么 | 本实现 |
/// |---|---|
/// | 信令(交换 SDP) | **用户自己传连接码** —— 零服务器 |
/// | STUN(发现公网地址) | 可配置,可留空(同网段不需要) |
/// | TURN(穿不过时中继) | 可配置,留空则**明确失败**而不是偷偷回落 |
///
/// 约 20-30% 的 NAT 组合(双方都是对称型)物理上无法直连,
/// 那时没有 TURN 就是连不上。本实现选择**如实报告失败**,
/// 因为「以为连上了其实没有」比「明确失败」糟糕得多。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'connect_code.dart';

/// ICE 服务器配置。两个都可以为空 —— 空的含义是「不用」,不是「用默认的」。
@immutable
class IceConfig {
  const IceConfig({this.stunUrls = const [], this.turn});

  /// STUN 地址。留空则只能在同一网段内直连。
  ///
  /// 刻意**不内置** Google 的公共 STUN:那是一个隐形的外部依赖,
  /// 与这个功能「不依赖任何人」的初衷相悖。要用就由用户自己填。
  final List<String> stunUrls;

  /// TURN 中继。留空则穿不过 NAT 时直接失败。
  final TurnConfig? turn;

  bool get isEmpty => stunUrls.isEmpty && turn == null;

  Map<String, dynamic> toRtcConfiguration() => {
        'iceServers': [
          for (final u in stunUrls) {'urls': u},
          if (turn != null)
            {
              'urls': turn!.url,
              'username': turn!.username,
              'credential': turn!.credential,
            },
        ],
        // 只走 UDP/TCP 直连与中继,不做多余尝试
        'sdpSemantics': 'unified-plan',
      };
}

@immutable
class TurnConfig {
  const TurnConfig({
    required this.url,
    required this.username,
    required this.credential,
  });

  final String url;
  final String username;
  final String credential;
}

enum P2PPhase {
  idle,

  /// 正在收集本机的连接候选(生成连接码前的必经步骤)
  gathering,

  /// 连接码已生成,等着对方回应
  waitingForPeer,

  /// 正在建立连接
  connecting,

  connected,

  /// 连不上。[P2PSession.failure] 里有人话说明。
  failed,

  closed,
}

/// 一次点对点会话。
///
/// 用法(发起方):
/// ```
/// await session.createOffer();          // 生成连接码
/// // ... 把 session.localCode 发给对方 ...
/// await session.acceptRemoteCode(code); // 贴入对方回的应答码
/// ```
///
/// 应答方:
/// ```
/// await session.acceptRemoteCode(offerCode); // 贴入对方的发起码
/// // ... 把 session.localCode 回给对方 ...
/// ```
class P2PSession extends ChangeNotifier {
  P2PSession({
    IceConfig ice = const IceConfig(),
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? factory,
    Future<MediaStream> Function()? microphone,
    this.gatherTimeout = const Duration(seconds: 8),
  })  : _ice = ice,
        _factory = factory ?? createPeerConnection,
        _microphone = microphone ?? _defaultMic;

  static Future<MediaStream> _defaultMic() =>
      navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});

  final IceConfig _ice;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _factory;
  final Future<MediaStream> Function() _microphone;

  /// 等 ICE 收集完成的上限。
  ///
  /// 为什么要有上限:候选收集在某些网络下**永远不会**报 complete
  /// (比如 STUN 不可达时会一直等超时)。
  /// 到点就用已有的候选生成连接码 —— 有总比没有强。
  final Duration gatherTimeout;

  RTCPeerConnection? _pc;
  MediaStream? _local;

  P2PPhase phase = P2PPhase.idle;

  /// 本机的连接码,生成后交给对方。
  String? localCode;

  /// 失败原因(人话)。
  String? failure;

  /// 我是发起方还是应答方。
  bool _isOfferer = false;

  Completer<void>? _gathered;

  bool get isConnected => phase == P2PPhase.connected;

  /// 发起方:生成发起码。
  Future<void> createOffer() async {
    _isOfferer = true;
    await _prepare();
    final pc = _pc!;
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    await _waitGathering();
    // 必须取**收集完成之后**的 localDescription:
    // createOffer 返回的那份里还没有 ICE 候选,对方拿到也连不上。
    final full = await pc.getLocalDescription();
    localCode = encodeConnectCode(ConnectCodeKind.offer, full?.sdp ?? '');
    _set(P2PPhase.waitingForPeer);
  }

  /// 贴入对方的连接码。
  ///
  /// 发起方贴的是 answer,应答方贴的是 offer —— 方法是同一个,
  /// 靠码里自带的类型区分,这样 UI 只要一个输入框。
  Future<void> acceptRemoteCode(String code) async {
    final r = decodeConnectCode(
      code,
      expect: _isOfferer ? ConnectCodeKind.answer : ConnectCodeKind.offer,
    );
    if (!r.isOk) {
      failure = r.message;
      _set(P2PPhase.failed);
      return;
    }

    if (!_isOfferer) {
      // 应答方:收到 offer -> 建连接 -> 生成 answer
      await _prepare();
      final pc = _pc!;
      await pc.setRemoteDescription(
        RTCSessionDescription(r.sdp, 'offer'),
      );
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      await _waitGathering();
      final full = await pc.getLocalDescription();
      localCode = encodeConnectCode(ConnectCodeKind.answer, full?.sdp ?? '');
      _set(P2PPhase.waitingForPeer);
      return;
    }

    // 发起方:收到 answer,握手完成,等连接建立
    await _pc!.setRemoteDescription(
      RTCSessionDescription(r.sdp, 'answer'),
    );
    _set(P2PPhase.connecting);
  }

  Future<void> _prepare() async {
    _set(P2PPhase.gathering);
    final pc = await _factory(_ice.toRtcConfiguration());
    _pc = pc;

    _gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!(_gathered?.isCompleted ?? true)) _gathered!.complete();
      }
    };
    pc.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _set(P2PPhase.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // 这里就是「穿不过 NAT」最常见的落点。
          failure = _ice.turn == null
              ? '连不上对方。你们的网络之间需要一台中继服务器(TURN),'
                  '可以在设置里填一个。'
              : '连不上对方,中继服务器可能也不通。';
          _set(P2PPhase.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (phase != P2PPhase.failed) _set(P2PPhase.closed);
        default:
          break;
      }
    };

    // 把麦克风加进去。必须在 createOffer 之前 ——
    // 否则 SDP 里没有音频轨,连上了也听不见。
    final mic = await _microphone();
    _local = mic;
    for (final t in mic.getAudioTracks()) {
      await pc.addTrack(t, mic);
    }
  }

  Future<void> _waitGathering() async {
    final g = _gathered;
    if (g == null || g.isCompleted) return;
    // 超时就用已有候选:某些网络下 complete 永远不来,
    // 干等着不如拿手上有的先试。
    await g.future.timeout(gatherTimeout, onTimeout: () {
      debugPrint('[lares] ICE 收集超时,用已有候选继续');
    });
  }

  bool _disposed = false;

  void _set(P2PPhase p) {
    if (phase == p) return;
    phase = p;
    // dispose 之后不能再通知 —— ChangeNotifier 会直接抛错。
    // 这条路径真实存在:dispose() 会调 close(),而 close() 要改状态。
    if (_disposed) return;
    notifyListeners();
  }

  /// 释放麦克风与连接。可重复调用。
  Future<void> close() async {
    for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    _local = null;
    await _pc?.close();
    _pc = null;
    _set(P2PPhase.closed);
  }

  @override
  void dispose() {
    // 先标记再清理:close() 内部会 _set(),那时不能再通知。
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
