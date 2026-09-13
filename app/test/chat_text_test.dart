import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/chat/chat_text.dart';

/// 扫描 code unit:高代理(0xD800..0xDBFF)必须紧跟低代理(0xDC00..0xDFFF),
/// 低代理必须紧跟在高代理之后。任一不成立即返回 false(存在孤立代理)。
bool hasNoLoneSurrogate(String value) {
  final List<int> units = value.codeUnits;
  for (int i = 0; i < units.length; i++) {
    final int u = units[i];
    final bool isHigh = u >= 0xD800 && u <= 0xDBFF;
    final bool isLow = u >= 0xDC00 && u <= 0xDFFF;
    if (isHigh) {
      if (i + 1 >= units.length) return false;
      final int next = units[i + 1];
      if (next < 0xDC00 || next > 0xDFFF) return false;
      i++; // 成对,跳过低位
      continue;
    }
    if (isLow) return false; // 低代理未被高代理消费 = 孤立
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('文字规整与截断', () {
    test('CJK 与 emoji 不被截断', () {
      // 前 4 个是 CJK(各 1 code unit),第 5 个字素是 ZWJ 家庭序列,
      // 其首个码点 U+1F468 是代理对 —— 于是 code unit 下标 5 恰好劈开它。
      const String s = '你好世界👨‍👩‍👧‍👦中文🇨🇳测试';
      const int k = 5;

      // 前置事实:共 10 个字素,k 同时是合法的字素数与 code unit 下标
      expect(s.characters.length, 10);
      expect(k <= s.characters.length, isTrue);
      expect(k <= s.length, isTrue);

      final String capped = capGraphemes(s, k);

      // 1. 字素数恰好为 k
      expect(capped.characters.length, k);
      // 2. 是原串的「字素前缀」
      expect(s.characters.take(k).toString(), capped);
      // 家庭 emoji 被整体保留,而不是留半个
      expect(capped, '你好世界👨‍👩‍👧‍👦');
      // 3. 结果中没有孤立代理
      expect(hasNoLoneSurrogate(capped), isTrue);

      // 4. 证明本测试有意义:朴素 substring 会切出不同且损坏的结果
      final String naive = s.substring(0, k);
      expect(naive, isNot(capped));
      expect(hasNoLoneSurrogate(naive), isFalse);
      // 朴素切法末位正是一个孤立高代理
      expect(naive.codeUnits.last >= 0xD800 && naive.codeUnits.last <= 0xDBFF,
          isTrue);

      // 旗帜同理:第 8 个字素是 🇨🇳(两个区域指示符,共 4 code unit)
      final String flagCapped = capGraphemes(s, 8);
      expect(flagCapped.characters.length, 8);
      expect(flagCapped.endsWith('🇨🇳'), isTrue);
      expect(hasNoLoneSurrogate(flagCapped), isTrue);
      expect(hasNoLoneSurrogate(s.substring(0, 8)), isFalse);
    });

    test('纯 CJK 精确截到 k 个字', () {
      const String cjk = '一二三四五六七八九十';
      expect(capGraphemes(cjk, 4), '一二三四');
      expect(graphemeCount(capGraphemes(cjk, 4)), 4);
      expect(capGraphemes(cjk, 10), cjk);
    });

    test('字素计数按簇而非 code unit', () {
      expect(graphemeCount('👨‍👩‍👧‍👦'), 1);
      expect(graphemeCount('🇨🇳'), 1);
      expect(graphemeCount('你好'), 2);
      expect(graphemeCount(''), 0);
      // 对照:code unit 口径会数出一大堆
      expect('👨‍👩‍👧‍👦'.length, greaterThan(1));
    });

    test('截断边界:非正数返回空串、未超限原样返回', () {
      const String s = '你好👨‍👩‍👧‍👦';
      expect(capGraphemes(s, 0), '');
      expect(capGraphemes(s, -5), '');
      expect(capGraphemes('abc', 100), 'abc');
      expect(capGraphemes('', 5), '');
      expect(capGraphemes(s, 3), s); // 恰好等于上限
    });

    test('空消息规整:空/纯空白返回 null', () {
      expect(normalizeOutgoing(''), isNull);
      expect(normalizeOutgoing('   '), isNull);
      expect(normalizeOutgoing('\n\t '), isNull);
      expect(normalizeOutgoing('\u3000'), isNull); // 全角空格
      // 有内容则裁掉首尾空白
      expect(normalizeOutgoing('  你好  '), '你好');
      expect(normalizeOutgoing('a'), 'a');
    });
  });
}
