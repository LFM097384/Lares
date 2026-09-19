import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/signaling_client.dart';
import '../recording/recording_consent.dart';
import '../p2p/host_election.dart';
import '../rtc/rtc_service.dart';
import 'join_error.dart';
import 'models.dart';
import 'settings_store.dart';

/// 房间状态机:信令 presence + RTC 媒体的粘合层。
///
/// 一键进房路径(P0 优化,设计.md §8.3):
///   App 启动即 preconnect() 建立信令长连接;
///   点一下 -> join() -> 信令 join/token 与 RTC 连接串行但无多余往返,
///   目标「点击到听到声音」≤ 1.5s。
class RoomController extends ChangeNotifier {
  RoomController({
    required SignalingClient signaling,
    required RtcService rtc,
    required this.userId,
    required this.deviceId,
    required this.userName,
    this.settings,
    this.isOnWifi,
  })  : _signaling = signaling,
        _rtc = rtc {
    _msgSub = _signaling.messages.listen(_onSignalingMessage);
    _speakingSub = _rtc.speakingIdentities.listen((ids) {
      _speakingIds
        ..clear()
        ..addAll(ids);
      _resetIdleTimer(); // 有说话活动,推迟媒体降级
      notifyListeners();
    });
    _rtcDropSub = _rtc.onDisconnected.listen((_) {
      // RTC 掉了但信令还在:标为 joining 并等待上层重进
      if (phase == RoomPhase.inRoom) {
        phase = RoomPhase.joining;
        notifyListeners();
      }
    });
  }

  final SignalingClient _signaling;
  final RtcService _rtc;

  /// 设置(可选;§2.2 流量透明度)与 WiFi 检测(可注入,默认真=高音质)
  final SettingsStore? settings;
  final Future<bool> Function()? isOnWifi;

  /// 录音同意控制器:录音态的唯一权威,UI 指示器直接读它。
  /// 注入而非内建,是为了让 RoomController 的既有测试不必关心录音。
  RecordingConsentController? recordingConsent;

  /// 进房前的端到端加密准备钩子(由 `e2ee/e2ee_controller.dart` 注入)。
  ///
  /// 用回调而不是持有 `E2EEController`,是为了让本文件继续与厂商无关 ——
  /// `E2EEController` 要 import livekit_client,而 `RtcService` 这条抽象线
  /// (设计.md §8.1)上不该出现任何 LiveKit 类型。
  ///
  /// ⚠️ 每一条会走到 `_rtc.join()` 的路径都必须先 await 它,包括媒体唤醒。
  /// 漏掉一条,用户就会在「以为加密了」的圈子里明文通话 —— 静默降级是
  /// 这个功能唯一不可接受的失败方式。
  Future<void> Function(String? circleId)? prepareEncryption;

  final String userId;
  final String deviceId;
  String userName;

  RoomPhase phase = RoomPhase.idle;
  String? circleId;

  String? _errorMessage;

  /// 给用户看的一句人话(没失败时为 null)。
  ///
  /// 做成属性而不是裸字段,是为了在**每一处**赋值时顺手记下这次失败的
  /// [lastErrorKind]。失败路径有六七条(鉴权被拒、限流、RTC 未配置、敲门超时、
  /// 跨服务器连不上、`_connectRtc` 的 catch),挨个去改既啰嗦又必然漏 ——
  /// 而漏掉一条的表现是「该弹的口令框不弹」,很难在测试里发现。
  ///
  /// 尤其是:`_failJoin` 是刚修好「卡死在正在进去…」那个 bug 的地方,
  /// 已有测试盯着,这样写就一个字都不用动它。
  String? get errorMessage => _errorMessage;

  set errorMessage(String? value) {
    _errorMessage = value;
    // 反查种类。自定义文案(如跨服务器失败)对不上任何一条,落 null ——
    // 那正确:它们本来也不该弹口令框。
    lastErrorKind = value == null ? null : kindOfJoinMessage(value);
  }

  /// 最近一次失败的**种类**(没失败过则为 null)。
  ///
  /// 与 [errorMessage] 的分工:那个是给人看的一句话,这个是给代码看的一位信息。
  /// UI 要据此决定「该不该显示口令输入框」—— 绝不能去匹配 [errorMessage]
  /// 的文字,那在英文界面下当场失效,也经不起一次文案润色。
  JoinErrorKind? lastErrorKind;

  /// 这次失败是不是「差一个口令」。房内补填口令的入口只在它为 true 时出现 ——
  /// 网络不好、服务器没配 LiveKit 的时候弹口令框纯属误导。
  bool get needsPasscode =>
      phase == RoomPhase.error && lastErrorKind == JoinErrorKind.needsPasscode;

  /// 最近一次进房耗时(性能透明度,设计.md §2.2)
  Duration? lastJoinLatency;

  /// 闲时媒体降级(P0):无说话活动超过此时长,断开媒体流只留 presence
  static const idleDowngradeAfter = Duration(minutes: 5);

  /// 当前是否处于「在线但媒体已挂起」状态
  bool mediaDowngraded = false;

  /// 语音便签到达计数(note_added 广播,VoiceNotesController 监听)
  int noteBumpCounter = 0;

  bool muted = true; // 进房默认静音
  MemberStatus myStatus = MemberStatus.free;

  final List<Member> _members = [];
  final Set<String> _speakingIds = {};

  /// 大厅 presence 摘要(未进房也可见,circleId -> (人数, 名字, 是否需敲门))
  final Map<String, ({int count, List<String> names, bool knockRequired})>
      circlePresence = {};

  /// 挂着「我有空」的人(userId -> 信息)。
  ///
  /// 与 [circlePresence] 的区别:那是「圈子里有几个人在语音」,
  /// 这是「有人挂在外面等人来找」—— 两者都算在线,但后者还没进任何房间。
  ///
  /// 一个人可以同时对多个圈子可约,所以 `circleIds` 是个列表;
  /// 服务端只会下发**本连接有权看到**的那几个圈子。
  final Map<String, ({String name, List<String> circleIds, int since})>
      availableMembers = {};

  /// 我自己此刻挂在哪几个圈子(空 = 没挂)。
  List<String> myAvailableCircles = const [];

  bool get iAmAvailable => myAvailableCircles.isNotEmpty;

  /// 外部数据源变化时用它触发一次刷新(`notifyListeners` 是 protected 的)。
  void refresh() => notifyListeners();

  /// 上一次报给服务器的延迟。用来节流 —— 每次心跳都报太吵,
  /// 而选主机对几十毫秒的变化并不敏感(切换阈值是 300ms)。
  int _lastReportedLatency = -1;

  /// 把本机测到的延迟报给服务器,转给同房的人用于选主机。
  ///
  /// 变化不大就不报:选举本身有 300ms 的切换阈值,
  /// 频繁上报只会制造广播噪音。
  void reportLatency(int ms) {
    if (ms < 0 || circleId == null) return;
    if (_lastReportedLatency >= 0 && (ms - _lastReportedLatency).abs() < 50) {
      return;
    }
    _lastReportedLatency = ms;
    _signaling.send({'t': 'latency', 'ms': ms});
  }

  /// 多人直连选主机用的候选名单。
  ///
  /// 直接从成员列表映射 —— 所有人看到的是**同一份服务器快照**,
  /// 因此各自算出的主机必然一致。这是选举能成立的前提。
  List<HostCandidate> get hostCandidates => [
        for (final m in _members)
          HostCandidate(
            userId: m.userId,
            isDesktop: m.isDesktop,
            latencyMs: m.latencyMs,
          ),
      ];

  /// 别的服务器上有谁挂着(由 PresencePool 注入)。
  ///
  /// 做成回调而不是直接依赖 `PresencePool`:controller 不该认识
  /// 跨服务器聚合这件事,它只需要知道「这个圈子里还有谁有空」。
  List<({String userId, String name})> Function(String circleId)?
      remoteAvailableIn;

  /// 某个圈子里有谁挂着可约(不含自己,已跨服务器聚合)。
  ///
  /// 去重按 userId:同一台服务器的人可能同时出现在主连接与池子里
  /// (主连接那台被 exclude 掉了,正常不会;但档案切换的瞬间可能重叠)。
  /// 宁可多一次去重,也不要让同一个人在列表里出现两次。
  List<({String userId, String name})> availableIn(String circleId) {
    final seen = <String>{};
    final out = <({String userId, String name})>[];
    for (final e in availableMembers.entries) {
      if (e.key == userId || !e.value.circleIds.contains(circleId)) continue;
      if (seen.add(e.key)) out.add((userId: e.key, name: e.value.name));
    }
    final remote = remoteAvailableIn?.call(circleId) ??
        const <({String userId, String name})>[];
    for (final r in remote) {
      if (r.userId == userId) continue;
      if (seen.add(r.userId)) out.add(r);
    }
    return out;
  }

  /// 敲门中(等待房内成员放行)
  bool knocking = false;

  /// 收到的敲门请求(我在房内时)
  final List<({String userId, String name})> knockRequests = [];

  /// 被踢通知(UI 弹出后即清)
  String? kickedBy;

  /// 「有人来找我了」的通知(UI 提示后即清)
  String? reachedBy;

  /// 去找人失败的原因(UI 提示后即清)
  String? reachFailed;

  /// 位置共享(Snapchat 式):同房成员的最新位置
  final Map<String, ({String name, double lat, double lng, int ts})> locations =
      {};

  /// 我是否正在共享位置(由 LocationShareService 驱动)
  bool sharingMyLocation = false;

  Timer? _knockTimer;

  static const knockTimeout = Duration(seconds: 30);

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<Set<String>>? _speakingSub;
  StreamSubscription<void>? _rtcDropSub;
  Completer<void>? _joinCompleter;
  Stopwatch? _joinStopwatch;

  /// 最近一次 token,用于断线重连与媒体降级后唤醒
  String? _lastRtcUrl;
  String? _lastRtcToken;

  /// 预热 token 缓存(P0):进房时与信令并行,省下 mint 往返
  String? _prefetchedCircle;
  String? _prefetchedUrl;
  String? _prefetchedToken;
  DateTime? _prefetchedAt;
  bool _rtcConnecting = false;

  static const _prefetchMaxAge = Duration(minutes: 90); // token TTL 2h,留余量

  /// 闲时降级计时器:有说话活动时重置
  Timer? _idleTimer;

  List<Member> get members => List.unmodifiable(_members);
  Set<String> get speakingIds => Set.unmodifiable(_speakingIds);
  bool get isInRoom => phase == RoomPhase.inRoom;
  String get signalingUrl => _signaling.url;

  Member? get me {
    for (final m in _members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  /// App 启动即调用:预建立信令长连接(P0 预连接)
  void preconnect() => _signaling.connect();

  /// 一键进房
  Future<void> join(String targetCircleId) async {
    if (phase == RoomPhase.joining) return;
    phase = RoomPhase.joining;
    errorMessage = null;
    circleId = targetCircleId;
    _joinStopwatch = Stopwatch()..start();
    _joinCompleter = Completer<void>();
    notifyListeners();

    _signaling.join(targetCircleId);
    knocking = false;
    knockRequests.clear();
    // P0:有预热 token 则 RTC 与信令并行,不等服务器 mint 往返。
    // 但敲门圈且圈内有人时禁止先行连媒体——未获放行不能听到声音(隐私红线)
    final summary = circlePresence[targetCircleId];
    final knockGate =
        summary != null && summary.knockRequired && summary.count > 0;
    if (!knockGate) {
      final cached = _takePrefetchedToken(targetCircleId);
      if (cached != null) _connectRtc(cached.$1, cached.$2);
    }
    // 后续由 _onSignalingMessage 的 room/token 事件接力
    return _joinCompleter!.future;
  }

  /// 刚填完口令之后重新进房。
  ///
  /// ## 为什么不能直接再调一次 [join]
  ///
  /// 两个原因,少考虑任何一个都会表现成「填了口令,按重试,还是进不去」:
  ///
  /// 1. **信令层已经停止重连了。** 4401 之后 `_onAuthRejected` 给一次重试机会,
  ///    第二次仍失败就**不再排重连定时器**(否则 5 分钟 10 次必然撞上 4429 封禁)。
  ///    它明确把主动权交还给上层:「等用户改口令后 reconnectWithNewCredential()
  ///    再来」。所以必须显式叫醒它,否则 [join] 发出的消息只会躺在 outbox 里。
  ///
  /// 2. **连接证明的是「哪个圈子」得先对。** circle 模式下服务端把会话钉死在
  ///    证明过的那个圈子上(`server/src/index.js` 的 `circleAllowed`),
  ///    而 `authCircleId` 在 `main.dart` 里只跟着**主圈子**走。
  ///    通过邀请链接加进来的圈子通常不是主圈子 —— 不在这里纠正,
  ///    握手就会拿 home 的口令去证明 work,必然再次 4401。
  ///
  /// 顺序很要紧:先摆正 `authCircleId`(它的 setter 在 circle 模式下自带一次
  /// 干净重连),再等握手,最后才 join。握手没完成就 join,消息会进 outbox,
  /// 而期间若再重连一次那条消息就丢了 —— [switchServerAndJoin] 踩过同一个坑,
  /// 所以那里也是先 `waitHandshake` 再 `join`。
  Future<void> retryJoin(String targetCircleId) async {
    // 上一轮失败的残留状态先清掉,免得界面在等待期间还显示着旧错误。
    if (phase != RoomPhase.idle) {
      phase = RoomPhase.idle;
      errorMessage = null;
      notifyListeners();
    }

    // circle 模式下这个 setter 会自己触发一次带新凭据的干净重连;
    // 值没变时它什么都不做,所以下面仍要兜一次显式重连。
    final before = _signaling.authCircleId;
    _signaling.authCircleId = targetCircleId;
    if (before == targetCircleId) {
      // 圈子没变、变的是口令本身(最常见:用户填了之前压根没有的那个口令)。
      // 这条路径必须显式重连 —— 见上面第 1 条,信令层已经不会自己再来了。
      _signaling.reconnectWithNewCredential();
    }

    // 握手要现做:刚刚才把连接拆了重建。给的时间与跨服务器那条路径一致。
    final ok = await _signaling.waitHandshake(const Duration(seconds: 10));
    if (!ok) {
      // 没握上手的原因通常仍是鉴权(口令又错了),也可能是网络。
      // 统一走 humanize,措辞与其它失败路径保持一致。
      phase = RoomPhase.error;
      errorMessage = humanizeJoinError(StateError('auth_failed'));
      notifyListeners();
      return;
    }

    // ⚠️ 刻意**不 await** join() 的返回值。
    //
    // join() 返回的是 `_joinCompleter.future` —— 它要等服务器把 room/token
    // 发回来才完成,失败时则 completeError。本方法的职责到「已经把这次进房
    // 发出去了」为止:界面要的是 phase 从 error 变回 joining(转圈),
    // 而不是一个要等好几秒才落地的 Future。await 它会让调用方(以及测试)
    // 一直挂着,而在服务端压根不回话的 4401 场景里,那就是永远。
    //
    // 失败不会丢:_failJoin 会把 phase / errorMessage 落好并通知监听者,
    // 那才是 UI 真正读的通道。这里只需接住 completeError 以免它变成
    // 未捕获的异步错误。
    unawaited(join(targetCircleId).catchError((Object _) {}));
  }

  /// 预热入口:App 启动后为默认圈子提前备 token
  void prefetchToken(String targetCircleId) =>
      _signaling.prefetchToken(targetCircleId);

  (String, String)? _takePrefetchedToken(String targetCircleId) {
    final at = _prefetchedAt;
    if (_prefetchedCircle != targetCircleId ||
        _prefetchedUrl == null ||
        _prefetchedToken == null ||
        at == null ||
        DateTime.now().difference(at) > _prefetchMaxAge) {
      return null;
    }
    return (_prefetchedUrl!, _prefetchedToken!);
  }

  /// 一键出房:无需告别仪式(设计.md §3.1)
  Future<void> leave() async {
    // 先停录再退房,顺序不能反 —— 否则会出现「人已走、录音还在」的荒谬状态。
    recordingConsent?.stop();
    _idleTimer?.cancel();
    _idleTimer = null;
    _knockTimer?.cancel();
    knocking = false;
    knockRequests.clear();
    _lastRtcUrl = null;
    _lastRtcToken = null;
    mediaDowngraded = false;
    locations.clear();
    _signaling.leave();
    await _rtc.leave();
    phase = RoomPhase.idle;
    circleId = null;
    _members.clear();
    _speakingIds.clear();
    muted = true;
    notifyListeners();
  }

  Future<void> toggleMute() async {
    if (mediaDowngraded) _wakeMedia();
    muted = !muted;
    notifyListeners();
    await _rtc.setMuted(muted);
  }

  /// 有说话活动时重置闲时计时;超时则断媒体留 presence
  void _resetIdleTimer() {
    if (phase != RoomPhase.inRoom || mediaDowngraded) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleDowngradeAfter, _downgradeMedia);
  }

  Future<void> _downgradeMedia() async {
    if (phase != RoomPhase.inRoom || mediaDowngraded) return;
    // 媒体都断了还「录」下去,录到的只有静音,而指示器还亮着 ——
    // 那是另一种形式的说谎。
    recordingConsent?.stop();
    await _rtc.leave();
    mediaDowngraded = true;
    muted = true;
    _speakingIds.clear();
    notifyListeners();
  }

  /// 仅 WiFi 下高音质:移动网络自动降码率(§2.2 流量透明度)
  Future<bool> _currentHighQuality() async {
    final s = settings;
    if (s != null && s.wifiOnlyHq && isOnWifi != null) {
      return isOnWifi!();
    }
    return true;
  }

  /// 媒体唤醒:用保存的 token 重连(静默失败则等下次 token 事件)
  void _wakeMedia() {
    if (!mediaDowngraded) return;
    final url = _lastRtcUrl;
    final token = _lastRtcToken;
    if (url == null || token == null) return;
    mediaDowngraded = false;
    notifyListeners();
    () async {
      final hq = await _currentHighQuality();
      // 媒体唤醒也是一次真正的 join:加密准备必须重做一遍。
      // 少了这一行,闲时降级后自动唤醒的那次通话就会悄悄变成明文。
      await prepareEncryption?.call(circleId);
      return _rtc.join(
          url: url,
          token: token,
          startMuted: true,
          highQuality: hq,
          tuning: settings?.audioTuning ?? AudioTuning.standard);
    }()
        .then((_) {
      _resetIdleTimer();
      notifyListeners();
    }).catchError((_) {
      mediaDowngraded = true; // 唤醒失败,保持挂起
      notifyListeners();
    });
  }

  void setStatus(MemberStatus status) {
    myStatus = status;
    _signaling.setStatus(status.wire);
    // 本地立即反映,服务器广播回来后幂等覆盖
    _upsertMember(userId, status: status);
    notifyListeners();
  }

  /// 踢人:把目标用户请出房间(服务端做圈内授权)
  void kick(String targetUserId) {
    _signaling
        .send({'t': 'kick', 'circleId': circleId, 'userId': targetUserId});
  }

  /// 挂起「我有空」,对这几个圈子可见。
  ///
  /// 与进房互斥:人已经在房里了就没必要再挂着,服务端也会拒绝。
  void setAvailable(List<String> circleIds) {
    if (circleIds.isEmpty) return clearAvailable();
    // 乐观更新:服务端 available_ok 回来后会以它为准覆盖。
    // 先本地生效是为了按下开关立刻有反馈,而不是等一个网络往返。
    myAvailableCircles = List.unmodifiable(circleIds);
    _signaling.setAvailable(circleIds);
    notifyListeners();
  }

  void clearAvailable() {
    if (myAvailableCircles.isEmpty) return;
    myAvailableCircles = const [];
    _signaling.clearAvailable();
    notifyListeners();
  }

  /// 去找某个挂着的人。成功的话服务端会把双方都拉进 [circleId]。
  void reach(String targetUserId, {String? circleId}) {
    reachFailed = null;
    _signaling.reach(targetUserId, circleId: circleId);
  }

  /// 有人在**另一台服务器**上来找我:把主连接切过去,再进那个圈子。
  ///
  /// 三步的顺序都不能换:
  ///  1. 先退出当前房间 —— 否则旧服务器上会留下一个「人还在」的幽灵;
  ///  2. 再换地址(setter 内部会干净重连、重新握手);
  ///  3. **等握手完成**才 join —— 握手未完成时 join 会被排队,
  ///     而排队期间若又一次重连,那条 join 就丢了,表现为「切过去了但没进房」。
  ///
  /// [url] 由调用方给:controller 不认识 ServerProfile,
  /// 不该为了查一个地址把整个设置层拖进来。
  Future<void> switchServerAndJoin({
    required String circleId,
    String? url,
  }) async {
    if (phase != RoomPhase.idle) await leave();
    if (url != null) _signaling.url = url;
    // 跨服务器通常意味着跨网络,超时给宽一点。
    final ok =
        await _signaling.waitHandshake(const Duration(seconds: 10));
    if (!ok) {
      phase = RoomPhase.error;
      errorMessage = '连不上那台服务器,没能过去';
      notifyListeners();
      return;
    }
    join(circleId);
  }

  /// UI 提示过之后调用,免得重复弹。
  void consumeReachNotices() {
    if (reachedBy == null && reachFailed == null) return;
    reachedBy = null;
    reachFailed = null;
    notifyListeners();
  }

  /// 位置共享:开启/关闭(LocationShareService 驱动)
  void setSharingMyLocation(bool sharing) {
    sharingMyLocation = sharing;
    if (!sharing) _signaling.send({'t': 'loc_off'});
    notifyListeners();
  }

  /// 上报一次位置(LocationShareService 节流后调用)
  void reportLocation(double lat, double lng) {
    _signaling.send({'t': 'loc', 'lat': lat, 'lng': lng});
  }

  /// 房内成员:放敲门的人进来
  void allowKnock(String userId) {
    _signaling
        .send({'t': 'knock_allow', 'circleId': circleId, 'userId': userId});
    knockRequests.removeWhere((k) => k.userId == userId);
    notifyListeners();
  }

  /// 房内成员:暂时不理会这条敲门(对方 30s 后自动超时)
  void dismissKnock(String userId) {
    knockRequests.removeWhere((k) => k.userId == userId);
    notifyListeners();
  }

  /// 设置圈子敲门模式(§3.3)
  void setKnockMode(String targetCircleId, bool enabled) {
    _signaling.send({
      't': 'knock_mode_set',
      'circleId': targetCircleId,
      'enabled': enabled,
    });
  }

  /// 改名:本地立即生效,广播给同房成员与大厅
  void rename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == userName) return;
    userName = trimmed;
    _signaling.send({'t': 'profile', 'name': trimmed});
    _upsertMember(
      userId,
      member: Member(userId: userId, name: trimmed, status: myStatus),
    );
    notifyListeners();
  }

  void _onSignalingMessage(Map<String, dynamic> msg) {
    // 录音态:原样转发给同意控制器(它自己挑需要的 t 处理)。
    // 放在 switch 之前,'room' / 'member_left' / '_disconnected' 这些已有分支
    // 就不必各自再记得调一次 —— 漏掉一处就是「指示器说谎」。
    recordingConsent?.handleMessage(msg);

    switch (msg['t']) {
      case 'welcome':
        // 断线重连成功:自动恢复到之前所在的房间(README 待办:房间态恢复)
        final wanted = circleId;
        if (wanted != null && phase != RoomPhase.idle) {
          phase = RoomPhase.joining;
          _signaling.join(wanted);
          _signaling.prefetchToken(wanted); // 重连后重备预热 token
          notifyListeners();
        }
      case 'room':
        if (msg['circleId'] != circleId) return;
        knocking = false; // 进房成功(直接进或敲门被放行)
        _knockTimer?.cancel();
        final wireMembers = (msg['members'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _members
          ..clear()
          ..addAll(wireMembers.map(Member.fromWire));
        // 恢复成员的位置共享状态(后进房也能看到)
        locations.clear();
        for (final m in wireMembers) {
          final loc = m['loc'];
          final uid = m['userId'] as String?;
          if (uid != null && loc is Map) {
            locations[uid] = (
              name: m['name'] as String? ?? '圈友',
              lat: (loc['lat'] as num).toDouble(),
              lng: (loc['lng'] as num).toDouble(),
              ts: (loc['ts'] as num?)?.toInt() ?? 0,
            );
          }
        }
        notifyListeners();
      case 'member_joined':
        if (msg['circleId'] != circleId) return;
        final m = Member.fromWire((msg['member'] as Map).cast<String, dynamic>());
        _upsertMember(m.userId, member: m);
        notifyListeners();
        _wakeMedia(); // 来人了:若媒体挂起则恢复,别错过第一句招呼
      case 'member_left':
        if (msg['circleId'] != circleId) return;
        _members.removeWhere((m) => m.userId == msg['userId']);
        _speakingIds.remove(msg['userId']);
        notifyListeners();
      case 'member_status':
        if (msg['circleId'] != circleId) return;
        _upsertMember(msg['userId'] as String,
            status: MemberStatus.fromWire(msg['status'] as String?));
        notifyListeners();
      case 'member_updated':
        if (msg['circleId'] != circleId) return;
        final m = Member.fromWire((msg['member'] as Map).cast<String, dynamic>());
        // 别人改名:覆盖除自己外的成员记录(自己的名字以本地为准)
        if (m.userId != userId) _upsertMember(m.userId, member: m);
        notifyListeners();
      case 'note_added':
        if (msg['circleId'] != circleId) return;
        noteBumpCounter++;
        notifyListeners();
      case 'token':
        final url = msg['url'] as String;
        final token = msg['token'] as String;
        if (msg['prefetch'] == true) {
          // 预热响应:只缓存,不进房
          _prefetchedCircle = msg['circleId'] as String?;
          _prefetchedUrl = url;
          _prefetchedToken = token;
          _prefetchedAt = DateTime.now();
          return;
        }
        if (msg['circleId'] != circleId) return;
        _lastRtcUrl = url;
        _lastRtcToken = token;
        mediaDowngraded = false;
        _connectRtc(url, token);
      case 'error':
        if (msg['message'] == 'rtc_not_configured') {
          // presence 已通但 RTC 未配置:进入房间但标注错误,方便联调
          phase = RoomPhase.error;
          errorMessage = 'RTC 未配置(服务器缺少 LIVEKIT_* 环境变量)';
          _joinCompleter?.completeError(StateError('rtc_not_configured'));
          _joinCompleter = null;
          notifyListeners();
        }
      case 'circle_summary':
        final id = msg['circleId'] as String?;
        if (id == null) return;
        circlePresence[id] = (
          count: (msg['count'] as num?)?.toInt() ?? 0,
          names: (msg['names'] as List? ?? []).whereType<String>().toList(),
          knockRequired: msg['knockRequired'] == true,
        );
        notifyListeners();
      case 'member_available':
        final uid = msg['userId'] as String?;
        if (uid == null) return;
        availableMembers[uid] = (
          name: msg['name'] as String? ?? '',
          circleIds:
              (msg['circleIds'] as List? ?? []).whereType<String>().toList(),
          since: (msg['since'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
      case 'member_unavailable':
        final uid = msg['userId'] as String?;
        if (uid == null) return;
        if (availableMembers.remove(uid) != null) notifyListeners();
      case 'available_ok':
        myAvailableCircles =
            (msg['circleIds'] as List? ?? []).whereType<String>().toList();
        notifyListeners();
      case 'reached':
        // 有人来找我了。进房由服务端直接执行(它会给我们发 room + token),
        // 这里只负责把「我挂着」这个本地状态收掉,并记下是谁来的。
        myAvailableCircles = const [];
        reachedBy = msg['by'] as String?;
        notifyListeners();
      case 'reach_failed':
        // 对方刚好走了或没权限 —— 说清楚,别让按钮看起来没反应
        reachFailed = switch (msg['reason']) {
          'auth_scope' => '这个圈子你没有口令',
          _ => '对方刚好不在了',
        };
        notifyListeners();
      case 'knock_waiting':
        if (msg['circleId'] != circleId) return;
        knocking = true;
        notifyListeners();
        _knockTimer?.cancel();
        _knockTimer = Timer(knockTimeout, () {
          if (!knocking) return;
          knocking = false;
          phase = RoomPhase.error;
          errorMessage = '没人应门,稍后再敲';
          _signaling.leave();
          _joinCompleter?.completeError(StateError('knock_timeout'));
          _joinCompleter = null;
          notifyListeners();
        });
      case 'knock':
        if (msg['circleId'] != circleId) return;
        knockRequests.add((
          userId: msg['userId'] as String? ?? '',
          name: msg['name'] as String? ?? '圈友',
        ));
        notifyListeners();
      case 'kicked':
        // 我被请出房间:清理本地房间态,UI 弹提示
        kickedBy = msg['by'] as String? ?? '';
        leave();
      case 'member_loc':
        if (msg['circleId'] != circleId) return;
        final uid = msg['userId'] as String? ?? '';
        final lat = (msg['lat'] as num?)?.toDouble();
        final lng = (msg['lng'] as num?)?.toDouble();
        if (uid.isEmpty || lat == null || lng == null) return;
        locations[uid] = (
          name: msg['name'] as String? ?? '圈友',
          lat: lat,
          lng: lng,
          ts: (msg['ts'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
      case 'member_loc_off':
        if (msg['circleId'] != circleId) return;
        locations.remove(msg['userId']);
        notifyListeners();
      case '_disconnected':
        if (phase == RoomPhase.inRoom) {
          phase = RoomPhase.joining; // 信令重连后会自动 hello;房间态待恢复
          notifyListeners();
          return;
        }
        // ⚠️ 正在进房时断开 —— 这里以前什么都不做,于是卡死在「正在进去…」。
        //
        // 鉴权失败(4401)时服务端直接关连接,**不会**发任何消息,
        // 所以 'room' / 'token' 分支永远不会执行,_joinCompleter 永远挂着,
        // 界面就停在 joining 转圈,连「算了」都退不出来。
        // 2026-09-19 真机实测撞到:用没配口令的圈子进房,必然卡死。
        //
        // 只有 4401 / 4429 这类**确定性失败**才落到 error ——
        // 普通网络抖动仍交给信令层自动重连,不打断用户。
        final int? code = msg['closeCode'] as int?;
        if (phase == RoomPhase.joining && (code == 4401 || code == 4429)) {
          // 传字符串而非自定义异常类:humanizeJoinError 本来就靠
          // toString() 里的关键码分派,新加类型反而要改两处。
          _failJoin(StateError(code == 4401 ? 'auth_failed' : 'rate_limited'));
        }
    }
  }

  /// 进房失败的统一出口:把 phase 落到 error、给出人话、解开 completer。
  ///
  /// 单独抽出来是因为失败路径有好几条(鉴权被拒、限流、RTC 未配置、
  /// 敲门超时),以前各写各的,`_joinCompleter` 很容易漏掉一条 ——
  /// 漏了就是界面永久卡在「正在进去…」,连「算了」都退不出来。
  void _failJoin(Object error) {
    phase = RoomPhase.error;
    errorMessage = humanizeJoinError(error);
    _joinStopwatch?.stop();
    // completeError 必须有人接,否则会变成未捕获异步错误。
    // join() 的调用方(home_screen)已经 catch 了。
    _joinCompleter?.completeError(error);
    _joinCompleter = null;
    notifyListeners();
  }

  /// 测试注入:模拟收到服务器 token 事件(与 'token' 分支行为一致)
  @visibleForTesting
  Future<void> testInjectToken(String url, String token) {
    _lastRtcUrl = url;
    _lastRtcToken = token;
    mediaDowngraded = false;
    return _connectRtc(url, token);
  }

  Future<void> _connectRtc(String url, String token) async {
    _lastRtcUrl = url;
    _lastRtcToken = token;
    // 预热路径与服务器 token 事件可能同时触发,只连一次
    if (_rtcConnecting || phase == RoomPhase.inRoom) return;
    _rtcConnecting = true;
    try {
      final highQuality = await _currentHighQuality();
      // 密钥必须在 Room 构造之前装好:RoomOptions.encryption 是构造期参数,
      // 进房之后再改一个字都不会生效。
      await prepareEncryption?.call(circleId);
      final elapsed = await _rtc.join(
          url: url,
          token: token,
          startMuted: true,
          highQuality: highQuality,
          tuning: settings?.audioTuning ?? AudioTuning.standard);
      lastJoinLatency = _joinStopwatch?.elapsed ?? elapsed;
      debugPrint('[lares] 进房分段: 总=${lastJoinLatency!.inMilliseconds}ms '
          'RTC=${elapsed.inMilliseconds}ms');
      _joinStopwatch = null;
      phase = RoomPhase.inRoom;
      muted = true;
      _joinCompleter?.complete();
      _joinCompleter = null;
      _resetIdleTimer();
      notifyListeners();
    } catch (e) {
      phase = RoomPhase.error;
      // 给用户看人话,原始异常进日志。
      // 曾经这里是 `'进房失败:$e'`,于是屏幕上出现过
      // 「ClientException with SocketException: Connection...」:
      // 用户看不懂,且长度不可控把标题行撑爆(2014px 溢出)。
      debugPrint('[lares] 进房失败(原始异常): $e');
      errorMessage = humanizeJoinError(e);
      _joinCompleter?.completeError(e);
      _joinCompleter = null;
      notifyListeners();
    } finally {
      _rtcConnecting = false;
    }
  }

  void _upsertMember(String targetUserId,
      {Member? member, MemberStatus? status}) {
    final i = _members.indexWhere((m) => m.userId == targetUserId);
    if (i >= 0) {
      final existing = _members[i];
      _members[i] = Member(
        userId: existing.userId,
        // 名字:改名(member)优先,否则保留
        name: member?.name ?? existing.name,
        // 状态:显式 status 优先,其次 member 携带,否则保留
        status: status ?? member?.status ?? existing.status,
        // 设备数:仅服务器快照(member)可更新,否则保留原值
        deviceCount: member?.deviceCount ?? existing.deviceCount,
        // ⚠️ 这里每加一个字段都必须跟着加一行,否则本地状态更新
        // (比如只改 status)会把服务器发来的值**抹成默认值**。
        // platform/latencyMs 是选主机的输入,抹掉会让选举结果飘。
        platform: member?.platform.isNotEmpty == true
            ? member!.platform
            : existing.platform,
        latencyMs: (member?.latencyMs ?? -1) >= 0
            ? member!.latencyMs
            : existing.latencyMs,
      );
    } else if (member != null) {
      _members.add(member);
    }
  }

  /// 设置页用:如实显示本平台实际生效的降噪状态。
  /// 不承诺平台做不到的事 —— 例如 Windows 上「增强」会诚实回落到「标准」。
  ResolvedAudioTuning rtcPreview(AudioTuning tuning) =>
      _rtc.previewTuning(tuning);

  @override
  void dispose() {
    _idleTimer?.cancel();
    _knockTimer?.cancel();
    _msgSub?.cancel();
    _speakingSub?.cancel();
    _rtcDropSub?.cancel();
    super.dispose();
  }
}

