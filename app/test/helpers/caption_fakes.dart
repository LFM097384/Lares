// 实时字幕测试共用的假实现:数据通道 / 麦克风抽头 / 识别器。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lares_app/src/captions/caption_controller.dart';
import 'package:lares_app/src/rtc/rtc_service.dart';

class FakeChannel implements RoomDataChannel {
  FakeChannel({this.localIdentity = 'me'});

  @override
  final String? localIdentity;

  final Set<String> remotes = {};
  final Set<String> micOn = {};
  final List<({Map<String, dynamic> msg, List<String>? to})> published = [];
  final inboundCtl = StreamController<RoomDataFrame>.broadcast(sync: true);
  final _joined = StreamController<String>.broadcast(sync: true);
  final _left = StreamController<String>.broadcast(sync: true);
  final _mic = StreamController<void>.broadcast(sync: true);

  @override
  Set<String> get remoteIdentities => Set.of(remotes);
  @override
  bool isRemoteMicOn(String identity) => micOn.contains(identity);
  @override
  Stream<void> get remoteMicChanged => _mic.stream;
  @override
  Stream<RoomDataFrame> get inbound => inboundCtl.stream;
  @override
  Stream<String> get participantJoined => _joined.stream;
  @override
  Stream<String> get participantLeft => _left.stream;

  @override
  Future<void> publish(Uint8List data, {List<String>? to}) async {
    published.add((
      msg: jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
      to: to == null ? null : List.of(to),
    ));
  }

  void receive(String from, Map<String, dynamic> m) => inboundCtl.add(RoomDataFrame(
      senderIdentity: from,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(m)))));

  void join(String id, {bool mic = false}) {
    remotes.add(id);
    if (mic) micOn.add(id);
    _joined.add(id);
  }

  void leave(String id) {
    remotes.remove(id);
    micOn.remove(id);
    _left.add(id);
  }

  Iterable<Map<String, dynamic>> sentOfType(String t) =>
      published.where((p) => p.msg['t'] == t).map((p) => p.msg);
}

class FakeTap implements LocalAudioTap {
  bool unmuted = true;
  int attachCount = 0;
  int cancelCount = 0;

  /// 为 false 时注册成功但永远不出帧(模拟 unmute 后的静默失效)。
  bool deliver = true;
  void Function(Uint8List)? _cb;
  final _changes = StreamController<void>.broadcast(sync: true);

  @override
  bool get micPublishedAndUnmuted => unmuted;

  @override
  LocalAudioTapCancel? attach(void Function(Uint8List pcm16) onFrame) {
    attachCount++;
    _cb = onFrame;
    return () async {
      cancelCount++;
      if (identical(_cb, onFrame)) _cb = null;
    };
  }

  bool get attached => _cb != null;

  void frame([int bytes = 320]) {
    if (deliver) _cb?.call(Uint8List(bytes));
  }

  @override
  Stream<void> get trackChanges => _changes.stream;

  void changed() => _changes.add(null);
}

class FakeTranscriber implements CaptionTranscriber {
  FakeTranscriber(this.onPartial, this.onFinal, this.onFatal);
  final void Function(String, String) onPartial;
  final void Function(String, String) onFinal;
  final void Function(String) onFatal;
  bool started = false;
  bool stopped = false;
  bool disposed = false;
  int pcmBytes = 0;

  @override
  void start() => started = true;
  @override
  void addPcm(Uint8List pcm) => pcmBytes += pcm.length;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Future<void> dispose() async => disposed = true;

  bool get active => started && !stopped;
}
