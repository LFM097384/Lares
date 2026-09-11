import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// presence 信令客户端:与 server/ 的 JSON-over-WebSocket 协议对话。
///
/// 预连接策略(设计.md §8.3-P0):App 启动即 connect + hello,
/// 保持长连接,进房时只需 join -> token 一个往返。
class SignalingClient {
  SignalingClient({required this.url});

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  bool _connected = false;
  bool _disposed = false;
  int _retrySeconds = 1;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  /// 待重连成功后补发的 hello 信息
  Map<String, dynamic>? _lastHello;

  /// 未连接期间的消息队列,连接建立后按序补发
  final List<Map<String, dynamic>> _outbox = [];

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  bool get isConnected => _connected;

  /// 建立(或重建)长连接。重复调用安全。
  void connect() {
    if (_disposed || _connected) return;
    _reconnectTimer?.cancel();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _sub = _channel!.stream.listen(
      _onData,
      onError: (_) => _onDisconnected(),
      onDone: _onDisconnected,
      cancelOnError: true,
    );
    _connected = true;
    _retrySeconds = 1;
    // 重连成功后恢复身份,并按序补发排队的消息
    final hello = _lastHello;
    if (hello != null) send(hello);
    for (final msg in _outbox) {
      send(msg);
    }
    _outbox.clear();
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      send({'t': 'ping'});
    });
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data);
      if (json is Map<String, dynamic> && json['t'] != 'pong') {
        _messages.add(json);
      }
    } catch (_) {
      // 忽略坏包
    }
  }

  void _onDisconnected() {
    if (!_connected) return;
    _connected = false;
    _pingTimer?.cancel();
    _sub?.cancel();
    _messages.add({'t': '_disconnected'}); // 内部事件:UI 可显示重连中
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // 指数退避,封顶 16s
    _reconnectTimer = Timer(Duration(seconds: _retrySeconds), connect);
    _retrySeconds = (_retrySeconds * 2).clamp(1, 16);
  }

  void send(Map<String, dynamic> msg) {
    if (msg['t'] == 'hello') _lastHello = msg;
    if (!_connected) {
      if (msg['t'] != 'hello') _outbox.add(msg);
      connect(); // 懒连接:发送时若未连接则先连,消息连接后补发
      return;
    }
    _channel?.sink.add(jsonEncode(msg));
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

  /// 测试注入:模拟收到一条服务器消息
  // ignore: use_setters_to_change_properties
  void testInject(Map<String, dynamic> msg) => _messages.add(msg);

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _messages.close();
  }
}
