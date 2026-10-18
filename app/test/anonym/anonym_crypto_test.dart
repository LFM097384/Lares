import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/anonym/anonym_crypto.dart';

/// 固定种子测试向量(与 docs/plans/chatham/client-canonicalisation.md 一致)。
/// 已用 node:crypto + server/anonym-agent/core/crypto.mjs 交叉验证过。
const String kVectorPub = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const String kVectorMsg =
    '{"draftHash":"h","draftId":"d1","nonce":"AAECAwQFBgcICQoLDA0ODw","sid":"S1"}';
const String kVectorSig =
    'C4fR1aepz6LZ0oEc5B+yelRCzW64Ujp43mSgWkayEd5lvwHWR91fWq3W1lHglmC+DCrocIpB7wue0EzI+ChTBQ==';

void main() {
  group('canonicalJson', () {
    test('sorts keys recursively, no whitespace, arrays keep order', () {
      expect(
        canonicalJson({
          'b': 1,
          'a': {'z': true, 'y': null},
          'c': [3, 1, {'k': 'v', 'j': 2.5}],
        }),
        '{"a":{"y":null,"z":true},"b":1,"c":[3,1,{"j":2.5,"k":"v"}]}',
      );
    });

    test('escapes like JSON.stringify; non-ASCII stays literal', () {
      expect(canonicalJson({'s': 'a"b\\c\n隐名 \u0001'}),
          '{"s":"a\\"b\\\\c\\n隐名 \\u0001"}');
    });

    test('sort is by code unit (uppercase before lowercase)', () {
      expect(canonicalJson({'b': 0, 'B': 0, 'a': 0}), '{"B":0,"a":0,"b":0}');
    });

    test('approvalMessage has the fixed key order', () {
      expect(
        approvalMessage(
            sid: 'S1', draftId: 'd1', draftHash: 'h', nonce: 'AAECAwQFBgcICQoLDA0ODw'),
        kVectorMsg,
      );
    });

    test('rejects non-finite numbers', () {
      expect(() => canonicalJson({'x': double.nan}), throwsA(anything));
    });
  });

  group('AnonymKeys', () {
    test('fixed-seed vector: pubKey and signature are deterministic', () {
      final keys = AnonymKeys.fromSeed(List<int>.generate(32, (i) => i));
      expect(keys.pubKeyB64, kVectorPub);
      expect(keys.sign(kVectorMsg), kVectorSig);
      expect(verifyApproval(kVectorPub, kVectorMsg, kVectorSig), isTrue);
    });

    test('verify rejects a tampered message or signature', () {
      expect(verifyApproval(kVectorPub, kVectorMsg.replaceAll('d1', 'd2'), kVectorSig),
          isFalse);
      final bad = base64.decode(kVectorSig)..[0] ^= 1;
      expect(verifyApproval(kVectorPub, kVectorMsg, base64.encode(bad)), isFalse);
      expect(verifyApproval('nope', kVectorMsg, kVectorSig), isFalse);
    });

    test('verify accepts base64url forms too', () {
      String url(String s) =>
          s.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      expect(verifyApproval(url(kVectorPub), kVectorMsg, url(kVectorSig)), isTrue);
    });

    test('generated keys sign and verify; wipe zeroes and disables', () {
      final keys = AnonymKeys.generate();
      expect(base64.decode(keys.pubKeyB64), hasLength(32));
      final sig = keys.sign('hello');
      expect(base64.decode(sig), hasLength(64));
      expect(verifyApproval(keys.pubKeyB64, 'hello', sig), isTrue);
      keys.wipe();
      expect(keys.wiped, isTrue);
      expect(() => keys.sign('hello'), throwsStateError);
    });

    test('two generated keys differ', () {
      expect(AnonymKeys.generate().pubKeyB64,
          isNot(AnonymKeys.generate().pubKeyB64));
    });
  });

  group('newNonce', () {
    test('16 bytes, base64url without padding', () {
      final n = newNonce();
      expect(n, hasLength(22));
      expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(n), isTrue);
      final padded = n.replaceAll('-', '+').replaceAll('_', '/');
      expect(base64.decode('$padded=='), hasLength(16));
    });

    test('injectable RNG is deterministic', () {
      expect(newNonce(Random(1)), newNonce(Random(1)));
    });
  });
}
