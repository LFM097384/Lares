@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lares_app/src/auth/auth_credential.dart';
import 'package:lares_app/src/auth/auth_verifier.dart';
import 'package:lares_app/src/auth/circle_identity.dart';
import 'package:lares_app/src/net/signaling_client.dart';

/// 端到端:真实 SignalingClient × 真实 Node 服务端,走完一遍圈主的一生。
///
/// 建圈(本机生成圈主钥匙、待登记)→ 服务器确认 → 第二人凭口令进圈 → 圈主踢人 → 圈主换口令 →
/// 被请出去的人拿旧口令重连,必须 4401 失败;拿新口令才进得来。
///
/// 这一组证明的是**客户端代码**真的和服务器谈得拢(v2 证明、register{verifier,ownerHash}、
/// ownerKey 回传、owner_ok 回执),不是协议草稿自洽。缺 node/server 时整组跳过。
/// 单独运行:flutter test test/circle_owner_live_test.dart
void main() {
  final repoRoot = Directory.current.parent.path;
  final sep = Platform.pathSeparator;
  final serverDir = Directory('$repoRoot${sep}server');
  final hasServer =
      File('${serverDir.path}${sep}src${sep}index.js').existsSync() &&
          Directory('${serverDir.path}${sep}node_modules').existsSync();

  Process? proc;
  Directory? dataDir;
  const port = 18971; // 避开 signaling_live_auth_test 用的 18941–18953

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('lares-owner-live-');
    proc = await Process.start(
      'node',
      ['src/index.js'],
      workingDirectory: serverDir.path,
      environment: {
        ...Platform.environment,
        'LARES_PORT': '$port',
        'LARES_AUTH_MODE': 'circle',
        'LARES_CIRCLE_PASSCODES': '{"home":"env-home-passcode"}',
        'LARES_CIRCLE_PASSCODE': '',
        'LARES_DATA_DIR': dataDir!.path,
        'LIVEKIT_URL': '',
        'LIVEKIT_API_KEY': '',
        'LIVEKIT_API_SECRET': '',
      },
    );
    proc!.stdout.drain<void>();
    proc!.stderr.drain<void>();
    final http = HttpClient();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res =
            await (await http.getUrl(Uri.parse('http://127.0.0.1:$port/health')))
                .close();
        await res.drain<void>();
        if (res.statusCode == 200) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    fail('服务端未能启动');
  });

  tearDown(() async {
    proc?.kill();
    proc = null;
    try {
      await dataDir?.delete(recursive: true);
    } catch (_) {}
  });

  /// 等第一条满足条件的消息
  Future<Map<String, dynamic>> waitFor(
    SignalingClient c,
    bool Function(Map<String, dynamic>) pred, {
    Duration timeout = const Duration(seconds: 10),
  }) =>
      c.messages
          .firstWhere(pred)
          .timeout(timeout, onTimeout: () => {'t': '_timeout'});

  test('建圈 → 钥匙 → 第二人进 → 圈主踢人并换口令 → 旧口令被拒', () async {
    final cid = generateCircleId();
    var passcode = generateCirclePasscode();

    // ── 圈主:本机先生成钥匙(真 App 里此时已进 vault 并读回),再待登记 ──
    var pending = true;
    final String storedKey = generateOwnerKey();
    final owner = SignalingClient(
      url: 'ws://127.0.0.1:$port/ws',
      userId: 'u_owner',
      credentials: () => AuthCredential(
          mode: AuthMode.circle, passcode: passcode, circleId: cid),
      circleHints: (id) => (register: pending, ownerKey: storedKey),
    );
    var serverSentKey = false;
    owner.onOwnerKeyIssued = (id, key) async => serverSentKey = true;
    owner.onRegistrationSettled = (_) => pending = false;
    owner.authCircleId = cid;
    final ownerWelcome = waitFor(owner, (m) => m['t'] == 'welcome');
    owner.connect();
    owner.hello(
        userId: 'u_owner', deviceId: 'd_o', name: '圈主', platform: 'test');
    final w = await ownerWelcome;
    expect(w['t'], 'welcome');
    final circle = w['circle'] as Map;
    expect(circle['registered'], isTrue);
    expect(circle['isOwner'], isTrue);
    expect(circle['created'], isTrue);
    expect(circle.containsKey('ownerKey'), isFalse, reason: '服务器不再生成/下发钥匙');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(serverSentKey, isFalse);
    expect(pending, isFalse, reason: 'welcome 确认后清掉待登记');

    // ── 第二人:凭口令进圈 ──
    Future<SignalingClient> member(String pass) async {
      final m = SignalingClient(
        url: 'ws://127.0.0.1:$port/ws',
        userId: 'u_member',
        credentials: () =>
            AuthCredential(mode: AuthMode.circle, passcode: pass, circleId: cid),
      );
      m.authCircleId = cid;
      m.connect();
      m.hello(
          userId: 'u_member', deviceId: 'd_m', name: '成员', platform: 'test');
      return m;
    }

    final m1 = await member(passcode);
    final mw = await waitFor(m1, (m) => m['t'] == 'welcome');
    expect(mw['t'], 'welcome');
    expect((mw['circle'] as Map)['isOwner'], isFalse);

    // 非圈主换口令:被拒
    m1.setCirclePasscode(cid, ownerKey: 'f' * 64, verifier: 'a' * 64);
    final denied = await waitFor(m1, (m) => m['t'] == 'owner_error');
    expect(denied['reason'], 'not_owner');

    // ── 圈主踢人(两人都在房里)──
    final ownerRoom = waitFor(owner, (m) => m['t'] == 'room');
    owner.send({'t': 'join', 'circleId': cid});
    await ownerRoom;
    final memberRoom = waitFor(m1, (m) => m['t'] == 'room');
    m1.send({'t': 'join', 'circleId': cid});
    await memberRoom;
    final kicked = waitFor(m1, (m) => m['t'] == 'kicked');
    final kickOk =
        waitFor(owner, (m) => m['t'] == 'owner_ok' && m['op'] == 'kick');
    owner.send(
        {'t': 'kick', 'circleId': cid, 'userId': 'u_member', 'ownerKey': storedKey});
    expect((await kicked)['t'], 'kicked');
    expect((await kickOk)['t'], 'owner_ok');

    // ── 圈主换口令:成员被断开 ──
    final next = generateCirclePasscode();
    final verifier = await AuthVerifierCache().get(cid, next);
    final rekeyed = waitFor(m1, (m) => m['t'] == 'circle_rekeyed');
    final passOk = waitFor(owner,
        (m) => m['t'] == 'owner_ok' && m['op'] == 'circle_passcode_set');
    owner.setCirclePasscode(cid, ownerKey: storedKey, verifier: verifier);
    expect((await passOk)['t'], 'owner_ok');
    expect((await rekeyed)['t'], 'circle_rekeyed');
    await m1.dispose();

    // ── 被请出去的人拿旧口令:4401 ──
    final m2 = await member(passcode);
    final rejected = await waitFor(
        m2, (m) => m['t'] == '_auth_failed' || m['t'] == 'welcome');
    expect(rejected['t'], '_auth_failed', reason: '旧口令必须作废');
    await m2.dispose();

    // ── 拿到新口令的人进得来 ──
    passcode = next;
    final m3 = await member(next);
    final ok3 = await waitFor(m3, (m) => m['t'] == 'welcome');
    expect(ok3['t'], 'welcome');
    await m3.dispose();

    // ── 解散:剩下的人收到 circle_deleted,之后谁也进不来 ──
    final m4 = await member(next);
    await waitFor(m4, (m) => m['t'] == 'welcome');
    final gone = waitFor(m4, (m) => m['t'] == 'circle_deleted');
    final delOk =
        waitFor(owner, (m) => m['t'] == 'owner_ok' && m['op'] == 'circle_delete');
    owner.deleteCircle(cid, ownerKey: storedKey);
    expect((await delOk)['t'], 'owner_ok');
    expect((await gone)['t'], 'circle_deleted');
    await m4.dispose();
    await owner.dispose();
  }, skip: hasServer ? null : '未找到 server/ 或其 node_modules',
      timeout: const Timeout(Duration(seconds: 60)));

  test('welcome 丢了:重试撞 4409 → 带本机钥匙登录 → isOwner=true,不成无主圈', () async {
    final cid = generateCircleId();
    final passcode = generateCirclePasscode();
    final key = generateOwnerKey();

    // 第一个客户端完成登记后立刻消失(模拟 welcome 在路上丢了):
    // 不挂 onRegistrationSettled,待登记标记原样保持。
    final lost = SignalingClient(
      url: 'ws://127.0.0.1:$port/ws',
      userId: 'u_owner',
      credentials: () => AuthCredential(
          mode: AuthMode.circle, passcode: passcode, circleId: cid),
      circleHints: (id) => (register: true, ownerKey: key),
    );
    lost.authCircleId = cid;
    final first = waitFor(lost, (m) => m['t'] == 'welcome');
    lost.connect();
    lost.hello(
        userId: 'u_owner', deviceId: 'd_o', name: '圈主', platform: 'test');
    expect((await first)['t'], 'welcome');
    await lost.dispose();

    // 「重启」后的新进程:待登记还在,钥匙在 vault 里
    var pending = true;
    final codes = <Object?>[];
    final retry = SignalingClient(
      url: 'ws://127.0.0.1:$port/ws',
      userId: 'u_owner',
      credentials: () => AuthCredential(
          mode: AuthMode.circle, passcode: passcode, circleId: cid),
      circleHints: (id) => (register: pending, ownerKey: key),
    );
    retry.onRegistrationSettled = (_) => pending = false;
    retry.authCircleId = cid;
    final sub = retry.messages.listen((m) {
      if (m['t'] == '_disconnected') codes.add(m['closeCode']);
    });
    final w = waitFor(retry, (m) => m['t'] == 'welcome',
        timeout: const Duration(seconds: 15));
    retry.connect();
    retry.hello(
        userId: 'u_owner', deviceId: 'd_o', name: '圈主', platform: 'test');
    final welcome = await w;
    expect(codes, contains(4409), reason: '第一次重试带 register,应当撞 circle_exists');
    expect(welcome['t'], 'welcome');
    expect((welcome['circle'] as Map)['isOwner'], isTrue,
        reason: '钥匙一直在本机,服务器认它 —— 圈主身份没丢');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pending, isFalse, reason: 'isOwner=true 即视为登记成功,清标记');

    // 圈主操作照常可用
    final ok = waitFor(retry,
        (m) => m['t'] == 'owner_ok' && m['op'] == 'circle_e2ee_set');
    retry.send({
      't': 'circle_e2ee_set',
      'circleId': cid,
      'enabled': true,
      'ownerKey': key,
    });
    expect((await ok)['t'], 'owner_ok');
    await sub.cancel();
    await retry.dispose();
  }, skip: hasServer ? null : '未找到 server/ 或其 node_modules',
      timeout: const Timeout(Duration(seconds: 60)));
}