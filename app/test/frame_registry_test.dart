import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/frame_registry.dart';

IncomingFrame _frame(String type, {Map<String, dynamic>? header}) =>
    IncomingFrame(
      type: type,
      header: header ?? <String, dynamic>{'t': type},
      payload: Uint8List(0),
    );

void main() {
  group('帧分发', () {
    test('注册过的类型会被交给对应处理器', () {
      final r = FrameRegistry();
      IncomingFrame? got;
      r.register('text', (f) => got = f);

      expect(r.dispatch(_frame('text')), isTrue);
      expect(got?.type, 'text');
    });

    test('未知类型被静默忽略,不抛异常', () {
      // 这不是容错,是协议设计:对方可能装了我们没有的插件。
      final r = FrameRegistry();
      expect(() => r.dispatch(_frame('x/com.nobody.thing')), returnsNormally);
      expect(r.dispatch(_frame('x/com.nobody.thing')), isFalse);
    });

    test('各类型互不串台', () {
      final r = FrameRegistry();
      final hits = <String>[];
      r.register('text', (_) => hits.add('text'));
      r.register('img', (_) => hits.add('img'));

      r.dispatch(_frame('img'));
      r.dispatch(_frame('text'));
      r.dispatch(_frame('img'));

      expect(hits, ['img', 'text', 'img']);
    });

    test('注销之后不再分发', () {
      final r = FrameRegistry();
      var n = 0;
      r.register('text', (_) => n++);
      r.dispatch(_frame('text'));
      expect(r.unregister('text'), isTrue);
      r.dispatch(_frame('text'));
      expect(n, 1);
      expect(r.unregister('text'), isFalse, reason: '重复注销返回 false');
    });
  });

  group('注册的约束', () {
    test('重复注册同一类型直接抛错 —— 绝不静默覆盖', () {
      // 这是安全边界,不是配置问题:静默覆盖意味着后加载的插件
      // 能接管 `text`,把所有聊天内容劫持走。
      final r = FrameRegistry();
      r.register('text', (_) {});
      expect(() => r.register('text', (_) {}), throwsStateError);
    });

    test('劫持内核类型同样被拒', () {
      final r = FrameRegistry();
      r.register('text', (_) {});
      expect(
        () => r.register('text', (_) {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('劫持'),
          ),
        ),
      );
    });

    test('空类型名被拒', () {
      final r = FrameRegistry();
      expect(() => r.register('', (_) {}), throwsArgumentError);
    });
  });

  group('caps 上报', () {
    test('registeredTypes 反映当前注册情况', () {
      final r = FrameRegistry();
      expect(r.registeredTypes, isEmpty);
      r.register('text', (_) {});
      r.register('x/com.example.chess', (_) {});
      expect(r.registeredTypes, containsAll(['text', 'x/com.example.chess']));
    });

    test('registeredTypes 是只读的 —— 拿去塞 JSON 不该能反改注册表', () {
      final r = FrameRegistry();
      r.register('text', (_) {});
      expect(() => r.registeredTypes.add('img'), throwsUnsupportedError);
    });

    test('supports 与 registeredTypes 一致', () {
      final r = FrameRegistry();
      r.register('text', (_) {});
      expect(r.supports('text'), isTrue);
      expect(r.supports('img'), isFalse);
    });
  });

  group('命名空间', () {
    test('x/ 前缀区分插件类型与内核类型', () {
      expect(isPluginType('x/com.example.chess'), isTrue);
      expect(isPluginType('text'), isFalse);
      expect(isPluginType('img'), isFalse);
    });

    test('合法的插件类型', () {
      expect(isValidPluginType('x/com.example.chess'), isTrue);
      expect(isValidPluginType('x/org.lares.file-transfer'), isTrue);
      expect(isValidPluginType('x/io.github.user_name.thing'), isTrue);
    });

    test('不合法的插件类型', () {
      // 没有 x/ 前缀
      expect(isValidPluginType('com.example.chess'), isFalse);
      // 前缀后面空的
      expect(isValidPluginType('x/'), isFalse);
      // 没有点,撞名风险高
      expect(isValidPluginType('x/chess'), isFalse);
      // 点在两端
      expect(isValidPluginType('x/.example'), isFalse);
      expect(isValidPluginType('x/example.'), isFalse);
      // 含空白 —— JSON 里易出错
      expect(isValidPluginType('x/com.example chess'), isFalse);
      // 含斜杠 —— 会和前缀混淆
      expect(isValidPluginType('x/com.example/chess'), isFalse);
    });

    test('内核类型不带 x/,所以插件永远撞不上将来新增的内核类型', () {
      // 这条是命名空间存在的全部理由,值得单独钉一下
      for (final core in ['text', 'img', 'file', 'video', 'location']) {
        expect(isPluginType(core), isFalse, reason: '$core 不该被当成插件类型');
      }
    });
  });
}
