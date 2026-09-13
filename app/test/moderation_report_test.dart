import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/moderation/consent_store.dart';
import 'package:lares_app/src/moderation/content_policy_text.dart';
import 'package:lares_app/src/moderation/report.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 检查字符串里有没有落单的代理项(半个 emoji)。
/// 按 code unit 截断会造出这种字符,邮件里显示为乱码。
bool hasLoneSurrogate(String s) {
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    final isHigh = u >= 0xD800 && u <= 0xDBFF;
    final isLow = u >= 0xDC00 && u <= 0xDFFF;
    if (isHigh) {
      if (i + 1 >= units.length) return true;
      final next = units[i + 1];
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++; // 成对,跳过低位
    } else if (isLow) {
      return true; // 低位在前 = 落单
    }
  }
  return false;
}

ReportDraft makeDraft({
  String? messageId,
  String? messageExcerpt,
  String note = '他在语音里一直骂人',
  ReportReason reason = ReportReason.harassment,
}) {
  return ReportDraft(
    targetUserId: 'u_2k9fh3x1q',
    targetName: '老王',
    circleId: 'home',
    timestamp: DateTime.utc(2026, 3, 14, 9, 26, 53),
    reason: reason,
    note: note,
    messageId: messageId,
    messageExcerpt: messageExcerpt,
    reporterUserId: 'u_7dm4pz0aa',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConsentStore 同意状态', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('空存储:从未同意', () async {
      final store = await ConsentStore.load();
      expect(store.acceptedVersion, 0);
      expect(store.accepted, isFalse);
    });

    test('accept() 记下当前版本,并且跨 load() 保留', () async {
      final store = await ConsentStore.load();
      await store.accept();
      expect(store.acceptedVersion, ConsentStore.currentPolicyVersion);
      expect(store.accepted, isTrue);

      final reloaded = await ConsentStore.load();
      expect(reloaded.acceptedVersion, ConsentStore.currentPolicyVersion);
      expect(reloaded.accepted, isTrue);
    });

    test('revoke() 回到从未同意,并且落盘', () async {
      final store = await ConsentStore.load();
      await store.accept();
      await store.revoke();
      expect(store.acceptedVersion, 0);
      expect(store.accepted, isFalse);

      final reloaded = await ConsentStore.load();
      expect(reloaded.accepted, isFalse);
    });

    test('accept / revoke 都会 notifyListeners', () async {
      final store = await ConsentStore.load();
      var calls = 0;
      store.addListener(() => calls++);
      await store.accept();
      expect(calls, 1);
      await store.revoke();
      expect(calls, 2);
    });

    test('accepted 由「存的版本号 vs 当前版本号」决定', () async {
      // 存了一个比当前低的版本(模拟规范改版后的老用户)-> 需要重新同意
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lares.contentPolicyAcceptedVersion':
            ConsentStore.currentPolicyVersion - 1,
      });
      final stale = await ConsentStore.load();
      expect(stale.acceptedVersion, ConsentStore.currentPolicyVersion - 1);
      expect(stale.accepted, isFalse);

      // 存了一个更高的版本(降级安装)-> 仍算已同意,不该反复弹
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lares.contentPolicyAcceptedVersion':
            ConsentStore.currentPolicyVersion + 1,
      });
      final ahead = await ConsentStore.load();
      expect(ahead.accepted, isTrue);
    });
  });

  group('内容规范文案', () {
    test('标题、摘要、按钮文案都非空,条目 3-4 条', () {
      expect(kContentPolicyTitle.trim(), isNotEmpty);
      expect(kContentPolicySummary.trim(), isNotEmpty);
      expect(kContentPolicyAgreeLabel.trim(), isNotEmpty);
      expect(kContentPolicyDeclineLabel.trim(), isNotEmpty);
      expect(kContentPolicyPoints.length, inInclusiveRange(3, 4));
      for (final p in kContentPolicyPoints) {
        expect(p.title.trim(), isNotEmpty);
        expect(p.body.trim(), isNotEmpty);
      }
    });

    test('文案不出现「匿名」「随机」「陌生人」', () {
      final all = <String>[
        kContentPolicyTitle,
        kContentPolicySummary,
        kContentPolicyAgreeLabel,
        kContentPolicyDeclineLabel,
        for (final p in kContentPolicyPoints) '${p.title}\n${p.body}',
        for (final r in ReportReason.values) r.label,
      ].join('\n');
      for (final banned in ['匿名', '随机', '陌生人']) {
        expect(all, isNot(contains(banned)), reason: '出现了禁用词 $banned');
      }
    });

    test('覆盖 1.2 要求的承诺:零容忍、本人负责、移除、24 小时', () {
      final all = kContentPolicyPoints
          .map((p) => '${p.title}\n${p.body}')
          .join('\n');
      expect(all, contains('零容忍'));
      expect(all, contains('负责'));
      expect(all, contains('移出'));
      expect(all, contains('24 小时'));
      expect(all, contains('屏蔽'));
      expect(all, contains('举报'));
    });
  });

  group('举报分类', () {
    test('每个分类都有非空中文名,wire 用枚举名', () {
      for (final r in ReportReason.values) {
        expect(r.label.trim(), isNotEmpty, reason: '${r.name} 缺 label');
        expect(r.wire, r.name);
      }
    });
  });

  group('buildReportBody 正文', () {
    test('包含被举报者、圈子、理由、举报人', () {
      final body = buildReportBody(makeDraft());
      expect(body, contains('u_2k9fh3x1q'));
      expect(body, contains('老王'));
      expect(body, contains('home'));
      expect(body, contains(ReportReason.harassment.label));
      expect(body, contains('u_7dm4pz0aa'));
      expect(body, contains('2026-03-14T09:26:53'));
      expect(body, contains('24 小时'));
    });

    test('有消息上下文时带上消息 id 与摘录', () {
      final body = buildReportBody(makeDraft(
        messageId: 'm_88f2',
        messageExcerpt: '一段很难听的话',
      ));
      expect(body, contains('消息 ID: m_88f2'));
      expect(body, contains('消息摘录: 一段很难听的话'));
    });

    test('举报的是人而非消息时,整行省掉不留空标签', () {
      final body = buildReportBody(makeDraft());
      expect(body, isNot(contains('消息 ID')));
      expect(body, isNot(contains('消息摘录')));
    });

    test('补充说明为空时写「(无)」而不是空白', () {
      final body = buildReportBody(makeDraft(note: '   '));
      expect(body, contains('补充说明: (无)'));
    });
  });

  group('excerptForReport 摘录截断', () {
    test('null 与纯空白返回空串', () {
      expect(excerptForReport(null), '');
      expect(excerptForReport('   \n\t '), '');
    });

    test('短文本原样返回(去掉首尾空白)', () {
      expect(excerptForReport('  就这一句  '), '就这一句');
    });

    test('超长文本截断并加省略号', () {
      final long = '啊' * 500;
      final out = excerptForReport(long);
      expect(out.runes.length, 201); // 200 个字 + 一个「…」
      expect(out.endsWith('…'), isTrue);
    });

    test('按 runes 截断,不会把 emoji 劈成半个', () {
      final out = excerptForReport('🎉' * 10, maxChars: 3);
      expect(out, '🎉🎉🎉…');
      expect(hasLoneSurrogate(out), isFalse);
    });

    test('ZWJ 组合 emoji 也不产生落单代理项', () {
      final out = excerptForReport('👨‍👩‍👧' * 20, maxChars: 7);
      expect(hasLoneSurrogate(out), isFalse);
      expect(out.endsWith('…'), isTrue);
      expect(out.runes.length, 8);
    });
  });

  group('buildReportMailtoUri', () {
    test('scheme / path 正确,主题与正文能往返', () {
      final uri = buildReportMailtoUri(makeDraft(messageId: 'm_88f2'));
      expect(uri.scheme, 'mailto');
      expect(uri.path, kSupportEmail);

      final subject = uri.queryParameters['subject'];
      final body = uri.queryParameters['body'];
      expect(subject, isNotNull);
      expect(subject, isNotEmpty);
      expect(body, isNotNull);
      expect(body, isNotEmpty);
      expect(body, contains('u_2k9fh3x1q'));
      expect(body, contains('m_88f2'));
      expect(subject, contains(ReportReason.harassment.label));
    });
  });
}
