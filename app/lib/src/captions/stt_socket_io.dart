import 'dart:async';

import 'package:web_socket_channel/io.dart';

import 'stt_socket.dart';

const bool supported = true;

SttSocket connect(Uri url, Map<String, String> headers) =>
    _IoSttSocket(IOWebSocketChannel.connect(
      url,
      headers: headers,
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    ));

class _IoSttSocket implements SttSocket {
  _IoSttSocket(this._ch);

  final IOWebSocketChannel _ch;

  @override
  Stream<String> get messages =>
      _ch.stream.where((m) => m is String).cast<String>();

  @override
  Future<void> get ready => _ch.ready;

  @override
  void send(String text) => _ch.sink.add(text);

  @override
  Future<void> close([int? code]) async {
    try {
      await _ch.sink.close(code ?? 1000).timeout(const Duration(seconds: 2));
    } on Object {
      // 关不干净也无所谓:连接对象随即被丢弃
    }
  }

  @override
  int? get closeCode => _ch.closeCode;
}
