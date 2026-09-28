/// 识别服务 WebSocket 的最小抽象,测试里用假实现替换。
library;

import 'dart:async';

import 'stt_socket_stub.dart' if (dart.library.io) 'stt_socket_io.dart'
    as impl;

/// 一条已建立(或正在建立)的识别连接。
abstract class SttSocket {
  /// 服务端下行的文本帧。连接断开时流结束。
  Stream<String> get messages;

  /// 握手完成。握手失败时以异常结束。
  Future<void> get ready;

  void send(String text);

  Future<void> close([int? code]);

  /// 服务端关闭码(流结束后可读;未知为 null)。
  int? get closeCode;
}

typedef SttSocketConnector = SttSocket Function(
  Uri url,
  Map<String, String> headers,
);

/// 平台默认实现:原生平台用 dart:io WebSocket(可以带 Authorization 头);
/// Web 上浏览器 WebSocket 不能设头,字幕不可用,调用即抛 [UnsupportedError]。
SttSocket connectSttSocket(Uri url, Map<String, String> headers) =>
    impl.connect(url, headers);

/// 本平台能否直接连识别服务。
const bool kSttSocketSupported = impl.supported;
