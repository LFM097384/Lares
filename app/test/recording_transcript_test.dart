import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/recording/transcript_store.dart';

/// 构造一条转写,避免每个用例都写全参数。
TranscriptSegment seg({
  String identity = 'u-1',
  String name = '张三',
  String text = '你好',
  double? confidence,
  String backend = 'sherpa-onnx',
  int atSecond = 0,
}) {
  final DateTime start = DateTime.utc(2026, 5, 1, 10).add(
    Duration(seconds: atSecond),
  );
  return TranscriptSegment(
    startedAt: start,
    endedAt: start.add(const Duration(seconds: 2)),
    speakerIdentity: identity,
    speakerName: name,
    text: text,
    confidence: confidence,
    backend: backend,
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lares_transcript_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('JSONL 往返', () {
    test('单条往返保持全部字段', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      final TranscriptSegment s = seg(confidence: 0.87, text: '晚饭吃什么');

      await store.append(s, circleId: 'c1', sessionId: 's1');
      final TranscriptReadResult r = await store.read(
        circleId: 'c1',
        sessionId: 's1',
      );

      expect(r.skipped, 0);
      expect(r.segments, hasLength(1));
      expect(r.segments.single, equals(s));
      expect(r.segments.single.confidence, 0.87);
      expect(r.segments.single.backend, 'sherpa-onnx');
    });

    test('confidence 为 null 也能原样往返(不被伪造成 1.0)', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      await store.append(seg(), circleId: 'c1', sessionId: 's1');

      final TranscriptReadResult r = await store.read(
        circleId: 'c1',
        sessionId: 's1',
      );
      expect(r.segments.single.confidence, isNull);
    });

    test('多条按写入顺序读回', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      for (int i = 0; i < 5; i++) {
        await store.append(
          seg(text: '第 $i 句', atSecond: i * 3),
          circleId: 'c1',
          sessionId: 's1',
        );
      }

      final TranscriptReadResult r = await store.read(
        circleId: 'c1',
        sessionId: 's1',
      );
      expect(r.segments, hasLength(5));
      expect(r.skipped, 0);
      expect(r.segments.first.text, '第 0 句');
      expect(r.segments.last.text, '第 4 句');
    });

    test('追加写不覆盖已有内容(重新打开 store 继续追加)', () async {
      await TranscriptStore(
        root: tmp,
      ).append(seg(text: '第一次'), circleId: 'c1', sessionId: 's1');
      await TranscriptStore(
        root: tmp,
      ).append(seg(text: '第二次'), circleId: 'c1', sessionId: 's1');

      final TranscriptReadResult r = await TranscriptStore(
        root: tmp,
      ).read(circleId: 'c1', sessionId: 's1');
      expect(r.segments.map((TranscriptSegment s) => s.text), <String>[
        '第一次',
        '第二次',
      ]);
    });

    test('时刻以 UTC 落盘,跨时区读回仍指向同一瞬间', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      final TranscriptSegment s = seg();
      await store.append(s, circleId: 'c1', sessionId: 's1');

      final File f = store.fileFor(circleId: 'c1', sessionId: 's1');
      expect(f.readAsStringSync(), contains('Z'));

      final TranscriptReadResult r = await store.read(
        circleId: 'c1',
        sessionId: 's1',
      );
      expect(
        r.segments.single.startedAt.isAtSameMomentAs(s.startedAt),
        isTrue,
      );
    });

    test('读一个不存在的会话返回空结果而不是抛异常', () async {
      final TranscriptReadResult r = await TranscriptStore(
        root: tmp,
      ).read(circleId: 'nope', sessionId: 'nope');
      expect(r.isEmpty, isTrue);
      expect(r.skipped, 0);
    });
  });

  group('坏行容错', () {
    test('中间夹一行畸形 JSON 不影响其余行,并被计数', () {
      final String content = <String>[
        _line(seg(text: 'A')),
        '{这不是合法 JSON',
        _line(seg(text: 'B')),
      ].join('\n');

      final TranscriptReadResult r = parseJsonl(content);
      expect(r.segments, hasLength(2));
      expect(r.skipped, 1);
      expect(r.segments.map((TranscriptSegment s) => s.text), <String>[
        'A',
        'B',
      ]);
    });

    test('末行被截断(模拟崩溃)时前面的完好行全部返回', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      for (int i = 0; i < 3; i++) {
        await store.append(
          seg(text: '句子 $i', atSecond: i),
          circleId: 'c1',
          sessionId: 's1',
        );
      }

      // 直接截断文件尾部,精确模拟"写到一半进程被杀"
      final File f = store.fileFor(circleId: 'c1', sessionId: 's1');
      final String full = f.readAsStringSync();
      f.writeAsStringSync(full.substring(0, full.length - 30));

      final TranscriptReadResult r = await store.read(
        circleId: 'c1',
        sessionId: 's1',
      );
      expect(r.segments, hasLength(2));
      expect(r.skipped, 1, reason: '崩溃留下的半行应当恰好被跳过一行');
      expect(r.segments.last.text, '句子 1');
    });

    test('合法 JSON 但字段类型不对的行被跳过', () {
      final String content = <String>[
        _line(seg(text: 'A')),
        '{"startedAt":123,"endedAt":"x","speakerIdentity":"u",'
            '"speakerName":"n","text":"t","backend":"b"}',
        '{"startedAt":"2026-05-01T10:00:00Z","endedAt":"2026-05-01T10:00:02Z",'
            '"speakerIdentity":"u","speakerName":"n","text":"t",'
            '"confidence":"高","backend":"b"}',
        _line(seg(text: 'B')),
      ].join('\n');

      final TranscriptReadResult r = parseJsonl(content);
      expect(r.segments, hasLength(2));
      expect(r.skipped, 2);
    });

    test('缺字段的行被跳过', () {
      final TranscriptReadResult r = parseJsonl(
        '{"startedAt":"2026-05-01T10:00:00Z"}',
      );
      expect(r.segments, isEmpty);
      expect(r.skipped, 1);
    });

    test('空行不计为坏行', () {
      final String content = '${_line(seg())}\n\n\n${_line(seg())}\n';
      final TranscriptReadResult r = parseJsonl(content);
      expect(r.segments, hasLength(2));
      expect(r.skipped, 0);
    });

    test('全是坏行时返回空结果并如实计数', () {
      final TranscriptReadResult r = parseJsonl('x\ny\nz');
      expect(r.segments, isEmpty);
      expect(r.skipped, 3);
    });
  });

  group('文件名与路径', () {
    test('按 <circleId>/<sessionId>.jsonl 组织', () {
      final File f = TranscriptStore(
        root: tmp,
      ).fileFor(circleId: 'circle-a', sessionId: 'sess-1');

      expect(f.path, startsWith(tmp.path));
      expect(f.path, endsWith('sess-1.jsonl'));
      expect(f.parent.path, endsWith('circle-a'));
    });

    test('危险字符被清洗,不会发生目录穿越', () {
      expect(sanitizeIdComponent('../../etc/passwd'), isNot(contains('..')));
      expect(sanitizeIdComponent('../../etc/passwd'), isNot(contains('/')));
      expect(sanitizeIdComponent('a/b\\c'), 'a_b_c');
      expect(sanitizeIdComponent('a:b*c?'), 'a_b_c_');
      expect(sanitizeIdComponent(''), '_');
    });

    test('Windows 保留设备名被加前缀绕开', () {
      expect(sanitizeIdComponent('CON'), '_CON');
      expect(sanitizeIdComponent('nul'), '_nul');
      expect(sanitizeIdComponent('COM1'), '_COM1');
    });

    test('超长 id 被截断到可写长度', () {
      expect(sanitizeIdComponent('a' * 500).length, lessThanOrEqualTo(64));
    });

    test('中文 id 被清洗成下划线但仍可写入读回', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      await store.append(seg(), circleId: '家里人', sessionId: '晚饭局');

      final TranscriptReadResult r = await store.read(
        circleId: '家里人',
        sessionId: '晚饭局',
      );
      expect(r.segments, hasLength(1));
    });

    test('listSessions 列出该圈子下的会话', () async {
      final TranscriptStore store = TranscriptStore(root: tmp);
      await store.append(seg(), circleId: 'c1', sessionId: 's-b');
      await store.append(seg(), circleId: 'c1', sessionId: 's-a');
      await store.append(seg(), circleId: 'c2', sessionId: 's-z');

      expect(await store.listSessions('c1'), <String>['s-a', 's-b']);
      expect(await store.listSessions('c2'), <String>['s-z']);
      expect(await store.listSessions('c3'), isEmpty);
    });
  });

  group('Markdown 导出', () {
    test('包含说话人名字与正文', () {
      final String md = exportTranscriptMarkdown(<TranscriptSegment>[
        seg(name: '张三', text: '今天下雨了'),
        seg(identity: 'u-2', name: '李四', text: '带伞了吗', atSecond: 5),
      ], title: '晚饭局');

      expect(md, contains('晚饭局'));
      expect(md, contains('张三'));
      expect(md, contains('李四'));
      expect(md, contains('今天下雨了'));
      expect(md, contains('带伞了吗'));
    });

    test('连续同一说话人只出现一次名字', () {
      final String md = exportTranscriptMarkdown(<TranscriptSegment>[
        seg(text: '第一句'),
        seg(text: '第二句', atSecond: 3),
        seg(text: '第三句', atSecond: 6),
      ], toLocal: false);

      expect('张三'.allMatches(md).length, 1, reason: '同一说话人的名字被重复打印了');
      expect(md, contains('第一句'));
      expect(md, contains('第三句'));
    });

    test('说话人交替时名字重新出现', () {
      final String md = exportTranscriptMarkdown(<TranscriptSegment>[
        seg(text: 'a'),
        seg(identity: 'u-2', name: '李四', text: 'b', atSecond: 3),
        seg(text: 'c', atSecond: 6),
      ], toLocal: false);

      expect('张三'.allMatches(md).length, 2);
      expect('李四'.allMatches(md).length, 1);
    });

    test('同一人中途改昵称不会被拆成两个人(按 identity 分组)', () {
      final String md = exportTranscriptMarkdown(<TranscriptSegment>[
        seg(name: '张三', text: 'a'),
        seg(name: '张三(新昵称)', text: 'b', atSecond: 3),
      ], toLocal: false);

      // identity 相同 -> 只起一个小节,后一条的新昵称不再单独成节
      expect('## '.allMatches(md).length, 1);
    });

    test('空转写稿给出明确提示而不是空字符串', () {
      expect(
        exportTranscriptMarkdown(const <TranscriptSegment>[]),
        contains('没有转写内容'),
      );
    });

    test('时间戳按 HH:MM:SS 呈现', () {
      expect(formatClock(DateTime.utc(2026, 1, 1, 9, 5, 3)), '09:05:03');
      final String md = exportTranscriptMarkdown(<TranscriptSegment>[
        seg(),
      ], toLocal: false);
      expect(md, contains('10:00:00'));
    });
  });

  group('值类型语义', () {
    test('TranscriptSegment 相等性与 copyWith', () {
      final TranscriptSegment a = seg(confidence: 0.5);
      final TranscriptSegment b = seg(confidence: 0.5);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(a.copyWith(text: '别的'))));
      expect(a.copyWith(text: '别的').speakerIdentity, a.speakerIdentity);
      expect(a.duration, const Duration(seconds: 2));
      expect(a.toString(), contains('sherpa-onnx'));
    });

    test('TranscriptReadResult 是值类型', () {
      expect(
        parseJsonl(_line(seg())),
        equals(parseJsonl(_line(seg()))),
      );
      expect(parseJsonl('').toString(), contains('skipped: 0'));
    });
  });
}

/// 把一条转写序列化成单行 JSON(与落盘格式一致)。
String _line(TranscriptSegment s) => jsonEncode(s.toJson());
