import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/purpose/purpose_code.dart';
import 'package:lares_app/src/purpose/purpose_schema.dart';

import 'helpers/localized_app.dart';

/// 用途分享码 + 客户端校验(features-purpose-contract §3.1 / §3.3)。
void main() {
  group('分享码', () {
    test('往返:含中文和 emoji', () {
      final p = <String, dynamic>{
        'v': 1,
        'id': 'family-時間',
        'name': '一家人 👨‍👩‍👧',
        'icon': '🏠',
        'features': {'focus': true, 'map': false},
        'plugins': [
          {'id': 'lares.focus', 'enabled': true, 'config': {'minutes': 25}},
        ],
      };
      final code = encodePurposeCode(p);
      expect(code, startsWith(kPurposeCodePrefix));
      expect(code, matches(RegExp(r'^lares-purpose:[A-Za-z0-9_-]+$')));
      expect(decodePurposeCode(code), p);
    });

    test('解得开 Node(zlib.gzipSync + base64url)编出来的码', () {
      // node -e "const z=require('zlib');const j=JSON.stringify({id:'x',name:'测试',features:{focus:true}});console.log('lares-purpose:'+z.gzipSync(Buffer.from(j)).toString('base64url'))"
      const node =
          'lares-purpose:H4sIAAAAAAAACqtWykxRslKqUNJRykvMTVWyUnq2tfvF-qlKOkppqYklpUWpxUpW1Upp-cmlxUpWJUWlqbW1AMjUe840AAAA';
      expect(decodePurposeCode(node), {
        'id': 'x',
        'name': '测试',
        'features': {'focus': true},
      });
    });

    test('宽容:前后空白、夹在一段话里、带换行、带 = 填充', () {
      final code = encodePurposeCode({'id': 'a', 'name': 'b'});
      expect(decodePurposeCode('  $code\n'), {'id': 'a', 'name': 'b'});
      expect(decodePurposeCode('试试这个:$code 好用'), {'id': 'a', 'name': 'b'});
      final body = code.substring(kPurposeCodePrefix.length);
      final wrapped =
          '$kPurposeCodePrefix${body.substring(0, 10)}\n${body.substring(10)}';
      expect(decodePurposeCode(wrapped), {'id': 'a', 'name': 'b'});
    });

    PurposeCodeErrorKind kindOf(String s) {
      try {
        decodePurposeCode(s);
      } on PurposeCodeException catch (e) {
        return e.kind;
      }
      fail('应该解不开: $s');
    }

    test('前缀不对', () {
      expect(kindOf('lares-plugin:abc'), PurposeCodeErrorKind.prefix);
      expect(kindOf('{"id":"x"}'), PurposeCodeErrorKind.prefix);
      expect(kindOf(''), PurposeCodeErrorKind.prefix);
    });

    test('乱码:不是 gzip / base64 坏了', () {
      expect(kindOf('lares-purpose:aGVsbG8gd29ybGQ'),
          anyOf(PurposeCodeErrorKind.gzip, PurposeCodeErrorKind.base64));
      expect(kindOf('lares-purpose:A'),
          anyOf(PurposeCodeErrorKind.gzip, PurposeCodeErrorKind.base64));
      // 截断的真码
      final code = encodePurposeCode({'id': 'a', 'name': 'b' * 50});
      expect(kindOf(code.substring(0, code.length ~/ 2)),
          anyOf(PurposeCodeErrorKind.gzip, PurposeCodeErrorKind.base64));
    });

    test('解压后太大(gzip 炸弹)', () {
      final big = utf8.encode('{"id":"x","name":"${'a' * (200 * 1024)}"}');
      final gz = GZipEncoder().encodeBytes(big);
      final code = '$kPurposeCodePrefix${base64Url.encode(gz).replaceAll('=', '')}';
      expect(kindOf(code), PurposeCodeErrorKind.tooLarge);
      // 33KB:解压没超 64KB 上限,但 JSON 超 32KB
      final mid = utf8.encode('{"id":"x","name":"${'a' * (33 * 1024)}"}');
      final code2 =
          '$kPurposeCodePrefix${base64Url.encode(GZipEncoder().encodeBytes(mid))}';
      expect(kindOf(code2), PurposeCodeErrorKind.tooLarge);
    });

    test('不是 JSON 对象', () {
      String enc(String s) =>
          '$kPurposeCodePrefix${base64Url.encode(GZipEncoder().encodeBytes(utf8.encode(s)))}';
      expect(kindOf(enc('[1,2]')), PurposeCodeErrorKind.notObject);
      expect(kindOf(enc('not json')), PurposeCodeErrorKind.json);
    });

    test('给 Node 交叉校验用:LARES_PURPOSE_CODE_OUT 指定时把 Dart 编的码写出去', () {
      final out = Platform.environment['LARES_PURPOSE_CODE_OUT'];
      if (out == null) return;
      File(out).writeAsStringSync(encodePurposeCode({
        'id': 'x',
        'name': '测试 🎉',
        'features': {'focus': true},
      }));
    });
  });

  group('校验', () {
    final t = zhStrings();

    List<String> errs(Object? p) =>
        validatePurpose(p).map((i) => '${i.path}:${i.code.name}').toList();

    test('三个内置用途和模板都通过', () {
      for (final b in builtinPurposes(t)) {
        expect(validatePurpose(b.json), isEmpty, reason: b.id);
      }
      expect(validatePurpose(purposeTemplate(t)), isEmpty);
      expect(builtinPurposes(t).map((b) => b.id), ['chat', 'study', 'meeting']);
      expect(builtinPurposes(t).map((b) => b.icon), ['💬', '📚', '📝']);
    });

    test('顶层', () {
      expect(errs([1]), [r'$:notObject']);
      expect(errs({'id': 'a', 'name': 'b', 'extra': 1}), ['extra:unknownKey']);
      expect(errs({'v': 2, 'id': 'a', 'name': 'b'}), ['v:version']);
      expect(errs({'name': 'b'}), ['id:id']);
      expect(errs({'id': 'A', 'name': 'b'}), ['id:id']);
      expect(errs({'id': '-a', 'name': 'b'}), ['id:id']);
      expect(errs({'id': 'a' * 33, 'name': 'b'}), ['id:id']);
      expect(errs({'id': 'a' * 32, 'name': 'b'}), isEmpty);
      expect(errs({'id': 'a'}), ['name:name']);
      expect(errs({'id': 'a', 'name': '   '}), ['name:name']);
      expect(errs({'id': 'a', 'name': '😀' * 24}), isEmpty);
      expect(errs({'id': 'a', 'name': '😀' * 25}), ['name:name']);
      expect(errs({'id': 'a', 'name': 'b', 'icon': '🙂' * 9}), ['icon:icon']);
      expect(errs({'id': 'a', 'name': 'b', 'description': 'x' * 201}),
          ['description:description']);
      expect(errs({'id': 'a', 'name': 'x' * 40000}), [r'$:tooLarge']);
    });

    test('features / settings', () {
      final base = {'id': 'a', 'name': 'b'};
      expect(errs({...base, 'features': <Object>[]}), ['features:notObjectField']);
      expect(errs({...base, 'features': {'x': true}}), ['features.x:unknownKey']);
      expect(errs({...base, 'features': {'map': 1}}), ['features.map:notBool']);
      expect(errs({...base, 'settings': {'foo': true}}),
          ['settings.foo:unknownKey']);
      expect(errs({...base, 'settings': {'knockRequired': 'yes'}}),
          ['settings.knockRequired:notBool']);
      expect(
          errs({
            ...base,
            'features': {'transcript': true},
            'settings': {'transcript': false},
          }),
          ['settings.transcript:conflict']);
    });

    test('plugins', () {
      final base = {'id': 'a', 'name': 'b'};
      expect(errs({...base, 'plugins': <String, Object>{}}), ['plugins:notArray']);
      expect(
          errs({
            ...base,
            'plugins': [for (var i = 0; i < 11; i++) {'id': 'p.n$i'}],
          }),
          ['plugins:tooManyPlugins']);
      expect(errs({...base, 'plugins': [1]}), ['plugins[0]:notObjectField']);
      expect(
          errs({
            ...base,
            'plugins': [
              {'id': 'lares.focus'},
              {'id': 'x.y', 'manifestUrl': 'https://a.b/m.json'},
            ],
          }),
          ['plugins[1]:pluginSource']);
      expect(
          errs({
            ...base,
            'plugins': [{'enabled': true}],
          }),
          ['plugins[0]:pluginSource']);
      expect(
          errs({
            ...base,
            'plugins': [
              {'id': 'lares.focus'},
              {'manifestUrl': 'http://a.b/m.json'},
            ],
          }),
          ['plugins[1].manifestUrl:manifestUrl']);
      expect(
          errs({
            ...base,
            'plugins': [{'id': 'lares.focus', 'enabled': 'y'}],
          }),
          ['plugins[0].enabled:notBool']);
      expect(
          errs({
            ...base,
            'plugins': [{'id': 'lares.focus', 'oops': 1}],
          }),
          ['plugins[0].oops:unknownKey']);
      expect(
          errs({
            ...base,
            'plugins': [
              {'id': 'lares.focus', 'config': {'k': 'x' * 5000}},
            ],
          }),
          ['plugins[0].config:configTooLarge']);
      expect(
          errs({
            ...base,
            'plugins': [{'id': 'lares.focus'}, {'id': 'lares.focus'}],
          }),
          ['plugins[1]:duplicate']);
      expect(
          errs({
            ...base,
            'features': {'focus': false},
            'plugins': [{'id': 'lares.focus'}],
          }),
          ['plugins[0].enabled:conflict']);
      expect(
          errs({
            ...base,
            'features': {'focus': false},
            'plugins': [{'id': 'lares.focus', 'enabled': false}],
          }),
          isEmpty);
    });

    test('manifest 轻量检查', () {
      Map<String, dynamic> m([Map<String, dynamic> over = const {}]) => {
            'id': 'com.example.x',
            'name': 'X',
            'version': '1.0.0',
            'author': 'me',
            'permissions': ['circle.read'],
            ...over,
          };
      List<String> e(Object? manifest) => errs({
            'id': 'a',
            'name': 'b',
            'plugins': [{'manifest': manifest}],
          });
      expect(e(m()), isEmpty);
      expect(e('x'), ['plugins[0].manifest:manifest']);
      expect(validatePurpose({
        'id': 'a',
        'name': 'b',
        'plugins': [{'manifest': m({'author': ''})}],
      }).single.field, 'author');
      expect(validatePurpose({
        'id': 'a',
        'name': 'b',
        'plugins': [{'manifest': m({'permissions': [1]})}],
      }).single.field, 'permissions');
      expect(validatePurpose({
        'id': 'a',
        'name': 'b',
        'plugins': [{'manifest': m()..remove('version')}],
      }).single.field, 'version');
    });

    test('JSON 语法错误给出行列', () {
      const text = '{\n  "id": "a",\n  "name": "b",,\n}';
      final r = validatePurposeText(text);
      expect(r.purpose, isNull);
      final i = r.issues.single;
      expect(i.code, PurposeIssueCode.syntax);
      expect(i.line, 3);
      expect(i.column, greaterThan(1));
      expect(purposeIssueMessage(t, i), contains('第 3 行'));
    });

    test('结构错误定位到行', () {
      const text = '{\n  "id": "a",\n  "name": "b",\n  "plugins": [\n'
          '    {"id": "lares.focus"},\n    {"manifestUrl": "http://x"}\n  ]\n}';
      final r = validatePurposeText(text);
      final i = r.issues.single;
      expect(i.path, 'plugins[1].manifestUrl');
      expect(i.line, 6);
      expect(validatePurposeText('{"id":"a","name":"b"}').purpose,
          {'id': 'a', 'name': 'b'});
    });

    test('每个错误都有本地化说明', () {
      for (final c in PurposeIssueCode.values) {
        expect(purposeIssueMessage(t, PurposeIssue('x', c, field: 'f')),
            isNotEmpty);
      }
    });
  });
}
