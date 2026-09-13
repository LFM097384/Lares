import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_message.dart';
import 'package:lares_app/src/moderation/block_store.dart';
import 'package:lares_app/src/moderation/blocked_message_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一条消息,只关心 senderId / senderName / isMine 三个字段
ChatMessage msg({
  required String id,
  required String senderId,
  required String senderName,
  bool isMine = false,
}) =>
    ChatMessage.text(
      id: id,
      senderId: senderId,
      senderName: senderName,
      circleId: 'home',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      body: '你好',
      isMine: isMine,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('BlockStore 基本行为', () {
    test('屏蔽与解除屏蔽', () async {
      final store = await BlockStore.load();
      expect(store.count, 0);
      expect(store.isBlocked('u_aaa'), isFalse);

      await store.block('u_aaa');
      expect(store.isBlocked('u_aaa'), isTrue);
      expect(store.count, 1);

      await store.unblock('u_aaa');
      expect(store.isBlocked('u_aaa'), isFalse);
      expect(store.count, 0);
    });

    test('重启后名单还在', () async {
      final store = await BlockStore.load();
      await store.block('u_aaa');
      await store.block('u_bbb');

      final reloaded = await BlockStore.load();
      expect(reloaded.isBlocked('u_aaa'), isTrue);
      expect(reloaded.isBlocked('u_bbb'), isTrue);
      expect(reloaded.count, 2);
      expect(reloaded.isBlocked('u_ccc'), isFalse);
    });

    test('空 id 永远不算被屏蔽', () async {
      final store = await BlockStore.load();
      await store.block('');
      await store.block('   ');
      expect(store.count, 0);
      expect(store.isBlocked(''), isFalse);
      expect(store.isBlocked('   '), isFalse);

      // 名单里有人时,空 id 仍然不能命中(不能一个空串屏蔽所有人)
      await store.block('u_aaa');
      expect(store.isBlocked(''), isFalse);
    });

    test('blockedIds 是只读视图', () async {
      final store = await BlockStore.load();
      await store.block('u_aaa');
      expect(store.blockedIds, <String>{'u_aaa'});
      expect(() => store.blockedIds.add('u_bbb'), throwsUnsupportedError);
    });

    test('clear 清空整张名单', () async {
      final store = await BlockStore.load();
      await store.block('u_aaa');
      await store.block('u_bbb');
      await store.clear();
      expect(store.count, 0);

      final reloaded = await BlockStore.load();
      expect(reloaded.count, 0);
    });
  });

  group('BlockStore 通知', () {
    test('屏蔽/解除各通知一次', () async {
      final store = await BlockStore.load();
      var calls = 0;
      store.addListener(() => calls++);

      await store.block('u_aaa');
      expect(calls, 1);

      await store.unblock('u_aaa');
      expect(calls, 2);
    });

    test('重复屏蔽同一个人不再通知', () async {
      final store = await BlockStore.load();
      var calls = 0;
      store.addListener(() => calls++);

      await store.block('u_aaa');
      await store.block('u_aaa');
      await store.block('u_aaa');
      expect(calls, 1);

      // 不在名单里的人解除屏蔽,同样是 no-op
      await store.unblock('u_zzz');
      expect(calls, 1);
    });
  });

  group('filterBlocked', () {
    test('屏蔽以稳定 identity 为键:改昵称不能绕过屏蔽', () async {
      final store = await BlockStore.load();
      await store.block('u_bad');

      // 同一个人,前后换了昵称
      final before = msg(id: 'm1', senderId: 'u_bad', senderName: '张三');
      final after = msg(id: 'm2', senderId: 'u_bad', senderName: '李四');
      // 另一个人,偏偏顶着被屏蔽者的旧昵称
      final impostor = msg(id: 'm3', senderId: 'u_good', senderName: '张三');

      final visible = filterBlocked(
        <ChatMessage>[before, after, impostor],
        store.isBlocked,
      );

      // 改昵称挡不住:两条都被过滤
      expect(visible.map((m) => m.id), <String>['m3']);
      // 同名不同 id 的无辜者没被误伤
      expect(visible.single.senderId, 'u_good');
    });

    test('自己的消息永远不过滤', () {
      final mine = msg(
        id: 'm1',
        senderId: 'u_me',
        senderName: '我',
        isMine: true,
      );
      final theirs = msg(id: 'm2', senderId: 'u_me', senderName: '我');

      // 连自己的 id 都在屏蔽名单里,isMine 的那条仍然留下
      final visible = filterBlocked(
        <ChatMessage>[mine, theirs],
        (String id) => id == 'u_me',
      );
      expect(visible.map((m) => m.id), <String>['m1']);
    });

    test('没屏蔽任何人时原样返回', () {
      final list = <ChatMessage>[
        msg(id: 'm1', senderId: 'u_a', senderName: '甲'),
        msg(id: 'm2', senderId: 'u_b', senderName: '乙'),
      ];
      final visible = filterBlocked(list, (String _) => false);
      expect(visible.map((m) => m.id), <String>['m1', 'm2']);
    });

    test('空 senderId 的消息不会被空串屏蔽项吞掉', () async {
      final store = await BlockStore.load();
      await store.block('u_aaa');
      final orphan = msg(id: 'm1', senderId: '', senderName: '');
      final visible = filterBlocked(<ChatMessage>[orphan], store.isBlocked);
      expect(visible.length, 1);
    });

    test('解除屏蔽后历史原样回来', () async {
      final store = await BlockStore.load();
      final list = <ChatMessage>[
        msg(id: 'm1', senderId: 'u_bad', senderName: '张三'),
        msg(id: 'm2', senderId: 'u_ok', senderName: '王五'),
      ];

      await store.block('u_bad');
      expect(filterBlocked(list, store.isBlocked).length, 1);

      await store.unblock('u_bad');
      expect(filterBlocked(list, store.isBlocked).length, 2);
    });
  });
}
