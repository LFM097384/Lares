/// 自动更新核心服务(平台无关)。
///
/// 职责边界很清楚:
/// - **本文件**:查 GitHub Release、比版本、挑资产、下载、校验、维护状态机与节流。
/// - **installer_io.dart**:平台相关的「装」这一步。
/// - **update_panel.dart**:UI。
///
/// 三条产品纪律(来自需求):
/// 1. 启动自动检查默认**开**,但检查是**静默**的,失败不打扰用户;
/// 2. **绝不**自动安装 —— 下载和安装都必须是用户的显式点击;
/// 3. 任何异常都降级为「暂时查不了」,不允许把 App 拖崩。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'installer.dart' if (dart.library.io) 'installer_io.dart';
import 'update_models.dart';
import 'version.dart';

/// 状态机。UI 只读这个。
enum UpdateStage {
  /// 还没查过
  idle,

  /// 正在查
  checking,

  /// 已是最新
  upToDate,

  /// 有新版本(详情在 [UpdateState.info])
  available,

  /// 正在下载(进度在 [UpdateState.progress])
  downloading,

  /// 下载完成、校验通过,等用户点「安装」
  readyToInstall,

  /// 出错了(原因在 [UpdateState.reason])
  failed,
}

/// 不可变状态快照。
@immutable
class UpdateState {
  const UpdateState({
    required this.stage,
    this.info,
    this.progress = 0,
    this.reason,
    this.downloadedPath,
    this.sha256Hex,
    this.integrity = IntegrityLevel.none,
    this.lastCheckedAt,
  });

  final UpdateStage stage;
  final UpdateInfo? info;

  /// 0.0 ~ 1.0;服务端未给 Content-Length 时为 -1(不确定进度)。
  final double progress;

  final String? reason;
  final String? downloadedPath;

  /// 已下载文件的实际 SHA-256(小写 hex),仅在下载完成后有值。
  final String? sha256Hex;

  final IntegrityLevel integrity;
  final DateTime? lastCheckedAt;

  bool get isBusy =>
      stage == UpdateStage.checking || stage == UpdateStage.downloading;

  UpdateState copyWith({
    UpdateStage? stage,
    UpdateInfo? info,
    double? progress,
    String? reason,
    String? downloadedPath,
    String? sha256Hex,
    IntegrityLevel? integrity,
    DateTime? lastCheckedAt,
  }) =>
      UpdateState(
        stage: stage ?? this.stage,
        info: info ?? this.info,
        progress: progress ?? this.progress,
        reason: reason ?? this.reason,
        downloadedPath: downloadedPath ?? this.downloadedPath,
        sha256Hex: sha256Hex ?? this.sha256Hex,
        integrity: integrity ?? this.integrity,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      );
}

/// 下载完成后**实际达到**的完整性级别。UI 要如实展示,不许吹。
enum IntegrityLevel {
  /// 没有任何校验
  none,

  /// 只核对了字节数与 release 声明的 size 一致
  sizeOnly,

  /// 核对了字节数,且 SHA-256 与 release 正文里公布的值一致
  sizeAndPublishedSha256,
}

/// 更新服务。ChangeNotifier,与项目里 RoomController/SettingsStore 一致。
class UpdateService extends ChangeNotifier {
  UpdateService({
    http.Client? client,
    String owner = 'LFM097384',
    String repo = 'Lares',
    UpdatePlatform? platformOverride,
    Future<String> Function()? versionReader,
    Future<List<String>> Function()? abiReader,
    DateTime Function()? now,
    Duration throttle = const Duration(hours: 6),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _owner = owner,
        _repo = repo,
        _platform = platformOverride ?? _detectPlatform(),
        _versionReader = versionReader ?? _defaultVersionReader,
        _abiReader = abiReader ?? readDeviceAbis,
        _now = now ?? DateTime.now,
        _throttle = throttle;

  final http.Client _client;
  final bool _ownsClient;
  final String _owner;
  final String _repo;
  final UpdatePlatform _platform;
  final Future<String> Function() _versionReader;
  final Future<List<String>> Function() _abiReader;

  /// 注入时钟:让节流逻辑可以在单元测试里精确验证,不依赖真实时间流逝。
  final DateTime Function() _now;

  /// 两次**自动**检查之间的最小间隔(手动检查不受限)。
  final Duration _throttle;

  static const _kLastCheck = 'lares.update.lastCheckMs';
  static const _kAutoCheck = 'lares.update.autoCheck';

  UpdateState _state = const UpdateState(stage: UpdateStage.idle);
  UpdateState get state => _state;

  UpdatePlatform get platform => _platform;

  String? _currentVersionRaw;

  /// 运行中 App 的版本号(首次读取后缓存)。
  Future<String> currentVersion() async =>
      _currentVersionRaw ??= await _versionReader();

  /// 启动自动检查开关,默认 **on**。
  Future<bool> autoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoCheck) ?? true;
  }

  Future<void> setAutoCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheck, value);
    notifyListeners();
  }

  Future<DateTime?> lastCheckedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kLastCheck);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 距上次检查是否已超过节流窗口(纯函数式判断,便于测试)。
  bool shouldAutoCheck(DateTime? last) {
    if (last == null) return true;
    return _now().difference(last) >= _throttle;
  }

  /// 启动时调用:遵守开关 + 节流,**静默**执行。
  ///
  /// 返回 true 表示这次真的发起了网络请求。任何失败都只写日志,
  /// 不会把 stage 推成 failed 去打扰用户(静默检查的失败不该弹红字)。
  Future<bool> maybeAutoCheck() async {
    try {
      if (!await autoCheckEnabled()) return false;
      final last = await lastCheckedAt();
      if (!shouldAutoCheck(last)) {
        debugPrint('[update] 距上次检查不足 ${_throttle.inHours}h,跳过');
        return false;
      }
      await check(silent: true);
      return true;
    } catch (e) {
      debugPrint('[update] 自动检查异常(已忽略): $e');
      return false;
    }
  }

  /// 查询最新版本。[silent] 为 true 时失败不改 UI 状态。
  ///
  /// 手动「立即检查」传 silent: false,并且**不看节流**。
  Future<void> check({bool silent = false}) async {
    if (_state.isBusy) return;
    if (!silent) _emit(_state.copyWith(stage: UpdateStage.checking));

    try {
      final currentRaw = await currentVersion();
      final current = LaresVersion.tryParse(currentRaw);
      if (current == null) {
        return _fail('无法识别当前版本号($currentRaw)', silent: silent);
      }

      final uri = Uri.https(
        'api.github.com',
        '/repos/$_owner/$_repo/releases/latest',
      );
      final resp = await _client.get(uri, headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      }).timeout(const Duration(seconds: 15));

      // 只要**收到了**服务端响应就记一次时间戳:即便这次是 403/500,
      // 也不该在下次启动时立刻再打一遍(真正该重试的只有断网,那条路不记)。
      await _touchLastCheck();

      // 未认证配额 60 次/小时;超了 GitHub 回 403(偶尔 429)
      if (resp.statusCode == 403 || resp.statusCode == 429) {
        final remaining = resp.headers['x-ratelimit-remaining'];
        if (remaining == '0') {
          final resetAt = _rateLimitReset(resp.headers);
          return _fail(
            'GitHub 接口调用次数用完了(未登录每小时 60 次)'
            '${resetAt == null ? '' : ',约 $resetAt 后恢复'}。稍后再试。',
            silent: silent,
          );
        }
        return _fail('GitHub 拒绝了这次请求(${resp.statusCode})。稍后再试。',
            silent: silent);
      }
      if (resp.statusCode == 404) {
        return _fail('仓库还没有发布任何版本。', silent: silent);
      }
      if (resp.statusCode != 200) {
        return _fail('检查失败(HTTP ${resp.statusCode})。', silent: silent);
      }

      final release = ReleaseInfo.fromJsonString(utf8.decode(resp.bodyBytes));
      if (release == null) {
        return _fail('发布信息格式异常,无法解析。', silent: silent);
      }

      final checkedAt = _now();

      if (release.version <= current) {
        return _emit(UpdateState(
          stage: UpdateStage.upToDate,
          lastCheckedAt: checkedAt,
        ));
      }

      final abis = _platform == UpdatePlatform.android
          ? await _abiReader()
          : const <String>[];
      final asset =
          AssetSelector.select(release.assets, _platform, deviceAbis: abis);
      final installer = createInstaller(_platform);

      _emit(UpdateState(
        stage: UpdateStage.available,
        lastCheckedAt: checkedAt,
        info: UpdateInfo(
          release: release,
          currentVersion: current,
          platform: _platform,
          capability: installer.capability,
          asset: asset,
          expectedSha256: asset == null
              ? null
              : extractSha256ForAsset(release.body, asset.name),
        ),
      ));
    } on TimeoutException {
      _fail('网络超时,暂时查不了更新。', silent: silent);
    } catch (e) {
      // 断网 / DNS 失败 / TLS 问题都落到这里 —— 一律降级,不崩
      debugPrint('[update] 检查失败: $e');
      _fail('连不上网络,暂时查不了更新。', silent: silent);
    }
  }

  /// 下载本平台的更新包。**只能由用户显式触发**。
  ///
  /// 完整性做到哪一步,如实记在 [UpdateState.integrity] 里:
  /// - 字节数必须与 release 声明的 size 一致,否则判失败;
  /// - 始终计算 SHA-256 并打日志;
  /// - 仅当 release 正文里公布了该文件的 SHA-256 时,才做「真·校验」。
  Future<void> download() async {
    final info = _state.info;
    final asset = info?.asset;
    if (info == null || asset == null) {
      return _fail('这个平台没有可下载的安装包。');
    }
    if (_state.isBusy) return;

    // 先做平台自检(Windows 不可写目录 -> 别白下 60MB)
    final installer = createInstaller(_platform);
    final blocker = await installer.preflight();
    if (blocker != null && installer.capability != UpdateCapability.notifyOnly) {
      return _fail(blocker);
    }

    _emit(_state.copyWith(stage: UpdateStage.downloading, progress: 0));

    try {
      final target = await openDownloadTarget(asset.name);

      final req = http.Request('GET', Uri.parse(asset.downloadUrl));
      final resp = await _client.send(req).timeout(
            const Duration(seconds: 30),
          );
      if (resp.statusCode != 200) {
        await target.close();
        await target.delete();
        return _fail('下载失败(HTTP ${resp.statusCode})。');
      }

      final total = resp.contentLength ?? asset.size;
      final digestSink = _Sha256Accumulator();
      var received = 0;

      try {
        await for (final chunk in resp.stream) {
          target.add(chunk);
          digestSink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _emit(_state.copyWith(
              stage: UpdateStage.downloading,
              progress: received / total,
            ));
          }
        }
      } finally {
        await target.close();
      }

      // 1) 字节数核对 —— 唯一一个 GitHub 事先提供的凭据
      if (asset.size > 0 && received != asset.size) {
        await target.delete();
        return _fail(
          '下载的文件大小不对(期望 ${asset.size} 字节,实际 $received),已删除。',
        );
      }

      // 2) SHA-256:始终算、始终记
      final hex = digestSink.close();
      debugPrint('[update] ${asset.name} sha256=$hex size=$received');

      var level = asset.size > 0 ? IntegrityLevel.sizeOnly : IntegrityLevel.none;
      final expected = info.expectedSha256;
      if (expected != null) {
        if (expected.toLowerCase() != hex) {
          await target.delete();
          return _fail('文件校验和不匹配,可能已损坏或被篡改,已删除。');
        }
        level = IntegrityLevel.sizeAndPublishedSha256;
      }

      _emit(_state.copyWith(
        stage: UpdateStage.readyToInstall,
        progress: 1,
        downloadedPath: target.path,
        sha256Hex: hex,
        integrity: level,
      ));
    } on TimeoutException {
      _fail('下载超时。');
    } catch (e) {
      debugPrint('[update] 下载失败: $e');
      _fail('下载失败:$e');
    }
  }

  /// 执行安装。**只能由用户显式触发**。
  Future<InstallOutcome> install() async {
    final path = _state.downloadedPath;
    if (path == null) {
      return const InstallOutcome.failure('还没有下载好的安装包。');
    }
    final installer = createInstaller(_platform);
    final outcome = await installer.install(path);
    if (!outcome.ok) _fail(outcome.message ?? '安装失败。');
    return outcome;
  }

  /// Windows 自替换专用:退出本进程,把文件锁交给助手脚本。
  /// 仅当 [InstallOutcome.requiresQuit] 为 true 时由 UI 调用。
  void quitForUpdate() => createInstaller(_platform).quitForUpdate();

  /// 回到初始状态(用户关掉面板时调用)。
  void reset() => _emit(const UpdateState(stage: UpdateStage.idle));

  Future<void> _touchLastCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastCheck, _now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[update] 记录检查时间失败: $e');
    }
  }

  void _fail(String reason, {bool silent = false}) {
    if (silent) {
      debugPrint('[update] 静默检查失败: $reason');
      // 静默失败保持原状态,不打扰用户
      return;
    }
    _emit(_state.copyWith(stage: UpdateStage.failed, reason: reason));
  }

  void _emit(UpdateState next) {
    _state = next;
    notifyListeners();
  }

  static String? _rateLimitReset(Map<String, String> headers) {
    final raw = headers['x-ratelimit-reset'];
    final secs = int.tryParse(raw ?? '');
    if (secs == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    final mins = at.difference(DateTime.now()).inMinutes;
    return mins <= 0 ? null : '$mins 分钟';
  }

  static Future<String> _defaultVersionReader() async {
    final info = await PackageInfo.fromPlatform();
    // version 形如 0.1.0;buildNumber 是 +1 那部分(不参与比较)
    return info.version;
  }

  static UpdatePlatform _detectPlatform() {
    if (kIsWeb) return UpdatePlatform.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return UpdatePlatform.windows;
      case TargetPlatform.android:
        return UpdatePlatform.android;
      case TargetPlatform.macOS:
        return UpdatePlatform.macos;
      case TargetPlatform.iOS:
        return UpdatePlatform.ios;
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return UpdatePlatform.unknown;
    }
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// 流式累加 SHA-256(避免把整个安装包读进内存)。
class _Sha256Accumulator {
  _Sha256Accumulator() {
    _inner = sha256.startChunkedConversion(
      _DigestCatcher((d) => _digest = d),
    );
  }

  late final ByteConversionSink _inner;
  Digest? _digest;

  void add(List<int> chunk) => _inner.add(chunk);

  String close() {
    _inner.close();
    return _digest!.toString();
  }
}

// 注:Sink 是 interface class,只能 implements 不能 extends(Dart 3 类修饰符)
class _DigestCatcher implements Sink<Digest> {
  _DigestCatcher(this.onDigest);
  final void Function(Digest) onDigest;

  @override
  void add(Digest data) => onDigest(data);

  @override
  void close() {}
}
