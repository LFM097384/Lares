/// 密封测试向量:server/anonym-agent/SEALING.md 的官方向量(agent 侧
/// server/bots/anonym-agent/test/sealing.test.mjs 复算同一个),Dart 必须逐字节一致。
/// 说明见 docs/plans/chatham/client-sealing.md。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_seal.dart';

List<int> _hex(String h) => [
  for (int i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
];

const String kSealCircle = 'c_test';

/// agent 私钥 = 0x11 × 32(RFC 7748 原始标量)。
final List<int> kSealAgentSeed = List<int>.filled(32, 0x11);
final List<int> kSealAgentPub =
    base64.decode('e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=');

/// 临时私钥 = 0x22 × 32;nonce = 0x00..0x0b。
final List<int> kSealEphSeed = List<int>.filled(32, 0x22);
final List<int> kSealNonce = _hex('000102030405060708090a0b');
const String kSealEphPub = 'D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA=';

/// 明文 = 媒体密钥 hex 字符串本身(按 UTF-8 加密)。
const String kSealPlaintext =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

const String kSealed =
    'AQ+qaE7SiGe5f0pqLe5d+M6XTna3AY4/IqHEzyZ4Vw8gAAECAwQFBgcICQoLV6kH+YsWDA/PgPHajRbfNoONuWPQ4318ZKZx72GgEa+fd4E7o7VISxdbjISF7DWzrNxdqwUSwCKG4Td8lcVU/0CoOIByJaypKN2eb+GvayI=';

void main() {
  test('X25519 public keys from the SEALING.md private keys', () async {
    expect(await x25519PubFromSeed(kSealAgentSeed), kSealAgentPub);
    expect(base64.encode(await x25519PubFromSeed(kSealEphSeed)), kSealEphPub);
    expect(_hex('1111111111111111111111111111111111111111111111111111111111111111'),
        kSealAgentSeed);
  });

  test('seal vector matches SEALING.md byte for byte', () async {
    final String sealed = await anonSeal(
      agentPub: kSealAgentPub,
      plaintext: kSealPlaintext,
      circleId: kSealCircle,
      ephemeralSeed: kSealEphSeed,
      nonce: kSealNonce,
    );
    expect(sealed, kSealed);
    final List<int> raw = base64.decode(sealed);
    expect(raw.length, 1 + 32 + 12 + 64 + 16);
    expect(raw[0], kAnonSealVersion);
    expect(base64.encode(raw.sublist(1, 33)), kSealEphPub);
    expect(raw.sublist(33, 45), kSealNonce);
  });

  test('agent unseals; random seal round-trips; tamper / wrong circle fails', () async {
    expect(
      await anonUnseal(agentSeed: kSealAgentSeed, sealed: kSealed, circleId: kSealCircle),
      kSealPlaintext,
    );
    final String s1 =
        await anonSeal(agentPub: kSealAgentPub, plaintext: 'ab' * 32, circleId: 'c1');
    final String s2 =
        await anonSeal(agentPub: kSealAgentPub, plaintext: 'ab' * 32, circleId: 'c1');
    expect(s1, isNot(s2)); // 每次新的临时密钥 + nonce
    expect(await anonUnseal(agentSeed: kSealAgentSeed, sealed: s1, circleId: 'c1'), 'ab' * 32);
    // circleId 进了 HKDF info 和 AAD:换圈解不开
    await expectLater(
      anonUnseal(agentSeed: kSealAgentSeed, sealed: s1, circleId: 'c2'),
      throwsA(anything),
    );
    final List<int> bad = base64.decode(kSealed)..[50] ^= 1;
    await expectLater(
      anonUnseal(agentSeed: kSealAgentSeed, sealed: base64.encode(bad), circleId: kSealCircle),
      throwsA(anything),
    );
    final List<int> v2 = base64.decode(kSealed)..[0] = 2;
    await expectLater(
      anonUnseal(agentSeed: kSealAgentSeed, sealed: base64.encode(v2), circleId: kSealCircle),
      throwsA(anything),
    );
  });

  test('parseX25519Pub accepts b64 / url-b64 / hex, rejects wrong length', () {
    const String b64 = 'e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=';
    expect(parseX25519Pub(b64), kSealAgentPub);
    expect(parseX25519Pub(b64.replaceAll('=', '')), kSealAgentPub);
    expect(
      parseX25519Pub(b64.replaceAll('+', '-').replaceAll('/', '_')),
      kSealAgentPub,
    );
    final String hex =
        kSealAgentPub.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(parseX25519Pub(hex), kSealAgentPub);
    expect(parseX25519Pub('AAAA'), isNull);
    expect(parseX25519Pub('!!!'), isNull);
    expect(parseX25519Pub(42), isNull);
    expect(parseX25519Pub(''), isNull);
  });
}