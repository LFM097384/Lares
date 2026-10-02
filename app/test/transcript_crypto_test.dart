import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/transcript/transcript_crypto.dart';

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final vector = jsonDecode(
          File('test/fixtures/transcript_blob_vector.json').readAsStringSync())
      as Map<String, dynamic>;
  final keyHex = vector['keyHex'] as String;
  final circleId = vector['circleId'] as String;

  test('HKDF matches the Node vector', () {
    final k = deriveTranscriptKey(circleKeyHex: keyHex, circleId: circleId);
    expect(_toHex(k), vector['derivedKeyHex']);
  });

  test('encrypt with fixed nonce reproduces the Node blob; decrypts back', () {
    final key = deriveTranscriptKey(circleKeyHex: keyHex, circleId: circleId);
    final blob = encryptTranscriptBlobWithKey(
      key: key,
      circleId: circleId,
      plaintext: vector['plaintext'] as String,
      nonce: _hex(vector['nonceHex'] as String),
    );
    expect(blob, vector['blob']);
    final line = decryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, blob: vector['blob'] as String);
    expect(line.name, '阿丽');
    expect(line.uid, 'user-alice');
    expect(line.startedAt, 1727900000000);
  });

  const plain = TranscriptPlain(
      id: 's1', uid: 'u1', name: '小明', text: '你好', startedAt: 1, ts: 2);

  test('round trip with random nonce, nonces differ', () {
    final a = encryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, line: plain);
    final b = encryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, line: plain);
    expect(a, isNot(b));
    final out =
        decryptTranscriptLine(circleKeyHex: keyHex, circleId: circleId, blob: a);
    expect(out.toJson(), plain.toJson());
    expect(base64.decode(a)[0], 0x01);
  });

  test('wrong key fails', () {
    final blob = encryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, line: plain);
    expect(
        () => decryptTranscriptLine(
            circleKeyHex: 'aa' * 32, circleId: circleId, blob: blob),
        throwsA(isA<TranscriptCryptoException>()));
  });

  test('tampered ciphertext fails', () {
    final blob = encryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, line: plain);
    final raw = base64.decode(blob);
    raw[20] ^= 0x01;
    expect(
        () => decryptTranscriptLine(
            circleKeyHex: keyHex, circleId: circleId, blob: base64.encode(raw)),
        throwsA(isA<TranscriptCryptoException>()));
  });

  test('AAD binds the circle id', () {
    // 同一把圈密钥(ikm)但不同 circleId:HKDF salt 与 AAD 都不同 → 必须解不开。
    final blob = encryptTranscriptLine(
        circleKeyHex: keyHex, circleId: circleId, line: plain);
    expect(
        () => decryptTranscriptLine(
            circleKeyHex: keyHex, circleId: 'c_other', blob: blob),
        throwsA(isA<TranscriptCryptoException>()));
    // 只换 AAD(同一把派生密钥)也解不开
    final key = deriveTranscriptKey(circleKeyHex: keyHex, circleId: circleId);
    expect(
        () => decryptTranscriptBlobWithKey(
            key: key, circleId: 'c_other', blob: blob),
        throwsA(isA<TranscriptCryptoException>()));
  });

  test('garbage and bad version fail cleanly', () {
    final key = deriveTranscriptKey(circleKeyHex: keyHex, circleId: circleId);
    expect(
        () => decryptTranscriptBlobWithKey(
            key: key, circleId: circleId, blob: '%%%'),
        throwsA(isA<TranscriptCryptoException>()));
    final raw = base64.decode(vector['blob'] as String);
    raw[0] = 0x02;
    expect(
        () => decryptTranscriptBlobWithKey(
            key: key, circleId: circleId, blob: base64.encode(raw)),
        throwsA(isA<TranscriptCryptoException>()));
  });
}
