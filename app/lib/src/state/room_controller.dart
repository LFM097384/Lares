import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_credential.dart';
import '../net/signaling_client.dart';
import '../recording/recording_consent.dart';
import '../p2p/host_election.dart';
import '../rtc/rtc_service.dart';
import 'identity.dart' show capNickname;
import 'join_error.dart';
import 'mic_notice.dart';
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
      // ⚠️ 这里以前只是 `phase = joining` 然后「等上层重进」——
      // 可从来没有哪个上层会重进。媒体掉线之后界面就永久停在「正在进去…」,
      // 和前三次卡死是同一个病:进了 joining 却没有任何出口。
      //
      // leave() 现在会先把 phase 落到 idle 再 await _rtc.leave(),
      // 所以正常退房触发的这条事件会被下面这个守卫挡掉,不会误判成掉线。
      if (phase != RoomPhase.inRoom) return;
      // 掉线恢复是自动路径:记下断线前的麦克风状态,恢复后原样还原。
      // 静音的人回来仍是静音 —— 任何自动重连都不许把人变成开麦。
      _micOnAfterConnect = !muted;
      // 媒体已经断了,此刻麦克风确实没在发布:界面如实显示静音,
      // 而不是在「正在重连」期间继续亮着一个并不存在的开麦状态。
      muted = true;
      phase = RoomPhase.joining;
      notifyListeners();
      _recoverMedia();
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

  /// 麦克风是否静音。**只在 RTC 层回报了真实结果之后才改它**。
  ///
  /// 开麦状态是隐私相关的显示:界面(房间页按钮、主屏小组件)上画的
  /// 必须是真实状态。以前 toggleMute 先翻转这个值再去开麦,开麦失败
  /// (没权限 / 唤醒还没完成)时界面显示「开着」而麦克风其实是关的 ——
  /// 反方向同样可能:以为关了其实开着。所以现在一律「先做,成了再改」。
  bool muted = true;

  /// 麦克风操作没成的一次性提示(UI 弹一次即 [consumeMicNotice])。
  MicNotice? micNotice;

  /// 下一次 `_connectRtc` 连上之后要不要开麦。
  ///
  /// 只有**用户主动**进圈(点圈子、邀请链接、小组件/快捷方式「进圈」、托盘)
  /// 才按设置「进圈时打开麦克风」置为 true;自动路径(掉线恢复、信令重连、
  /// 挂机自动进圈、被别人 reach 拉进来)要么保持断线前的状态,要么保持静音 ——
  /// **任何自动重试都不许把一个静音的人变成开麦**。
  ///
  /// 放在字段上而不是作为 `_connectRtc` 的参数,是因为 `_connectRtc`
  /// 有两个触发点(预热 token 直连、服务端 token 事件),它们都只知道
  /// url/token,不知道这次进房是谁发起的。
  bool _micOnAfterConnect = false;

  /// 正在进行的媒体唤醒。toggleMute 要等它落地再开麦,
  /// 否则开麦请求会打在一个还没连好的房间上,被静默吞掉(原 bug 1)。
  Future<RtcJoinResult?>? _wakeInFlight;

  /// 麦克风切换进行中:连点只认第一次,免得两次请求交错、
  /// 最后落地的结果与界面显示对不上。
  bool _micBusy = false;
  MemberStatus myStatus = MemberStatus.free;

  final List<Member> _members = [];
  final Set<String> _speakingIds = {};

  /// 大厅 presence 摘要(未进房也可见,circleId -> (人数, 名字, 是否需敲门))
  final Map<String, ({int count, List<String> names, bool knockRequired})>
      circlePresence = {};

  /// 圈级设置(服务器权威):注册圈与否、端到端加密是否由圈主定死。
  ///
  /// 来源:welcome.circle(本连接证明的那个圈)、circle_summary、circle_settings。
  /// e2ee 为 null = 圈子没有统一规定(老圈 / env 圈),沿用本机开关。
  final Map<String, ({bool registered, bool? e2ee})> circleInfo = {};

  /// 这个圈子是注册圈吗(有圈主,kick/敲门/加密只归圈主管)。
  bool isRegisteredCircle(String id) => circleInfo[id]?.registered ?? false;

  /// 本机是不是这个圈的圈主:只看本机有没有钥匙 —— 钥匙才是凭据。
  /// (welcome.isOwner 只是服务器对那把钥匙的回执,不单独当真。)
  bool isOwnerOf(String id) =>
      (settings?.ownerKeyFor(id) ?? _signaling.issuedOwnerKey(id)) != null;

  /// 能不能动踢人 / 敲门 / 加密这些管理控件:
  /// env 圈人人可动(老行为),注册圈只有圈主。
  bool canModerate(String id) => !isRegisteredCircle(id) || isOwnerOf(id);

  String? _ownerKeyFor(String id) =>
      settings?.ownerKeyFor(id) ?? _signaling.issuedOwnerKey(id);

  /// 圈级 E2EE 规定变化时回调(main.dart 接到 E2EEController.setCirclePolicy)。
  void Function(String circleId, bool? enabled)? onCirclePolicy;

  /// 被解散的圈子(UI 弹一次「圈子已被圈主解散」,然后从列表拿掉)。
  String? dissolvedCircleId;

  /// 圈主操作的回执。UI 读一次即清空(见 [consumeOwnerResult])。
  ({String op, String circleId, String? error})? ownerResult;

  void consumeOwnerResult() {
    if (ownerResult == null) return;
    ownerResult = null;
    notifyListeners();
  }

  void consumeDissolved() {
    if (dissolvedCircleId == null) return;
    dissolvedCircleId = null;
    notifyListeners();
  }

  void _applyCircleInfo(Object? raw) {
    if (raw is! Map) return;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return;
    final e2ee = raw['e2ee'];
    circleInfo[id] = (
      registered: raw['registered'] == true,
      e2ee: e2ee is bool ? e2ee : null,
    );
    onCirclePolicy?.call(id, e2ee is bool ? e2ee : null);
    final prev = circlePresence[id];
    if (raw.containsKey('knockRequired')) {
      circlePresence[id] = (
        count: prev?.count ?? 0,
        names: prev?.names ?? const <String>[],
        knockRequired: raw['knockRequired'] == true,
      );
    }
  }

  // ── 圈主操作 ──────────────────────────────────────────────────────
  // 全部返回 Future<String?>:null = 成功;否则是原因码
  // (no_key / timeout / 服务器 owner_error 的 reason)。
  // 为什么要等回执而不是发完就算:换口令成功之前绝不能改本地口令 ——
  // 本地先改、服务器没换成,本机就用新口令去证明,自己把自己锁在门外。

  final List<({String op, String circleId, Completer<String?> done})>
      _ownerWaiters = [];

  Future<String?> _ownerOp(
      String op, String id, void Function(String key) sendIt) {
    final key = _ownerKeyFor(id);
    if (key == null) return Future<String?>.value('no_key');
    final done = Completer<String?>();
    final waiter = (op: op, circleId: id, done: done);
    _ownerWaiters.add(waiter);
    sendIt(key);
    return done.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _ownerWaiters.remove(waiter);
      return 'timeout';
    });
  }

  void _settleOwnerWaiters(String op, String id, String? error) {
    _ownerWaiters.removeWhere((w) {
      if (w.op != op || w.circleId != id) return false;
      if (!w.done.isCompleted) w.done.complete(error);
      return true;
    });
  }

  /// 刚建好的圈:让连接去证明(顺带登记)它,好尽快拿到圈主钥匙。
  ///
  /// 只在空闲时改 authCircleId —— 正在别的房间里时一改就会断掉那个房间;
  /// 那种情况下等用户第一次进这个圈时自然会登记。
  void ensureRegistered(String id) {
    if (phase == RoomPhase.idle) _signaling.authCircleId = id;
  }

  /// 换口令:[newVerifier] 由调用方在后台算好(Argon2 不能在这里同步跑)。
  Future<String?> setCirclePasscodeAsOwner(String id, String newVerifier) =>
      _ownerOp(
          'circle_passcode_set',
          id,
          (key) => _signaling.setCirclePasscode(id,
              ownerKey: key, verifier: newVerifier));

  Future<String?> setCircleE2EEAsOwner(String id, bool enabled) => _ownerOp(
      'circle_e2ee_set',
      id,
      (key) => _signaling.setCircleE2EE(id, ownerKey: key, enabled: enabled));

  Future<String?> deleteCircleAsOwner(String id) => _ownerOp('circle_delete',
      id, (key) => _signaling.deleteCircle(id, ownerKey: key));

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

  /// 进房总超时:兜住「服务器收了 join 却永远不回话」这类静默失败。
  ///
  /// ## 为什么必须有
  ///
  /// 前三次「卡在正在进去…」都是某条具体路径漏了出口,一条条补。但漏的
  /// 方式是**无穷**的:信令层在凭据不全时会拒发 hello 而**不关连接**
  /// (signaling_client.dart 的 `_sendHelloWithProof`),服务端也可能
  /// 收下 join 之后因为任何原因不回 room/token。这些路径不产生任何事件,
  /// 因此不可能靠「多处理一条消息」修好 —— 只有时间能把它们兜住。
  ///
  /// ## 为什么是 25 秒
  ///
  /// 下界由最慢的**正常**路径定:信令断开后指数退避重连(1+2+4+8s)再
  /// 重新握手,最坏约 15-18s 仍属正常。20s 会误伤这一条,25s 留了余量。
  /// 上界由人的耐心定:超过半分钟干等,用户早已认定「又卡死了」。
  ///
  /// ## 敲门期间由谁管:交接,而不是放手
  ///
  /// 敲门是**有人在等另一个人**,30 秒完全正常,这段时间的超时由
  /// [knockTimeout] 那条计时器负责。所以 `knock_waiting` 到达时本计时器
  /// 会被撤掉 —— 两个计时器同时管一件事,必然是短的那个先开枪、把话说错
  /// (它会说「服务器没回话」,而实情是「对方还没来应门」)。
  ///
  /// ⚠️ 但**撤掉不等于从此不管**。被放行时 `case 'room'` 会把 `_knockTimer`
  /// 撤掉,而那时 token 还没到 —— 所以 `case 'room'` 必须把本计时器重新挂上。
  /// 交接链完整是这样的:join 挂表 → knock_waiting 交给敲门 30s →
  /// room 交回本计时器 → token + RTC 成功后 `_connectRtc` 撤表。
  /// 任何一环只撤不挂,那一段窗口就又变成「永久转圈」。
  static const joinTimeout = Duration(seconds: 25);

  Timer? _joinTimer;

  /// 第几次进房。用来识别「过期的那一次」。
  ///
  /// ## 为什么 `phase != joining` 这个判据不够
  ///
  /// `_connectRtc` 里 await 的是真实的媒体连接,可能要好几秒。这期间用户
  /// 完全可能按「算了」(leave)然后再进一次 —— 此时 phase 又回到了
  /// joining,旧那次的 await 一返回就会把 `inRoom` 和新那次的 completer
  /// 一起「提交」掉,而它连的是**上一次**的房间。表现是退了房又自己回去,
  /// 或者进到刚才那个圈子里。
  ///
  /// 单调递增的代次能分清这件事:进入时记下代次,提交前比对,不是自己
  /// 那一代就默默收手。比 phase 多一个维度,也只多这一个 int。
  int _joinEpoch = 0;

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
  ///
  /// [force] 仅供 [retryJoin] 内部使用:它已经把 phase 摆到 joining
  /// (为了不让界面跳回主页),此时那个「已经在进房了」的守卫会误伤。
  ///
  /// [micOn] 这次连上之后是否开麦。默认 null = 按设置「进圈时打开麦克风」,
  /// 只适用于**用户主动**进圈。自动进圈的调用方(挂机自动进圈、被 reach
  /// 拉过去)必须显式传 `false`:没有人按下任何东西,就不该有人被听见。
  Future<void> join(String targetCircleId,
      {bool force = false, bool? micOn}) async {
    if (!force && phase == RoomPhase.joining) return;
    // 这次进房由谁发起,在最前面就定下来 —— 之后的预热直连与 token 事件
    // 都只读它。凭据检查失败提前 return 时它也无害:下次 join 会重写。
    _micOnAfterConnect = micOn ?? (settings?.joinWithMicOn ?? true);

    // ⚠️ 凭据不全就别进 joining —— 否则会**永远**停在「正在进去…」。
    //
    // 信令层的 connect() 在凭据不完整时会**直接 return 不发起连接**
    // (见 signaling_client.dart:270,理由是白撞一次只会把服务端的失败
    // 计数往上推、离 4429 更近)。既然连接压根没建立,就不会有 4401,
    // 也就不会有 _disconnected —— 上一轮加的失败处理全都等不到。
    //
    // 2026-09-19 真机实测:通过邀请链接加的圈子不填口令,必然卡死。
    // 修 4401 那次只覆盖了「连上了但被拒」,没覆盖「根本没连」。
    final cred = settings?.credentialFor(targetCircleId);
    if (cred != null && cred.mode != AuthMode.none && !cred.isComplete) {
      circleId = targetCircleId;
      _failJoin(StateError('auth_required'));
      return;
    }

    // ⚠️ 换代**之前**先把上一次的 completer 了结掉。
    //
    // force 路径(retryJoin)会直接盖掉 `_joinCompleter`,被盖掉的那个
    // 从此没有任何人会去 complete —— 谁 await 了它谁就永远挂着。UI 读的是
    // phase 不是这个 future,所以界面看着正常,但 `await join()` 的调用方
    // (以及测试)会静默卡死。这是「卡在正在进去…」的一种隐身变体。
    _abandonJoinCompleter(StateError('join_superseded'));

    _joinEpoch++;
    phase = RoomPhase.joining;
    errorMessage = null;
    circleId = targetCircleId;
    _joinStopwatch = Stopwatch()..start();
    _joinCompleter = Completer<void>();
    _armJoinWatchdog();
    notifyListeners();

    // ⚠️ 必须在 join 之前摆正「要证明哪个圈」。
    //
    // 2026-09-19 真机实测:这一行原本不存在,于是进任何**非主圈**的圈子,
    // 客户端都拿主圈的口令去算证明 —— 服务端 4401、界面反复要口令,
    // 而用户输的口令其实一直是对的。不只影响新加的圈子,
    // 已有的第二、第三个圈同样进不去。
    //
    // 值没变时这个 setter 什么都不做,所以这里不会引起多余的重连。
    _signaling.authCircleId = targetCircleId;
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
    // 清掉上一轮的错误,但**绝不能落到 idle**。
    //
    // 移动端 home_screen 用 `phase != idle` 判断「是否显示房间页」,
    // 一旦 idle 就立刻切回圈子列表 —— 用户刚在房间页填完口令按了重试,
    // 界面却跳回主页,而后面还要 await 握手最多 10 秒,他只能干看着。
    // 2026-09-19 真机实测报告的「填完口令自动回到主页面」就是这条。
    //
    // 直接进 joining:语义也更准 —— 我们确实正在进房。
    phase = RoomPhase.joining;
    errorMessage = null;
    circleId = targetCircleId;
    notifyListeners();

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
      // 走 _failJoin 而不是手写两行:本方法进来就把 phase 摆成了 joining,
      // 只落 error 而不解 completer / 不换代,就是又留一条半开的路。
      _failJoin(StateError('auth_failed'));
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
    unawaited(join(targetCircleId, force: true).catchError((Object _) {}));
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
    _knockTimer = null;
    _joinTimer?.cancel();
    _joinTimer = null;
    knocking = false;
    knockRequests.clear();
    _lastRtcUrl = null;
    _lastRtcToken = null;
    mediaDowngraded = false;
    locations.clear();

    // ⚠️ 以下四样以前一样都没清,下一次 join 会带着上一次的残留开工:
    //
    // - `_joinCompleter`:上一次 await join() 的人永远吊着(隐身的卡死);
    // - `_joinStopwatch`:不归零的话,下次进房的「耗时」会把用户在房里
    //    待的整段时间算进去,性能数字直接失真;
    // - `_joinEpoch`:退房就得换代,否则在途的 _rtc.join() 回来照样提交;
    // - 预热 token 缓存:留着不删,下次进房会拿一张属于上一段会话的
    //    token 去先行连媒体。退房往往正是因为口令/权限出了问题,
    //    那张旧 token 多半已经不作数,却会让 RTC 先连上去再失败。
    _abandonJoinCompleter(StateError('join_cancelled'));
    _joinStopwatch = null;
    _joinEpoch++;
    // 退房后任何残留的开麦意图都作废:下一次连上媒体的若是自动路径,
    // 它不该继承上一次「用户点了进圈」的开麦决定。
    _micOnAfterConnect = false;
    _prefetchedCircle = null;
    _prefetchedUrl = null;
    _prefetchedToken = null;
    _prefetchedAt = null;

    _signaling.leave();
    // 先落 idle 再拆媒体:_rtc.leave() 会触发 onDisconnected,
    // 而那个监听器看到 inRoom 就会当成掉线去自动恢复 ——
    // 结果是用户按了「算了」,App 却自己又连了回去。
    phase = RoomPhase.idle;
    circleId = null;
    await _rtc.leave();
    _members.clear();
    _speakingIds.clear();
    muted = true;
    notifyListeners();
  }

  /// 开麦 / 静音切换。**先让 RTC 层做,做成了才改 [muted]**。
  ///
  /// 以前是先翻 [muted] 再去开麦,带出两个真实的 bug:
  ///
  /// 1. 媒体闲时挂起时,唤醒是异步的,而 `setMuted` 紧跟着同步发出 ——
  ///    打在一个还没连上的房间上被吞掉;唤醒随后又按静音进房。
  ///    结果:按钮显示「麦克风开着」,麦克风其实是关的。
  /// 2. 没有任何错误处理。没给麦克风权限时 [muted] 已经翻成 false,
  ///    界面同样说谎,用户也不知道该去哪里改。
  ///
  /// 返回切换之后**真实的** [muted](小组件要把它写回去)。
  Future<bool> toggleMute() async {
    // 不在房里就没有麦克风可开:什么都不做,也不假装做了。
    // (joining 期间房间页已经显示,按钮能按到;那时的开麦意图由
    // 「进圈时打开麦克风」决定,这里不去改它,免得显示与意图各说各话。)
    if (phase != RoomPhase.inRoom || _micBusy) return muted;
    _micBusy = true;
    final wantMuted = !muted;
    try {
      if (!wantMuted && (mediaDowngraded || _wakeInFlight != null)) {
        // 媒体挂起中要开麦:等唤醒**真正落地**再看结果。
        // 唤醒若是别人触发的(来人了)且正在路上,它按静音进房,
        // 落地后再补一次开麦;没在路上就由我们发起一次「带着开麦」的唤醒。
        final pending = _wakeInFlight;
        if (pending != null) {
          final r = await pending;
          if (r == null || phase != RoomPhase.inRoom) {
            _setMicNotice(MicNotice.unmuteFailed);
            return muted;
          }
          await _applyMute(false);
        } else {
          final r = await _wakeMedia(micOn: true);
          if (r == null) {
            // 唤醒本身失败(没有可用 token / 连不上):麦克风当然没开。
            _setMicNotice(MicNotice.unmuteFailed);
            return muted;
          }
          // muted 已由 _wakeMedia 按真实结果落好,失败提示也在那里发。
        }
      } else {
        await _applyMute(wantMuted);
      }
      return muted;
    } finally {
      _micBusy = false;
    }
  }

  /// 让 RTC 层切换麦克风,并**按它回报的真实状态**落 [muted]。
  Future<void> _applyMute(bool wantMuted) async {
    // 开麦途中用户退了房:leave() 已经把 muted 落回 true,
    // 迟到的结果不许再把它改回「开着」。
    final epoch = _joinEpoch;
    try {
      await _rtc.setMuted(wantMuted);
      if (epoch != _joinEpoch) return;
      muted = wantMuted;
      notifyListeners();
    } on MicException catch (e) {
      debugPrint('[lares] 麦克风切换失败: $e');
      if (epoch != _joinEpoch) return;
      muted = !e.micOnNow;
      _setMicNotice(wantMuted
          ? (e.micOnNow ? MicNotice.muteFailed : null)
          : MicNotice.forUnmute(e.kind));
    } catch (e) {
      // 实现方没按约定抛 MicException:不知道真实状态,只能保守。
      // 想开没开成 -> 仍当它关着(没有证据说它开了);
      // 想关没关成 -> 仍当它开着 —— 宁可让人以为自己还能被听见,
      // 也不能让一个其实开着的麦克风显示成静音。
      debugPrint('[lares] 麦克风切换失败(未分类): $e');
      _setMicNotice(wantMuted ? MicNotice.muteFailed : MicNotice.unmuteFailed);
    }
  }

  void _setMicNotice(MicNotice? notice) {
    micNotice = notice;
    notifyListeners();
  }

  /// UI 弹过提示之后调用,免得重复弹。
  void consumeMicNotice() {
    if (micNotice == null) return;
    micNotice = null;
    notifyListeners();
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

  /// 媒体唤醒:用保存的 token 重连(静默失败则等下次 token 事件)。
  ///
  /// 默认**静音**唤醒:自动唤醒(来人了)绝不能把人变成开麦。
  /// 只有用户亲手按了开麦([toggleMute])才传 `micOn: true`。
  ///
  /// 返回 RTC 的真实结果;没有可唤醒的(未挂起 / 没 token)或失败则为 null。
  /// 调用方可以 await 它 —— toggleMute 正是靠这一点修掉了「开麦被吞」。
  Future<RtcJoinResult?> _wakeMedia({bool micOn = false}) {
    final inFlight = _wakeInFlight;
    if (inFlight != null) return inFlight;
    if (!mediaDowngraded) return Future.value(null);
    final url = _lastRtcUrl;
    final token = _lastRtcToken;
    if (url == null || token == null) return Future.value(null);
    mediaDowngraded = false;
    final epoch = _joinEpoch;
    notifyListeners();
    final future = () async {
      try {
        final hq = await _currentHighQuality();
        // 媒体唤醒也是一次真正的 join:加密准备必须重做一遍。
        // 少了这一行,闲时降级后自动唤醒的那次通话就会悄悄变成明文。
        await prepareEncryption?.call(circleId);
        final r = await _rtc.join(
            url: url,
            token: token,
            startMuted: !micOn,
            highQuality: hq,
            tuning: settings?.audioTuning ?? AudioTuning.standard);
        // 唤醒途中用户退了房:这次结果不作数,连好的媒体也拆掉。
        if (epoch != _joinEpoch || phase != RoomPhase.inRoom) {
          await _rtc.leave();
          return null;
        }
        muted = !r.micOn;
        if (micOn && !r.micOn) {
          _setMicNotice(MicNotice.forUnmute(r.micFailure));
        }
        _resetIdleTimer();
        notifyListeners();
        return r;
      } catch (e) {
        debugPrint('[lares] 媒体唤醒失败: $e');
        if (epoch == _joinEpoch) {
          mediaDowngraded = true; // 唤醒失败,保持挂起
          muted = true;
          notifyListeners();
        }
        return null;
      } finally {
        _wakeInFlight = null;
      }
    }();
    _wakeInFlight = future;
    return future;
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
    final id = circleId;
    // 注册圈要带圈主钥匙(服务器不认自报的 userId);env 圈不带,老行为不变。
    final key = id == null ? null : _ownerKeyFor(id);
    _signaling.send({
      't': 'kick',
      'circleId': id,
      'userId': targetUserId,
      'ownerKey': ?key,
    });
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

  /// 进目标圈;已在别的房间则先退(§2.2 多圈子互不干扰)。已经在这个圈里就什么都不做。
  ///
  /// 小组件深链与推送通知「加入」共用这一条,免得两处各写一份「先退再进」,
  /// 日后改一处漏一处。[micOn] 原样传给 [join]:默认 null = 用户主动进圈,
  /// 按设置「进圈时打开麦克风」。
  ///
  /// 不 await join 本身:它要等服务器回 room/token 才完成,界面读的是 phase。
  /// 接住 completeError,理由同 [retryJoin]。
  Future<void> switchToCircle(String targetCircleId, {bool? micOn}) async {
    if (phase != RoomPhase.idle) {
      if (circleId == targetCircleId) return;
      await leave();
    }
    unawaited(join(targetCircleId, micOn: micOn).catchError((Object _) {}));
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
  ///
  /// [micOn] 原样传给 [join]。默认 `false`:这个方法最早只服务于
  /// presence reach(别人来找我),那不是用户按下的。推送通知里点「加入」
  /// 才是用户主动的,它**显式传 null** = 按设置「进圈时打开麦克风」。
  /// (Dart 里显式传 null 会盖掉默认值,不会回落成 false。)
  Future<void> switchServerAndJoin({
    required String circleId,
    String? url,
    bool? micOn = false,
  }) async {
    if (phase != RoomPhase.idle) await leave();
    if (url != null) _signaling.url = url;
    // 跨服务器通常意味着跨网络,超时给宽一点。
    final ok =
        await _signaling.waitHandshake(const Duration(seconds: 10));
    if (!ok) {
      // 这条路径上 phase 还是 idle(上面 leave() 刚落的),不存在半开的
      // joining,所以直接落 error 即可。文案是自定义的:humanize 认不出
      // 「换服务器失败」,而这件事值得说清楚是哪一步没成。
      phase = RoomPhase.error;
      errorMessage = '连不上那台服务器,没能过去';
      _joinEpoch++;
      notifyListeners();
      return;
    }
    // 接住 completeError:join() 失败时会 completeError,没人接就变成
    // 未捕获异步错误。本方法不 await 它,理由同 retryJoin ——
    // 界面读的是 phase,不是这个要等好几秒才落地的 future。
    //
    // micOn 默认 false —— reach 是**别人**来找我,不是我点的。
    // 被人拉进房间可以,被人拉进房间还顺手开了我的麦,不行。
    unawaited(join(circleId, micOn: micOn).catchError((Object _) {}));
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
    final key = _ownerKeyFor(targetCircleId);
    _signaling.send({
      't': 'knock_mode_set',
      'circleId': targetCircleId,
      'enabled': enabled,
      'ownerKey': ?key,
    });
  }

  /// 改名:本地立即生效,广播给同房成员与大厅。
  ///
  /// 长度上限在**这里**兜,不只在 UI 里兜:这是所有改名入口的必经之路
  /// (主屏的改名按钮、设置页的改名行,以及将来任何一个新入口),
  /// 放在这里才绕不过去。UI 那边用的是同一个 [capNickname],
  /// 所以「界面里看到的」与「真正生效的」不会各说各话。
  void rename(String name) {
    // 先截断再比较。顺序反了的话,一个「前 24 字与当前名字相同、
    // 只在第 25 字之后才有差别」的输入会被判成「改了」,
    // 截完却和原来一模一样 —— 白发一轮广播。
    final trimmed = capNickname(name);
    if (trimmed.isEmpty || trimmed == userName) return;
    userName = trimmed;
    // 这两步缺一不可,它们修的是**两个不同时刻**的名字:
    //   profile 帧      → 当前这条连接上的人,立刻看到;
    //   updateIdentityName → 下次**重连**时自报家门用的那份快照。
    // 只发 profile 的话,一次掉线重连就会拿启动时的旧名字重新 hello,
    // 所有人看到的名字悄悄变回去,而用户什么都没做 —— 这正是原来的 bug。
    _signaling.send({'t': 'profile', 'name': trimmed});
    _signaling.updateIdentityName(trimmed);
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
        _applyCircleInfo(msg['circle']);
        // 断线重连成功:自动恢复到之前所在的房间(README 待办:房间态恢复)
        final wanted = circleId;
        if (wanted != null && phase != RoomPhase.idle) {
          // (phase 改成 joining 挪到了下面:开麦规则要先看断线前的 phase)
          // 这是一次**新的**进房尝试:重新计时。不重新挂表的话,恢复房间态
          // 这条路上服务端若不回 room,又是一次无声的永久 joining ——
          // 它绕开了 join(),此前从来没有任何东西兜着它。
          _joinEpoch++;
          _armJoinWatchdog();
          // 自动恢复的开麦规则(绝不借机开麦):
          // - 原本在房里:保持断线前的状态(静音的人回来仍是静音);
          // - 原本在 joining(用户刚点的那次、或掉线恢复还没连上):
          //   意图早已定好,不动它 —— 恢复路径在掉线那一刻就记下了断线前状态;
          // - 原本已经失败(error):那次进圈已经结束了,这是自动重试,一律静音。
          if (phase == RoomPhase.inRoom) {
            _micOnAfterConnect = !muted;
          } else if (phase == RoomPhase.error) {
            _micOnAfterConnect = false;
          }
          phase = RoomPhase.joining;
          _signaling.join(wanted);
          _signaling.prefetchToken(wanted); // 重连后重备预热 token
          notifyListeners();
        }
      case 'room':
        if (msg['circleId'] != circleId) return;
        knocking = false; // 进房成功(直接进或敲门被放行)
        _knockTimer?.cancel();
        _knockTimer = null;
        // ⚠️ 收到 room 不等于进房结束 —— 能听到声音还差一个 token。
        //
        // 服务端 joinCircle 是**先发 room 快照、再去 mint LiveKit token**
        // (server/src/index.js:867-878)。中间那一段是真会出事的:mint 要
        // 访问 LiveKit,可能卡在握手上,进程也可能正好在这儿被杀;而 TCP
        // 半开时连 error 都不会有 —— 只有沉默。
        //
        // 沉默恰好躲得过上面 case 'error' 的白名单:白名单只能接住「服务端
        // 明确说了失败」,接不住「服务端什么都不说」。
        //
        // 敲门那条路尤其危险:knock_waiting 到达时把总超时交接给了敲门那
        // 30 秒,被放行后上面一行又把 _knockTimer 撤掉 —— 若此处不重新挂表,
        // 从 room 到 token 这段就一个计时器都不剩,正是「卡在正在进去…」
        // 的第四种形状(前三次都是漏了某条具体出口,这次是漏了一段时间)。
        //
        // 重新挂而不是沿用 join() 那只:room 已经证明服务端活着、这次 join
        // 是有效的,该给后面的 token + RTC 一段完整预算,而不是剩下的残值。
        // 成功进房时 _connectRtc 会撤掉它,失败时 _failJoin 会撤掉它。
        if (phase == RoomPhase.joining) _armJoinWatchdog();
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
        // 来人了:若媒体挂起则恢复,别错过第一句招呼。
        // 静音唤醒 —— 别人进来不是你开麦的理由。
        unawaited(_wakeMedia());
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
      // 服务端的错误报文。以前**只**认 rtc_not_configured,其余一律落地无声 ——
      // 而服务端在 join 这条路上还会发 token_failed / auth_scope /
      // already_in_room / rate_limited(见 server/src/index.js)。
      // 每一条都意味着「这次进房不会有 room/token 了」,不接住就是永久 joining。
      case 'error':
        final String? reason = msg['message'] as String?;
        if (reason == 'rtc_not_configured') {
          // presence 已通但 RTC 未配置:标注错误,方便联调
          _failJoin(StateError('rtc_not_configured'));
          return;
        }
        // 只在**正在进房**时才当成进房失败。同一条 socket 上还跑着聊天和
        // 图片,它们被拒(too_large / bad_json)与这次进房毫无关系,
        // 拿来打断用户是另一种形式的误伤 —— 所以这里是白名单,不是黑名单。
        if (phase != RoomPhase.joining) return;
        switch (reason) {
          // 服务端签发 RTC token 失败:媒体服务那边的问题,填口令没用。
          case 'token_failed':
            _failJoin(StateError('rtc_not_configured'));
          // 本连接证明的不是这个圈子。口令对不上号,该让用户去填。
          case 'auth_scope':
          case 'auth_required':
          case 'auth_failed':
            _failJoin(StateError('auth_failed'));
          case 'rate_limited':
            _failJoin(StateError('rate_limited'));
          // 服务端认为这个会话已经在某个房间里了(上一次退房没走干净)。
          // 重连一次比让用户干等强:新连接上没有这个陈旧会话。
          case 'already_in_room':
            _failJoin(StateError('already_in_room'));
          // 服务端没收到 hello 就收到了 join。信令层的排队本该杜绝这件事,
          // 真发生了说明握手掉了 —— 等不到 room,得给出路。
          case 'say_hello_first':
            _failJoin(StateError('handshake_lost'));
          default:
            // 其余(bad_json / too_large / payload_too_large / userId_required)
            // 基本可以断定不是 join 引起的,交给总超时兜底,不误伤用户。
            break;
        }
      case 'circle_summary':
        final id = msg['circleId'] as String?;
        if (id == null) return;
        circlePresence[id] = (
          count: (msg['count'] as num?)?.toInt() ?? 0,
          names: (msg['names'] as List? ?? []).whereType<String>().toList(),
          knockRequired: msg['knockRequired'] == true,
        );
        // 新字段(老服务器不发):没有 registered 就不动 circleInfo
        if (msg.containsKey('registered')) {
          _applyCircleInfo({
            'id': id,
            'registered': msg['registered'],
            'e2ee': msg['e2ee'],
          });
        }
        notifyListeners();
      case 'circle_settings':
        _applyCircleInfo(msg['circle']);
        notifyListeners();
      case 'owner_ok':
      case 'owner_error':
        final result = (
          op: msg['op'] as String? ?? '',
          circleId: msg['circleId'] as String? ?? '',
          error: msg['t'] == 'owner_error'
              ? (msg['reason'] as String? ?? 'unknown')
              : null,
        );
        ownerResult = result;
        _settleOwnerWaiters(result.op, result.circleId, result.error);
        notifyListeners();
      case 'circle_deleted':
      case '_circle_deleted':
        final id = msg['circleId'] as String?;
        if (id == null || id.isEmpty) return;
        dissolvedCircleId = id;
        circleInfo.remove(id);
        circlePresence.remove(id);
        if (circleId == id) {
          // 在房里:真的退出(断媒体),提示由主页读 dissolvedCircleId 弹;
          // 还在进:按失败收尾,错误文案就是「圈子已被圈主解散」。
          if (phase == RoomPhase.inRoom) {
            unawaited(leave());
          } else if (phase == RoomPhase.joining) {
            _failJoin(StateError('circle_deleted'));
          }
        }
        notifyListeners();
      case '_register_failed':
        if (phase == RoomPhase.joining || phase == RoomPhase.inRoom) {
          _failJoin(StateError(msg['reason'] as String? ?? 'register_failed'));
        }
      case 'circle_rekeyed':
        // 圈主换了口令:服务器紧接着 4401 关连接,走既有的「请输入口令」流程。
        break;
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
        // 交接计时器:从这一刻起这次进房由敲门那 30 秒负责,
        // 总超时必须撤掉。两个计时器同时管一件事,短的那个会先开枪 ——
        // 而它说的是「服务器没回话」,与实情(对方还没来应门)不符。
        _joinTimer?.cancel();
        _joinTimer = null;
        notifyListeners();
        _knockTimer?.cancel();
        _knockTimer = Timer(knockTimeout, () {
          if (!knocking) return;
          knocking = false;
          _signaling.leave();
          // 走 _failJoin:它统一负责落 error、换代、撤计时器、解 completer。
          // 以前这里是手写的一份,于是每次给失败路径加清理动作都要记得
          // 来改这一处 —— 漏一次就是一条新的卡死路径。
          // 文案仍由这里定(humanize 认不出 knock_timeout,会落到泛泛的
          // 「没能进去」),所以紧接着覆盖一次。
          _failJoin(StateError('knock_timeout'));
          errorMessage = '没人应门,稍后再敲';
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
      // ⚠️ 信令层**放弃重连**时发的终局消息。必须处理,否则永久卡死。
      //
      // 2026-09-19 真机实测报告的「再次进入卡在正在进去…」就是这条:
      // 第一次 4401 时信令层给一次重试机会(nonce 可能只是正常过期),
      // 第二次仍 4401 就发 _auth_failed 并**彻底停止重连**
      // (见 signaling_client.dart 的 _onAuthRejected —— 不停会撞 4429 封 IP)。
      //
      // 此后不会再有任何 _disconnected 到来,上面那条分支等不到,
      // phase 永远停在 joining。
      //
      // 为什么之前的测试没抓到:FakeSignalingClient 从不走真实的
      // 4401 重试逻辑,fake 环境下「退出再进入」一直是好的。
      case '_auth_failed':
        if (phase == RoomPhase.joining || phase == RoomPhase.inRoom) {
          _failJoin(StateError('auth_failed'));
        }
      case '_rate_limited':
        if (phase == RoomPhase.joining || phase == RoomPhase.inRoom) {
          _failJoin(StateError('rate_limited'));
        }
      // ⚠️ 信令层「压根没去连」时发的消息(凭据不全,见 signaling_client.dart
      // 的 _emitCredentialRequired)。与 _auth_failed 的区别是「没试」而非
      // 「试了被拒」,但对这次进房而言结局一样:不会有 room、不会有 token、
      // 也不会有 _disconnected —— 不接住就是第四次「卡在正在进去…」。
      //
      // join() 里那道凭据前置检查覆盖不到这条:它读 SettingsStore,
      // 信令层读的是自己的 CredentialSource,两者可以不一致。
      case '_credential_required':
        if (phase == RoomPhase.joining || phase == RoomPhase.inRoom) {
          _failJoin(StateError('auth_required'));
        }
      case '_disconnected':
        if (phase == RoomPhase.inRoom) {
          // 自动恢复:记下断线前的麦克风状态,welcome 之后按它还原 ——
          // 静音的人回来仍是静音,绝不借机开麦。
          // (不在这里把 muted 改成 true:信令断了,媒体可能还连着、还在发布,
          // 那时显示「静音」就是在说谎。媒体真正重连时由 _connectRtc 按真实结果落。)
          _micOnAfterConnect = !muted;
          phase = RoomPhase.joining; // 信令重连后会自动 hello;房间态待恢复
          // 掉出房间也要挂表:若重连始终不成(信令层的重连链可能在
          // 凭据不全时静默断掉 —— connect() 会直接 return 不建连接),
          // 这里没有任何东西会再来,界面就永久停在「正在进去…」。
          _armJoinWatchdog();
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
    _joinStopwatch = null;
    _joinTimer?.cancel();
    _joinTimer = null;
    // 失败也要换代:此后任何在途的 _rtc.join() 回来都不许再提交状态。
    _joinEpoch++;
    // completeError 必须有人接,否则会变成未捕获异步错误。
    // join() 的调用方(home_screen)已经 catch 了。
    _joinCompleter?.completeError(error);
    _joinCompleter = null;
    notifyListeners();
  }

  /// 了结一个即将被丢弃的 completer,**不动** phase。
  ///
  /// 与 [_failJoin] 的分工:那个是「这次进房失败了,告诉用户」,
  /// 这个是「这次进房不算数了,别让 await 它的人吊着」——
  /// 后者发生在 leave() 和 retryJoin() 里,那时界面该走的路已经另有安排。
  void _abandonJoinCompleter(Object reason) {
    final pending = _joinCompleter;
    _joinCompleter = null;
    if (pending == null || pending.isCompleted) return;
    // completeError 必须有人接。join() 的直接调用方都 catch 了,
    // 但 leave() 是 UI 主动调的,此处再兜一层以防万一。
    pending.future.catchError((Object _) {});
    pending.completeError(reason);
  }

  /// 挂上总超时。已有的先撤 —— 两个计时器管同一次进房必然打架。
  void _armJoinWatchdog() {
    _joinTimer?.cancel();
    _joinTimer = Timer(joinTimeout, () {
      // 到点还停在 joining 才算数。正常进房/失败路径都会撤掉它,
      // 这里再核一次是为了容忍「撤销与触发赛跑」那一瞬。
      if (phase != RoomPhase.joining) return;
      // 敲门自有 30s 计时器,不该被这里抢先开枪(措辞会说错)。
      if (knocking) return;
      // 走 leave 而不是只落 error:服务端可能已经把我们记成在房里了
      // (join 收到了、只是回包没来),不打招呼就走会在那边留一个幽灵成员。
      _signaling.leave();
      _failJoin(TimeoutException('join_timeout', joinTimeout));
    });
  }

  /// 媒体掉线后的自动恢复:用缓存 token 重连,连不上就给用户一条出路。
  ///
  /// 只试一次。LiveKit 自己已经做过重连努力才会发 RoomDisconnectedEvent,
  /// 在它之上再叠一轮退避重试,只会让用户对着「正在进去…」多等一倍时间 ——
  /// 而这正是要消灭的那个症状。
  Future<void> _recoverMedia() async {
    final id = circleId;
    // 连在哪个圈都不知道就别装作能恢复。落 error,让用户自己决定要不要再进。
    if (id == null) {
      _failJoin(StateError('rtc_dropped'));
      return;
    }

    _joinEpoch++;
    _joinStopwatch = Stopwatch()..start();
    _armJoinWatchdog();

    // ⚠️ 向服务端**重新要一张 token**,不复用 `_lastRtcToken`。
    //
    // token TTL 是 2 小时,而这个产品的核心用法恰恰是长时间挂着。
    // 挂机超过 2h 后掉线,拿旧 token 去连必然失败 —— 症状是
    // 「自动恢复」看起来试了一下就报错,用户完全不知道为什么。
    //
    // 信令连接此时通常还活着(掉的是媒体),一条 join 就够;
    // 若信令也断了,消息会进 outbox,握手完成后自动补发。
    // 两种情况都由上面刚挂的 watchdog 兜底,不会无声无息地悬着。
    //
    // 用 join 而不是 token_prefetch:后者的回包带 `prefetch: true`,
    // 只进缓存不进房(见 'token' 分支),而恢复要的是真的连回去。
    _signaling.join(id);
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
    // 这次连接属于哪一代。下面每个提交点都要比对它 ——
    // 中途若用户退了房又进了别的圈,这次的结果就不该再落地。
    final epoch = _joinEpoch;
    _rtcConnecting = true;
    try {
      final highQuality = await _currentHighQuality();
      // 密钥必须在 Room 构造之前装好:RoomOptions.encryption 是构造期参数,
      // 进房之后再改一个字都不会生效。
      await prepareEncryption?.call(circleId);
      // 开麦与否在发起这次连接时就定下来(见 [_micOnAfterConnect] 的分类)。
      // 快照一份:连接途中若有新的 join 改写了字段,那一代自有它的连接。
      final wantMic = _micOnAfterConnect;
      final result = await _rtc.join(
          url: url,
          token: token,
          startMuted: !wantMic,
          highQuality: highQuality,
          tuning: settings?.audioTuning ?? AudioTuning.standard);
      final elapsed = result.elapsed;
      // 连上了,但这已经是上一代的事了(用户中途退了房 / 又进了别的圈)。
      // 把连好的媒体拆掉再走 —— 否则会留下一条没人管的音频流,
      // 而用户明明已经离开,却还在被别人听见。
      if (epoch != _joinEpoch) {
        await _rtc.leave();
        return;
      }
      lastJoinLatency = _joinStopwatch?.elapsed ?? elapsed;
      debugPrint('[lares] 进房分段: 总=${lastJoinLatency!.inMilliseconds}ms '
          'RTC=${elapsed.inMilliseconds}ms');
      _joinStopwatch = null;
      _joinTimer?.cancel();
      _joinTimer = null;
      phase = RoomPhase.inRoom;
      // 以 RTC 层回报的真实状态为准,不以「要求的」状态为准。
      muted = !result.micOn;
      // 要开没开成(多半是没给麦克风权限):进房照常成功,但得告诉用户。
      if (wantMic && !result.micOn) {
        micNotice = MicNotice.forUnmute(result.micFailure);
      }
      _joinCompleter?.complete();
      _joinCompleter = null;
      _resetIdleTimer();
      notifyListeners();
    } catch (e) {
      // 给用户看人话,原始异常进日志。
      // 曾经这里是 `'进房失败:$e'`,于是屏幕上出现过
      // 「ClientException with SocketException: Connection...」:
      // 用户看不懂,且长度不可控把标题行撑爆(2014px 溢出)。
      debugPrint('[lares] 进房失败(原始异常): $e');
      // 过期那一代的失败不该弹给用户:他早就不在等这次进房了,
      // 冒出来的错误只会盖掉当前这次的真实状态。
      if (epoch != _joinEpoch) return;
      // 走 _failJoin 而不是手写四行:超时计时器的撤销、代次推进、
      // stopwatch 的收尾都在那里。这里曾经是各写各的,于是每加一样
      // 要清的东西就得记得来改这一处 —— 而漏掉一次就是一个新的卡死。
      _failJoin(e);
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
    _joinTimer?.cancel();
    // 控制器都要没了,还吊着一个永不完成的 future 就纯属遗留垃圾。
    _abandonJoinCompleter(StateError('disposed'));
    _msgSub?.cancel();
    _speakingSub?.cancel();
    _rtcDropSub?.cancel();
    super.dispose();
  }
}

