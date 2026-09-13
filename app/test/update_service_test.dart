import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lares_app/src/update/update_models.dart';
import 'package:lares_app/src/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _releaseJson({
  String tag = 'v0.2.0',
  List<Map<String, Object?>> assets = const [],
  String body = '',
}) =>
    jsonEncode({
      'tag_name': tag,
      'name': 'Lares $tag',
      'body': body,
      'html_url': 'https://github.com/LFM097384/Lares/releases/tag/$tag',
      'assets': assets,
    });

/// 固定时钟,让节流可精确断言(不依赖真实时间流逝)。
class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

UpdateService _service({
  required http.Client client,
  required _Clock clock,
  UpdatePlatform platform = UpdatePlatform.windows,
  String current = '0.1.0',
  List<String> abis = const [],
  Duration throttle = const Duration(hours: 6),
}) =>
    UpdateService(
      client: client,
      platformOverride: platform,
      versionReader: () async => current,
      abiReader: () async => abis,
      now: clock.call,
      throttle: throttle,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('检查更新:状态机', () {
    test('有新版本 -> available,并带上本平台资产', () async {
      final client = MockClient((_) async => http.Response(
            _releaseJson(assets: [
              {
                'name': 'lares-windows.zip',
                'browser_download_url': 'https://example.invalid/w.zip',
                'size': 100,
              }
            ]),
            200,
          ));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();

      expect(s.state.stage, UpdateStage.available);
      expect(s.state.info!.latestDisplay, '0.2.0');
      expect(s.state.info!.currentDisplay, '0.1.0');
      expect(s.state.info!.asset!.name, 'lares-windows.zip');
      expect(s.state.info!.canSelfUpdate, isTrue);
    });

    test('同版本 -> upToDate(+build 差异不算更新)', () async {
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.1.0'), 200),
      );
      final s = _service(
        client: client,
        clock: _Clock(DateTime(2026, 9, 12)),
        current: '0.1.0',
      );
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.upToDate);
      expect(s.state.info, isNull);
    });

    test('线上版本更旧 -> upToDate(不提示降级)', () async {
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.0.9'), 200),
      );
      final s = _service(
        client: client,
        clock: _Clock(DateTime(2026, 9, 12)),
        current: '0.10.0',
      );
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.upToDate);
    });

    test('0.10.0 > 0.9.0 在服务层同样成立', () async {
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.10.0'), 200),
      );
      final s = _service(
        client: client,
        clock: _Clock(DateTime(2026, 9, 12)),
        current: '0.9.0',
      );
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.available);
    });

    test('有新版但本平台无包 -> available 且 canSelfUpdate 为 false', () async {
      // 这正是当前仓库的真实情况:release 的 assets 是空的
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.2.0'), 200),
      );
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.available);
      expect(s.state.info!.hasDownloadableAsset, isFalse);
      expect(s.state.info!.canSelfUpdate, isFalse);
    });

    test('iOS:即使有 ipa 也不允许自助更新', () async {
      final client = MockClient((_) async => http.Response(
            _releaseJson(assets: [
              {
                'name': 'lares_app.ipa',
                'browser_download_url': 'https://example.invalid/a.ipa',
                'size': 10,
              }
            ]),
            200,
          ));
      final s = _service(
        client: client,
        clock: _Clock(DateTime(2026, 9, 12)),
        platform: UpdatePlatform.ios,
      );
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.info!.capability, UpdateCapability.notifyOnly);
      expect(s.state.info!.canSelfUpdate, isFalse);
    });

    test('Android 按设备 ABI 选包', () async {
      final client = MockClient((_) async => http.Response(
            _releaseJson(assets: [
              {
                'name': 'app-arm64-v8a-release.apk',
                'browser_download_url': 'https://example.invalid/a.apk',
                'size': 10,
              },
              {
                'name': 'app-armeabi-v7a-release.apk',
                'browser_download_url': 'https://example.invalid/b.apk',
                'size': 11,
              },
            ]),
            200,
          ));
      final s = _service(
        client: client,
        clock: _Clock(DateTime(2026, 9, 12)),
        platform: UpdatePlatform.android,
        abis: ['armeabi-v7a', 'armeabi'],
      );
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.info!.asset!.name, 'app-armeabi-v7a-release.apk');
    });

    test('release 正文里的 SHA-256 会被提取出来', () async {
      const hash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final client = MockClient((_) async => http.Response(
            _releaseJson(
              assets: [
                {
                  'name': 'lares-windows.zip',
                  'browser_download_url': 'https://example.invalid/w.zip',
                  'size': 100,
                }
              ],
              body: 'lares-windows.zip  $hash',
            ),
            200,
          ));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.info!.expectedSha256, hash);
    });
  });

  group('失败降级:绝不崩,只说「暂时查不了」', () {
    test('403 且配额耗尽 -> 明确的限流提示', () async {
      final client = MockClient((_) async => http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {'x-ratelimit-remaining': '0'},
          ));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('60'));
    });

    test('403 非限流 -> 通用拒绝提示', () async {
      final client = MockClient((_) async => http.Response('nope', 403));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('403'));
    });

    test('404(还没有任何 release)', () async {
      final client = MockClient((_) async => http.Response('{}', 404));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('还没有发布'));
    });

    test('500 -> 失败但不抛异常', () async {
      final client = MockClient((_) async => http.Response('boom', 500));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await expectLater(s.check(), completes);
      expect(s.state.stage, UpdateStage.failed);
    });

    test('畸形 JSON -> 失败但不抛异常', () async {
      final client = MockClient((_) async => http.Response('not json{', 200));
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await expectLater(s.check(), completes);
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('格式异常'));
    });

    test('断网(抛异常)-> 降级为「连不上网络」', () async {
      final client = MockClient((_) async => throw const _NetDown());
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await expectLater(s.check(), completes);
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('连不上网络'));
    });

    test('静默检查失败不改变 UI 状态(不打扰用户)', () async {
      final client = MockClient((_) async => throw const _NetDown());
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check(silent: true);
      expect(s.state.stage, UpdateStage.idle);
      expect(s.state.reason, isNull);
    });
  });

  group('节流:别把 GitHub 打爆', () {
    test('从没查过 -> 允许', () {
      final s = _service(
        client: MockClient((_) async => http.Response('{}', 200)),
        clock: _Clock(DateTime(2026, 9, 12, 12)),
      );
      addTearDown(s.dispose);
      expect(s.shouldAutoCheck(null), isTrue);
    });

    test('刚查过 -> 拒绝;超过窗口 -> 允许', () {
      final clock = _Clock(DateTime(2026, 9, 12, 12));
      final s = _service(
        client: MockClient((_) async => http.Response('{}', 200)),
        clock: clock,
        throttle: const Duration(hours: 6),
      );
      addTearDown(s.dispose);

      final last = DateTime(2026, 9, 12, 12);
      expect(s.shouldAutoCheck(last), isFalse);

      clock.advance(const Duration(hours: 5, minutes: 59));
      expect(s.shouldAutoCheck(last), isFalse);

      clock.advance(const Duration(minutes: 1));
      expect(s.shouldAutoCheck(last), isTrue, reason: '恰好 6 小时应放行');

      clock.advance(const Duration(days: 3));
      expect(s.shouldAutoCheck(last), isTrue);
    });

    test('maybeAutoCheck:窗口内不发请求,窗口外才发', () async {
      var calls = 0;
      final clock = _Clock(DateTime(2026, 9, 12, 12));
      final client = MockClient((_) async {
        calls++;
        return http.Response(_releaseJson(tag: 'v0.1.0'), 200);
      });
      final s = _service(
        client: client,
        clock: clock,
        throttle: const Duration(hours: 6),
      );
      addTearDown(s.dispose);

      // 第一次:没有记录,应该真发
      expect(await s.maybeAutoCheck(), isTrue);
      expect(calls, 1);

      // 紧接着再来:被节流挡下
      expect(await s.maybeAutoCheck(), isFalse);
      expect(calls, 1);

      // 时间推进 6 小时后放行
      clock.advance(const Duration(hours: 6));
      expect(await s.maybeAutoCheck(), isTrue);
      expect(calls, 2);
    });

    test('手动 check() 无视节流', () async {
      var calls = 0;
      final clock = _Clock(DateTime(2026, 9, 12, 12));
      final client = MockClient((_) async {
        calls++;
        return http.Response(_releaseJson(tag: 'v0.1.0'), 200);
      });
      final s = _service(client: client, clock: clock);
      addTearDown(s.dispose);

      await s.maybeAutoCheck();
      expect(calls, 1);

      await s.check(); // 用户点「立即检查」
      await s.check();
      expect(calls, 3, reason: '手动检查必须每次都发');
    });

    test('关掉自动检查后 maybeAutoCheck 不发请求', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(_releaseJson(), 200);
      });
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.setAutoCheckEnabled(false);
      expect(await s.maybeAutoCheck(), isFalse);
      expect(calls, 0);
    });

    test('自动检查开关默认为开', () async {
      final s = _service(
        client: MockClient((_) async => http.Response('{}', 200)),
        clock: _Clock(DateTime(2026, 9, 12)),
      );
      addTearDown(s.dispose);
      expect(await s.autoCheckEnabled(), isTrue);
    });

    test('检查成功后写入 lastCheckedAt', () async {
      final clock = _Clock(DateTime(2026, 9, 12, 8));
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.1.0'), 200),
      );
      final s = _service(client: client, clock: clock);
      addTearDown(s.dispose);

      expect(await s.lastCheckedAt(), isNull);
      await s.check();
      expect(await s.lastCheckedAt(), DateTime(2026, 9, 12, 8));
    });
  });

  group('安装前置条件', () {
    test('没有资产时 download() 直接失败,不发请求', () async {
      final client = MockClient(
        (_) async => http.Response(_releaseJson(tag: 'v0.2.0'), 200),
      );
      final s = _service(client: client, clock: _Clock(DateTime(2026, 9, 12)));
      addTearDown(s.dispose);

      await s.check();
      await s.download();
      expect(s.state.stage, UpdateStage.failed);
      expect(s.state.reason, contains('没有可下载'));
    });

    test('没下载就 install() -> 明确失败', () async {
      final s = _service(
        client: MockClient((_) async => http.Response('{}', 200)),
        clock: _Clock(DateTime(2026, 9, 12)),
      );
      addTearDown(s.dispose);

      final outcome = await s.install();
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('还没有下载'));
    });
  });
}

class _NetDown implements Exception {
  const _NetDown();
  @override
  String toString() => 'SocketException: network is down';
}
