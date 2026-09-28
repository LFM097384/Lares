import 'stt_socket.dart';

const bool supported = false;

SttSocket connect(Uri url, Map<String, String> headers) =>
    throw UnsupportedError('实时字幕在本平台不可用(浏览器 WebSocket 不能带鉴权头)');
