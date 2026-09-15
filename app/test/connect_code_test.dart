import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/p2p/connect_code.dart';

/// 连接码的编解码测试。
///
/// 这层的意义:跨网络 P2P 要先交换 SDP,而交换本身需要一个通道。
/// 连接码把这一步交还给用户(微信/短信/扫码),从而**零信令服务器**。
///
/// 两类会真出问题的事:
///   1. 跨端格式不兼容(安卓生成的码 Web 打不开)
///   2. 用户粘错东西 —— 这是常见路径,不是异常
void main() {
  // 一份结构真实的 SDP 片段
  const sdp = 'v=0\r\n'
      'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
      's=-\r\n'
      't=0 0\r\n'
      'a=ice-ufrag:4ZcD\r\n'
      'a=ice-pwd:2/1muCWoOi3uLifh0NuRHlPw\r\n'
      'a=fingerprint:sha-256 4A:AD:B9:B1:3F:82:18:3B\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=rtpmap:111 opus/48000/2\r\n';

  group('往返', () {
    test('offer 编码后能原样解回来', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      final r = decodeConnectCode(code);
      expect(r.isOk, isTrue);
      expect(r.kind, ConnectCodeKind.offer);
      expect(r.sdp, sdp);
    });

    test('answer 同理', () {
      final code = encodeConnectCode(ConnectCodeKind.answer, sdp);
      final r = decodeConnectCode(code);
      expect(r.kind, ConnectCodeKind.answer);
      expect(r.sdp, sdp);
    });

    test('码带人眼可辨的前缀', () {
      expect(encodeConnectCode(ConnectCodeKind.offer, sdp),
          startsWith('LARES-O1:'));
      expect(encodeConnectCode(ConnectCodeKind.answer, sdp),
          startsWith('LARES-A1:'));
    });

    test('真实体量的 SDP 压完能进二维码 —— 这是方案能不能成立的前提', () {
      // 上面那个 sdp 常量只有约 300 字节,**不够真实**:
      // gzip 有固定开销(头部+校验),短文本压不过 base64。
      // 真实 SDP 含十几条 rtpmap 和若干 ICE 候选,实测约 1800 字节。
      final big = StringBuffer(sdp);
      for (var i = 0; i < 14; i++) {
        big.writeln('a=rtpmap:$i opus/48000/2');
        big.writeln('a=fmtp:$i minptime=10;useinbandfec=1');
      }
      for (var i = 0; i < 6; i++) {
        big.writeln('a=candidate:$i 1 udp 2122260223 192.168.1.10 5${i}000 '
            'typ host generation 0 ufrag 4ZcD network-id 1');
      }
      final real = big.toString();
      expect(real.length, greaterThan(1500), reason: '样本要够真实才有意义');

      final code = encodeConnectCode(ConnectCodeKind.offer, real);
      final plainB64 = base64Url.encode(utf8.encode(real));
      expect(code.length, lessThan(plainB64.length ~/ 2),
          reason: '实测能压到 29%,不压缩的话手动传递不现实');
      // 二维码版本 40-L 的二进制上限
      expect(code.length, lessThan(2953), reason: '要放得进二维码');
      // 而且解得回来
      expect(decodeConnectCode(code).sdp, real);
    });
  });

  group('⚠️ 跨端格式必须一致', () {
    // 原生端用 dart:io 的 gzip,Web 端用 archive 的 GZipEncoder。
    // 两者都是 RFC 1952,但「应该兼容」和「实测兼容」是两回事 ——
    // 不验的话会出现「安卓生成的码 Web 打不开」这种只在跨端才暴露的 bug。
    test('dart:io 压的,archive 能解', () {
      final raw = utf8.encode(sdp);
      final packed = gzip.encode(raw);
      final back = const GZipDecoder().decodeBytes(packed);
      expect(utf8.decode(back), sdp);
    });

    test('archive 压的,dart:io 能解', () {
      final raw = utf8.encode(sdp);
      final packed = const GZipEncoder().encode(raw);
      final back = gzip.decode(packed);
      expect(utf8.decode(back), sdp);
    });
  });

  group('用户粘错东西(常见路径,不是异常)', () {
    test('粘了一段普通文字', () {
      final r = decodeConnectCode('你好在吗');
      expect(r.isOk, isFalse);
      expect(r.error, ConnectCodeError.notLaresCode);
      expect(r.message, isNotEmpty);
    });

    test('空串', () {
      expect(decodeConnectCode('').error, ConnectCodeError.notLaresCode);
      expect(decodeConnectCode('   ').error, ConnectCodeError.notLaresCode);
    });

    test('前缀对但内容被截断', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      final cut = code.substring(0, code.length ~/ 2);
      expect(decodeConnectCode(cut).error, ConnectCodeError.corrupted);
    });

    test('该贴应答码的地方贴了发起码', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      final r = decodeConnectCode(code, expect: ConnectCodeKind.answer);
      expect(r.error, ConnectCodeError.wrongKind);
      expect(r.message, contains('贴反'));
    });

    test('版本对不上要明确报错,而不是解出乱码', () {
      // 手工造一个版本号不同的码
      final payload = jsonEncode({'v': 99, 'sdp': sdp});
      final packed = base64Url.encode(gzip.encode(utf8.encode(payload)));
      final r = decodeConnectCode('LARES-O1:$packed');
      expect(r.error, ConnectCodeError.versionMismatch);
      expect(r.message, contains('版本'));
    });
  });

  group('从聊天软件复制过来的脏数据', () {
    test('首尾空白和换行被容忍', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      expect(decodeConnectCode('  \n$code\n\n  ').sdp, sdp);
    });

    test('中间被插入换行(长文本在聊天里常被折行)', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      final folded =
          '${code.substring(0, 40)}\n${code.substring(40, 80)}\n${code.substring(80)}';
      expect(decodeConnectCode(folded).sdp, sdp);
    });

    test('零宽字符被清掉 —— 有些输入法会偷偷插', () {
      final code = encodeConnectCode(ConnectCodeKind.offer, sdp);
      final dirty = '\u200b$code\ufeff';
      expect(decodeConnectCode(dirty).sdp, sdp);
    });
  });

  group('每个失败都有人话', () {
    test('所有错误码都有非空说明,且不含英文异常名', () {
      for (final e in ConnectCodeError.values) {
        final msg = ConnectCodeResult.fail(e).message;
        expect(msg, isNotEmpty, reason: '$e 必须有话说');
        expect(msg, isNot(contains('Exception')));
        expect(msg.length, lessThanOrEqualTo(40), reason: '$e 太长');
      }
    });
  });
}
