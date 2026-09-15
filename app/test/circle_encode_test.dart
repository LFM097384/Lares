import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/state/circle_store.dart';

/// `Circle` 的编解码测试。
///
/// 这个文件存在的理由只有一个:**加字段不能弄坏老数据**。
/// 圈子列表存在 shared_preferences 里,用户升级 App 时那些字符串原样还在。
void main() {
  group('编解码往返', () {
    test('不带 serverId', () {
      const c = Circle(id: 'home', name: '我们的圈');
      final back = Circle.decode(c.encode())!;
      expect(back.id, 'home');
      expect(back.name, '我们的圈');
      expect(back.serverId, isNull);
    });

    test('带 serverId', () {
      const c = Circle(id: 'jia', name: '家里', serverId: 'p2');
      final back = Circle.decode(c.encode())!;
      expect(back.id, 'jia');
      expect(back.name, '家里');
      expect(back.serverId, 'p2');
    });
  });

  group('向后兼容(会真出问题的地方)', () {
    test('老格式(两段,无 serverId)照样能读', () {
      // 这就是升级前存在磁盘上的样子
      final back = Circle.decode('home\n我们的圈')!;
      expect(back.id, 'home');
      expect(back.name, '我们的圈');
      expect(back.serverId, isNull, reason: 'null = 跟当前服务器走,与升级前一致');
    });

    test('⚠️ 名字里含换行的老数据不会被拆坏', () {
      // 老实现用 indexOf 只切第一个 \n,所以名字里的换行一直是合法的。
      // 如果把 serverId 追加到末尾,这条数据的最后一行会被误当成 serverId。
      final back = Circle.decode('home\n第一行\n第二行')!;
      expect(back.id, 'home');
      expect(back.name, '第一行\n第二行');
      expect(back.serverId, isNull, reason: '绝不能把名字的一部分当成服务器 id');
    });

    test('名字含换行 + 有 serverId,两者都不串味', () {
      const c = Circle(id: 'jia', name: '第一行\n第二行', serverId: 'p2');
      final back = Circle.decode(c.encode())!;
      expect(back.name, '第一行\n第二行');
      expect(back.serverId, 'p2');
    });
  });

  group('坏数据', () {
    test('空串、无分隔符、空 id 一律返回 null 而不是崩', () {
      expect(Circle.decode(''), isNull);
      expect(Circle.decode('没有换行'), isNull);
      expect(Circle.decode('\n只有名字'), isNull);
    });

    test('只有 serverId 头、没有正文,也返回 null', () {
      expect(Circle.decode('@srv=p1'), isNull);
    });
  });

  group('copyWith', () {
    test('只改名字,serverId 保留', () {
      const c = Circle(id: 'jia', name: '旧名', serverId: 'p2');
      final n = c.copyWith(name: '新名');
      expect(n.name, '新名');
      expect(n.serverId, 'p2');
      expect(n.id, 'jia');
    });
  });
}
