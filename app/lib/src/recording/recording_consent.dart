/// 录音知情同意状态机(设计.md §9 录音与转写)。
///
/// 本模块是「是否允许采集音频」的**唯一权威**。录音服务只准读这里的
/// [RecordingConsentController.captureAllowed],不准自己判断。
///
/// 核心伦理约束只有一条:**绝不采集房间不知情的音频**。
/// 由此推出的关键设计 —— 「发出去」不等于「说到了」:
/// 信令客户端在断线期间会把消息塞进 outbox 静默排队,所以调用 send()
/// 什么都证明不了。唯一算数的凭据,是服务器把 `member_rec` 广播
/// **回显**给我自己(userId 匹配 + circleId 匹配 + active:true)。
/// 收到回显 = 房间里每个人都已经被告知 = 此刻才可以开麦采集。
///
/// 本文件**完全自足**:不引入 livekit_client / web_socket_channel,
/// 不碰任何平台通道,全部 I/O 经由注入的回调完成,可直接在纯 VM 的
/// `flutter test` 下跑。唯一的 Flutter 依赖是 foundation 提供的
/// [ChangeNotifier] 与 `@immutable` —— 两者都是纯 Dart 实现。
/// 未选用 package:meta 是因为它不是本包的直接依赖
/// (depend_on_referenced_packages)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 线协议常量
// ─────────────────────────────────────────────────────────────────────────────

/// 客户端 -> 服务器:请求开始录音。
const String kRecStart = 'rec_start';

/// 客户端 -> 服务器:已停止录音。
const String kRecStop = 'rec_stop';

/// 客户端 -> 服务器:录音期间的存活心跳,让服务器能过期掉崩溃者的残留状态。
const String kRecPing = 'rec_ping';

/// 服务器 -> 全体:某人录音状态变更。这也是本机开麦的唯一放行凭据。
const String kMemberRec = 'member_rec';

/// 服务器 -> 全体:房间快照。迟到者靠它立刻知道「已经有人在录」。
const String kRoomSnapshot = 'room';

/// 服务器 -> 全体:某人离开房间。
const String kMemberLeft = 'member_left';

/// 信令客户端在连接断开时**本地**注入的内部事件(并非服务器下发)。
/// 见 lib/src/net/signaling_client.dart 的 `_onDisconnected`。
const String kDisconnected = '_disconnected';

// ─────────────────────────────────────────────────────────────────────────────
// 状态枚举
// ─────────────────────────────────────────────────────────────────────────────

/// 本机录音同意状态机的状态。
///
/// 不变量:**有且只有 [recording] 允许采集音频**。
/// [RecordingConsentController.captureAllowed] 直接由本枚举派生,
/// 因此「未确认却在采集」在结构上不可能发生,而不是靠调用方自觉。
enum RecordingConsentState {
  /// 未录音。默认态 —— 录音默认关闭,这一点不允许用任何方式绕过。
  idle,

  /// 已发出 `rec_start`,正在等服务器把 `member_rec` 回显给我。
  /// **此状态下绝不采集**:房间还没被告知。
  arming,

  /// 已拿到回显凭据,正在录音。唯一允许采集的状态。
  ///
  /// 注意:信令中断后的宽限期内仍停留在本状态(见
  /// [RecordingConsentController.inGracePeriod]) —— 两秒的网络抖动
  /// 不该毁掉一整段录音,但宽限期一到还没重新确认就会强制停。
  recording,

  /// 正在收尾:已本地停采,`rec_stop` 已发出。是个瞬时态。
  stopping,

  /// 起录失败(最典型的是 armingTimeout 超时未收到回显)。
  /// 此状态下 [RecordingConsentController.notice] 必为非空。
  failed,
}

// ─────────────────────────────────────────────────────────────────────────────
// 给用户看的提示:语义标识
// ─────────────────────────────────────────────────────────────────────────────

/// 控制器要对用户说的那句话的**语义标识**。
///
/// 按 `docs/l10n-guide.md` 的分层纪律:本文件是模型层,拿不到也不该拿
/// [BuildContext],所以这里**只存标识,不存译文**,翻译查表放 UI 层
/// (见 `recording_indicator.dart` 的 `recordingNoticeText`)。
///
/// 每个值对应一个 ARB 键,命名一一对应:
///
/// | 枚举值                | ARB 键                              |
/// |-----------------------|-------------------------------------|
/// | circleIdEmpty         | `recordingNoticeCircleIdEmpty`      |
/// | alreadyInProgress     | `recordingNoticeAlreadyInProgress`  |
/// | armingTimeout         | `recordingNoticeArmingTimeout`      |
/// | serverMarkedInactive  | `recordingNoticeServerMarkedInactive` |
/// | removedFromRoom       | `recordingNoticeRemovedFromRoom`    |
/// | disconnected          | `recordingNoticeDisconnected`       |
/// | graceExpired          | `recordingNoticeGraceExpired`       |
/// | stateOutOfSync        | `recordingNoticeStateOutOfSync`     |
/// | signalingSilent       | `recordingNoticeSignalingSilent`    |
enum RecordingConsentNoticeCode {
  /// 圈子 ID 为空,压根无从录起。
  circleIdEmpty,

  /// 已有录音流程占用中,要求调用方先停。
  alreadyInProgress,

  /// 等服务器回执超时,起录失败。带 [RecordingConsentNotice.seconds]。
  armingTimeout,

  /// 服务器明确表示本机没在录(正面矛盾),已强制停。
  serverMarkedInactive,

  /// 本机已被移出房间,已强制停。
  removedFromRoom,

  /// 信令断开,宽限期内尝试恢复中。
  disconnected,

  /// 宽限期耗尽仍未恢复,已强制停。带 [RecordingConsentNotice.seconds]。
  graceExpired,

  /// 快照里没有我但我自以为在录,重新确认中。
  stateOutOfSync,

  /// 久无入站消息(半开连接看门狗),重新确认中。
  signalingSilent,
}

/// 一条待展示的提示 = 语义标识 + 它需要的参数。
///
/// 之所以不是裸枚举:有两条文案要把秒数嵌进句子里,而**语序在不同语言里会变**
/// (中文「超过 5 秒仍未恢复」,英文 "stayed down for more than 5 seconds"),
/// 所以秒数必须作为占位符参数传给 ARB,不能在这里拼成字符串。
@immutable
class RecordingConsentNotice {
  /// 构造一条提示。[seconds] 仅对带秒数的那两个 code 有意义。
  const RecordingConsentNotice(this.code, {this.seconds});

  /// 语义标识。
  final RecordingConsentNoticeCode code;

  /// 句子里要嵌的秒数;不需要参数的提示为 null。
  final int? seconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordingConsentNotice &&
          other.code == code &&
          other.seconds == seconds;

  @override
  int get hashCode => Object.hash(code, seconds);

  @override
  String toString() => 'RecordingConsentNotice(${code.name}, seconds: $seconds)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 值对象
// ─────────────────────────────────────────────────────────────────────────────

/// 某个正在录音的人(可能是别人,也可能是我自己)。
///
/// 驱动「X 正在录音」指示器。**刻意不假设只有一个录音者** ——
/// 协议允许多人同时录,UI 必须能同时显示多条。
@immutable
class RemoteRecorder {
  /// 构造一条录音者记录。
  const RemoteRecorder({
    required this.userId,
    required this.name,
    required this.since,
  });

  /// 录音者的用户 ID。也是 [RoomRecordingState] 里的去重键。
  final String userId;

  /// 展示名。服务器没给或给了非字符串时,解析阶段会退化成 userId ——
  /// 宁可显示一个 ID,也不能显示「 正在录音」这种没有主语的句子。
  final String name;

  /// 这一段录音的开始时刻(由服务器 `since` 的 epoch 毫秒转换而来)。
  /// 字段损坏时退化为本地当前时刻:时间戳不准是小事,
  /// 把「有人在录」这个事实丢掉才是大事。
  final DateTime since;

  /// 复制并覆盖部分字段。
  RemoteRecorder copyWith({String? userId, String? name, DateTime? since}) {
    return RemoteRecorder(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      since: since ?? this.since,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteRecorder &&
          other.userId == userId &&
          other.name == name &&
          other.since == since;

  @override
  int get hashCode => Object.hash(userId, name, since);

  @override
  String toString() =>
      'RemoteRecorder(userId: $userId, name: $name, since: $since)';
}

/// 房间整体的录音全景(纯值对象,UI 直接绑它重建)。
@immutable
class RoomRecordingState {
  /// 构造一份房间录音全景。[recorders] 会被原样持有,
  /// 请传入不可变列表(控制器内部保证这一点)。
  const RoomRecordingState({
    required this.recorders,
    required this.localUserId,
  });

  /// 空房间(没人在录)。
  static const RoomRecordingState empty = RoomRecordingState(
    recorders: <RemoteRecorder>[],
    localUserId: '',
  );

  /// 当前所有正在录音的人,按开始时间升序(同一时刻再按 userId),
  /// 保证同样的成员集合永远产出同样的顺序 —— 否则值相等性会假抖动,
  /// UI 也会无谓重排。
  final List<RemoteRecorder> recorders;

  /// 本机用户 ID,用来区分「我在录」和「别人在录」。
  final String localUserId;

  /// 是否有任何人正在录音(含我自己)。指示器的总开关。
  bool get anyoneRecording => recorders.isNotEmpty;

  /// 我自己是否在服务器眼里处于录音中。
  ///
  /// 注意:这是**服务器视角**,不等于「我可以采集」。
  /// 能不能采集只看 [RecordingConsentController.captureAllowed]。
  bool get localRecording =>
      localUserId.isNotEmpty &&
      recorders.any((RemoteRecorder r) => r.userId == localUserId);

  /// 除我之外正在录音的人。UI 显示「X、Y 正在录音」时用这个。
  List<RemoteRecorder> get others => List<RemoteRecorder>.unmodifiable(
    recorders.where((RemoteRecorder r) => r.userId != localUserId),
  );

  /// 同时录音的人数。
  int get recorderCount => recorders.length;

  /// 按 userId 查一个录音者,不在录则返回 null。
  RemoteRecorder? recorderOf(String userId) {
    for (final RemoteRecorder r in recorders) {
      if (r.userId == userId) return r;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomRecordingState &&
          other.localUserId == localUserId &&
          listEquals(other.recorders, recorders);

  @override
  int get hashCode => Object.hash(localUserId, Object.hashAll(recorders));

  @override
  String toString() =>
      'RoomRecordingState(localUserId: $localUserId, '
      'recorders: $recorders)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 控制器
// ─────────────────────────────────────────────────────────────────────────────

/// 采集许可变更回调。录音服务订阅它来开关麦克风。
typedef CapturePermissionChanged = void Function(bool allowed);

/// 出站信令发送函数。生产环境接 `SignalingClient.send`,测试里接一个数组。
typedef SignalingSend = void Function(Map<String, dynamic> msg);

/// 录音知情同意控制器。
///
/// 全部依赖都是注入的(发送函数、时钟),因此无需真网络、真时钟即可测试;
/// 定时器用 `dart:async` 的 [Timer],测试用 `fake_async` 推进。
///
/// 同时是 [ChangeNotifier],UI 可直接 listen 重建。
class RecordingConsentController extends ChangeNotifier {
  /// 构造一个同意控制器。
  ///
  /// [userId] 是本机用户 ID,回显匹配全靠它,**不能为空串**。
  /// [send] 出站发送函数;允许它抛异常,控制器内部一律吞掉
  /// (网络问题绝不能反过来打断状态机)。
  /// [now] 可注入时钟,默认 [DateTime.now]。
  /// [livenessTimeout] 默认关闭,开启前务必读它的文档(见字段说明)。
  RecordingConsentController({
    required this.userId,
    required SignalingSend send,
    DateTime Function() now = DateTime.now,
    this.armingTimeout = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 15),
    this.gracePeriod = const Duration(seconds: 10),
    this.livenessTimeout,
    this.onCaptureAllowedChanged,
  }) : assert(userId.isNotEmpty, 'userId 不能为空:回显匹配完全依赖它'),
       _send = send,
       _now = now;

  /// 本机用户 ID。
  final String userId;

  /// 起录等待回显的超时。超时即**失败**,绝不「先录着再说」。
  final Duration armingTimeout;

  /// 录音期间发送 `rec_ping` 的间隔。
  final Duration heartbeatInterval;

  /// 失去确认后的宽限期。期满仍未重新确认则自动停采。
  final Duration gracePeriod;

  /// 「入站静默」看门狗,**默认 null 即关闭**。
  ///
  /// 它要挡的是一个真实存在的洞:TCP 半开(连接已死但本机还没察觉)时
  /// 不会有 `_disconnected` 事件,心跳打进虚空,于是我一边采集、
  /// 房间那边可能早就不知情了。
  ///
  /// 但本协议下**无法安全地默认开启**:服务器只在状态**变化**时广播
  /// `member_rec`,安静的房间可以几分钟一条入站消息都没有;
  /// 而信令客户端又把 `pong` 在入站流里过滤掉了,拿不到它当活性信号。
  /// 贸然开启会把正常的长录音误杀。
  ///
  /// 因此:机制先留好,默认关闭。要真正堵上这个洞,需要服务器侧配合 ——
  /// 对 `rec_ping` 回一个 ack,或在录音期间周期性重播 `member_rec`。
  /// 届时把本值设为「略大于该周期」即可。
  final Duration? livenessTimeout;

  /// 采集许可变更回调。仅在**取值真的翻转**时触发,不会重复喊同一个值。
  final CapturePermissionChanged? onCaptureAllowedChanged;

  final SignalingSend _send;
  final DateTime Function() _now;

  RecordingConsentState _state = RecordingConsentState.idle;
  String? _activeCircleId;
  String? _message;
  RecordingConsentNotice? _notice;
  bool _disposed = false;

  /// 上一次向外广播过的采集许可值,用于「仅在翻转时回调」。
  bool _lastAnnouncedAllowed = false;

  Timer? _armingTimer;
  Timer? _heartbeatTimer;
  Timer? _graceTimer;
  Timer? _livenessTimer;
  Completer<bool>? _arming;

  /// 正在录音的人,按 userId 去重。
  ///
  /// 只能按 userId 建键,因为线协议的 `member_rec` 本身就只带 userId ——
  /// 设备维度根本无从表达。代价见类文档末尾的「已知取舍」。
  final Map<String, RemoteRecorder> _recorders = <String, RemoteRecorder>{};

  RoomRecordingState _room = RoomRecordingState.empty;

  // ── 对外只读状态 ──────────────────────────────────────────────────────────

  /// 当前状态机状态。
  RecordingConsentState get state => _state;

  /// **此刻是否允许采集音频**。录音服务的唯一依据。
  ///
  /// 由 [state] 直接派生,不是一个可以被单独写入的标志位 ——
  /// 所以不存在「状态是 arming 但许可却是 true」这种中间态。
  bool get captureAllowed => _state == RecordingConsentState.recording;

  /// 房间录音全景,驱动指示器。
  RoomRecordingState get room => _room;

  /// 给用户看的失败/警告文案;一切正常时为 null。
  ///
  /// 覆盖两类:起录失败(如超时)与录音中的异常(如信令中断被迫停止)。
  ///
  /// ⚠️ **未本地化的遗留路径,新代码请改用 [notice]。**
  /// 这里返回的是中文原文。之所以还留着:`ui/settings_sheet.dart` 目前把它
  /// 直接塞进 SnackBar,而那个文件不在本批次范围内;贸然删掉会让仓库编译不过。
  /// 消费方切到 [notice] + `recordingNoticeText(context, notice)` 之后,
  /// 本 getter 即可删除。
  String? get message => _message;

  /// 当前提示的**语义标识**([message] 的本地化版本)。
  ///
  /// 与 [message] 严格同生共灭:两者永远同时为 null 或同时非 null。
  /// UI 层用 `recordingNoticeText(context, notice)` 查表得到当前语言的句子。
  RecordingConsentNotice? get notice => _notice;

  /// 是否处在「失去确认但仍在宽限期内」。
  ///
  /// 此时 [captureAllowed] 仍为 true(抖动不该毁掉录音),
  /// 但 UI 应当给出显眼提示:再不恢复就要自动停了。
  bool get inGracePeriod => _graceTimer != null;

  /// 当前录音所属的圈子 ID;未在录音流程中时为 null。
  String? get activeCircleId => _activeCircleId;

  // ── 主流程 ────────────────────────────────────────────────────────────────

  /// 请求开始录音。返回「最终是否真的开录」。
  ///
  /// 流程(规则 1、2):
  /// 1. 立刻发 `rec_start`,状态进 [RecordingConsentState.arming];
  ///    **此时不采集**。
  /// 2. 等服务器把 `member_rec{userId: 我, active: true}` 回显回来。
  ///    收到即进 [RecordingConsentState.recording],许可放行,Future 返回 true。
  /// 3. [armingTimeout] 内没等到就判失败:许可全程没给过,
  ///    状态进 [RecordingConsentState.failed],[message] 给出中文原因,
  ///    Future 返回 false。
  ///
  /// 超时时会**补发一条 `rec_stop`**:如果 `rec_start` 其实已经到了服务器
  /// 只是回显丢了,房间里现在挂着一个「正在录音」的幽灵,而我根本没在录。
  /// 指示器一旦说过谎就再没人信,所以宁可多发一条无害的撤销。
  ///
  /// 重复调用是安全的:已在录同一圈子时直接返回 true(幂等);
  /// 正忙于其它圈子或正在收尾时返回 false 并给出中文说明。
  Future<bool> requestStart(String circleId) {
    if (_disposed) return Future<bool>.value(false);

    if (circleId.isEmpty) {
      _setNotice(
        RecordingConsentNoticeCode.circleIdEmpty,
        '圈子 ID 为空,无法开始录音',
      );
      _setState(RecordingConsentState.failed);
      return Future<bool>.value(false);
    }

    // 幂等:同一圈子已在录,直接认可,不重复走一遍 arming。
    if (_state == RecordingConsentState.recording &&
        _activeCircleId == circleId) {
      return Future<bool>.value(true);
    }

    // 已被别的圈子/别的流程占用。不排队、不抢占 —— 让调用方先 stop()。
    if (_state == RecordingConsentState.arming ||
        _state == RecordingConsentState.recording ||
        _state == RecordingConsentState.stopping) {
      _setNotice(
        RecordingConsentNoticeCode.alreadyInProgress,
        '已有录音流程进行中,请先停止当前录音',
      );
      _notify();
      return Future<bool>.value(false);
    }

    _activeCircleId = circleId;
    _clearNotice();
    final Completer<bool> completer = Completer<bool>();
    _arming = completer;

    _setState(RecordingConsentState.arming);
    _emit(<String, dynamic>{'t': kRecStart, 'circleId': circleId});

    _armingTimer?.cancel();
    _armingTimer = Timer(armingTimeout, _onArmingTimeout);

    return completer.future;
  }

  /// 停止录音(规则 6)。
  ///
  /// **同步、无条件、不可被网络阻断**:先本地撤销采集许可,再尝试发
  /// `rec_stop`。发送抛异常也照样撤销,异常不外泄。
  /// 停录这件事永远不许失败 —— 能不能停掉麦克风不该取决于网络好不好。
  ///
  /// 在 [RecordingConsentState.arming] 期间调用同样有效:取消等待、
  /// 补发 `rec_stop` 撤销可能已被服务器受理的 `rec_start`,
  /// 并让挂起的 [requestStart] Future 以 false 兑现(绝不留下永远不 resolve
  /// 的 Future)。
  void stop() {
    if (_disposed) return;
    if (_state == RecordingConsentState.idle ||
        _state == RecordingConsentState.failed) {
      // 本来就没在录。清掉残留文案即可,不发多余的包。
      if (_message != null) {
        _clearNotice();
        _notify();
      }
      return;
    }

    final String? circleId = _activeCircleId;

    // 顺序很重要:先断许可,再做其它任何事。
    _cancelTimers();
    _setState(RecordingConsentState.stopping);
    _completeArming(false);

    _emit(<String, dynamic>{
      't': kRecStop,
      'circleId': ?circleId,
    });

    // 本机不再是录音者;等服务器广播太慢,指示器要立刻灭。
    _recorders.remove(userId);
    _rebuildRoom();

    _activeCircleId = null;
    _clearNotice();
    _setState(RecordingConsentState.idle);
  }

  /// 喂入一条入站信令消息。
  ///
  /// **对畸形输入免疫**:字段缺失、类型不对、`members` 为 null 或不是数组,
  /// 一律安全忽略,绝不抛异常 —— 它跑在信令消息流的回调里,
  /// 抛出去会连带打死整条流。
  ///
  /// 处理:[kMemberRec]、[kRoomSnapshot]、[kMemberLeft]、[kDisconnected];
  /// 其余 `t` 静默跳过。
  void handleMessage(Map<String, dynamic> msg) {
    if (_disposed) return;
    final Object? rawType = msg['t'];
    if (rawType is! String) return;

    // 任何入站消息都算一次「对端还活着」的证据。
    _kickLivenessWatchdog();

    switch (rawType) {
      case kMemberRec:
        _onMemberRec(msg);
      case kRoomSnapshot:
        _onRoomSnapshot(msg);
      case kMemberLeft:
        _onMemberLeft(msg);
      case kDisconnected:
        _onDisconnected();
      default:
        break;
    }
  }

  // ── 入站分支 ──────────────────────────────────────────────────────────────

  void _onMemberRec(Map<String, dynamic> msg) {
    final String? uid = _asString(msg['userId']);
    if (uid == null || uid.isEmpty) return;

    final Object? rawActive = msg['active'];
    // strict-casts 下必须显式判型;顺带把 active 缺失/非 bool 当成 false,
    // 也就是「不确定就按没在录处理」—— 指示器宁可少亮,不可乱亮。
    final bool active = rawActive is bool && rawActive;
    final String circleId = _asString(msg['circleId']) ?? '';

    if (active) {
      _recorders[uid] = RemoteRecorder(
        userId: uid,
        name: _asString(msg['name']) ?? uid,
        since: _epochMsToDate(msg['since']),
      );
    } else {
      _recorders.remove(uid);
    }
    _rebuildRoom();

    if (uid != userId) {
      _notify();
      return;
    }

    // ── 以下是关于「我自己」的权威表态,状态机的核心 ──
    if (active) {
      // circleId 必须一并匹配:否则一条来自刚离开的旧圈子的滞留广播
      // 就能把我为新圈子的 arming 骗过去,变成「为 A 房间放行、
      // 实际只有 B 房间被告知」。这正是本模块要杜绝的那类事故。
      if (_activeCircleId != null && circleId.isNotEmpty &&
          circleId != _activeCircleId) {
        _notify();
        return;
      }
      _onConfirmed();
    } else {
      // 服务器说我没在录,而我的麦还热着 —— 房间的指示器已经灭了。
      // 这是**正面的**矛盾情报(不是「暂时不确定」),立刻无条件停采。
      if (_state == RecordingConsentState.recording ||
          _state == RecordingConsentState.arming) {
        _abort(
          RecordingConsentNoticeCode.serverMarkedInactive,
          '服务器已将本机标记为未在录音,已自动停止录音以免房间不知情',
        );
        return;
      }
      _notify();
    }
  }

  void _onRoomSnapshot(Map<String, dynamic> msg) {
    final Object? rawMembers = msg['members'];
    // null / 非数组一律当「这条快照没带成员信息」,保持现有全景不动,
    // 而不是把所有人清空 —— 清空会让指示器凭空熄灭。
    if (rawMembers is! List<Object?>) {
      _notify();
      return;
    }

    // 快照是全量权威:重建整张表,而不是增量合并。
    _recorders.clear();
    for (final Object? rawMember in rawMembers) {
      if (rawMember is! Map<String, dynamic>) continue;
      final String? uid = _asString(rawMember['userId']);
      if (uid == null || uid.isEmpty) continue;
      // `rec` 键存在即代表此人正在录音;缺失即没在录。
      final Object? rawRec = rawMember['rec'];
      if (rawRec is! Map<String, dynamic>) continue;
      _recorders[uid] = RemoteRecorder(
        userId: uid,
        name: _asString(rawMember['name']) ?? uid,
        since: _epochMsToDate(rawRec['since']),
      );
    }
    _rebuildRoom();

    final String circleId = _asString(msg['circleId']) ?? '';
    final bool sameCircle =
        _activeCircleId != null &&
        (circleId.isEmpty || circleId == _activeCircleId);

    if (sameCircle && !_recorders.containsKey(userId)) {
      // 快照里没有我,但我自以为在录。
      //
      // 这里**刻意**不像上面 active:false 那样立刻停,而是走宽限期:
      // 快照漏掉我在重连窗口里是**预期内且短暂的** —— 服务器完全可能
      // 先发快照、后处理我补发的 rec_start。立刻停会让每次重连
      // 都毁掉一段录音,这与规则 4「抖动不该毁录音」的取舍自相矛盾。
      //
      // 区别在于情报性质:active:false 是「服务器明确说我没录」(正面矛盾),
      // 快照漏我是「这一帧里没看见我」(信息缺失)。正面矛盾立刻停,
      // 信息缺失给宽限 —— 而两条路最终都会停,谁也不会让麦一直热着。
      if (_state == RecordingConsentState.recording) {
        _enterGrace(
          RecordingConsentNoticeCode.stateOutOfSync,
          '信令状态不同步,正在重新确认录音状态',
        );
        return;
      }
      if (_state == RecordingConsentState.arming) {
        _notify();
        return;
      }
    }
    _notify();
  }

  void _onMemberLeft(Map<String, dynamic> msg) {
    final String? uid = _asString(msg['userId']);
    if (uid == null || uid.isEmpty) return;

    // 消失的人绝不能被永远显示成「正在录音」。
    final bool removed = _recorders.remove(uid) != null;

    if (uid == userId &&
        (_state == RecordingConsentState.recording ||
            _state == RecordingConsentState.arming)) {
      // 服务器把我从花名册里划掉了 —— 别人的指示器上已经没有我这一条。
      // 同 active:false,属正面矛盾,立刻停。
      _rebuildRoom();
      _abort(
        RecordingConsentNoticeCode.removedFromRoom,
        '本机已被移出房间,已自动停止录音以免房间不知情',
      );
      return;
    }

    if (removed) _rebuildRoom();
    _notify();
  }

  void _onDisconnected() {
    if (_state == RecordingConsentState.arming) {
      // 还没开录就断了。不必急着判死 —— outbox 会在重连后补发 rec_start,
      // 回显仍可能在 armingTimeout 内赶到。让超时计时器自己决定生死。
      _notify();
      return;
    }
    if (_state != RecordingConsentState.recording) {
      _notify();
      return;
    }

    // 规则 5:立刻补发 rec_start。
    // 信令客户端断线时会把它压进 outbox,重连后自动按序补发 ——
    // 所以不需要一个「已重连」事件(协议里也确实没有)就能完成重新声明。
    // 万一注入的 send 没有 outbox 语义,补发丢失也不会出事:
    // 宽限期计时器照样会到点并强制停采。两条路都是安全侧。
    _reassert();
    _enterGrace(
      RecordingConsentNoticeCode.disconnected,
      '信令连接已断开,正在尝试恢复;若无法恢复将自动停止录音',
    );
  }

  /// 拿到(或重新拿到)权威确认。
  void _onConfirmed() {
    _armingTimer?.cancel();
    _armingTimer = null;

    final bool wasInGrace = _graceTimer != null;
    _graceTimer?.cancel();
    _graceTimer = null;

    if (_state == RecordingConsentState.arming) {
      _clearNotice();
      _setState(RecordingConsentState.recording);
      _startHeartbeat();
      _completeArming(true);
      return;
    }

    if (_state == RecordingConsentState.recording) {
      // 宽限期内恢复:状态从未离开 recording,采集自始至终没断过,
      // 清掉警告即可,不打断录音。
      if (wasInGrace) _clearNotice();
      _notify();
    }
  }

  // ── 超时与看门狗 ──────────────────────────────────────────────────────────

  void _onArmingTimeout() {
    _armingTimer = null;
    if (_state != RecordingConsentState.arming) return;

    final String? circleId = _activeCircleId;
    // 幽灵录音者撤销:见 requestStart 文档。即便服务器压根没收到
    // rec_start,这条 rec_stop 也只是一次无害的空操作。
    _emit(<String, dynamic>{
      't': kRecStop,
      'circleId': ?circleId,
    });

    _cancelTimers();
    _recorders.remove(userId);
    _rebuildRoom();
    _activeCircleId = null;
    _setNotice(
      RecordingConsentNoticeCode.armingTimeout,
      '未能确认房间已被告知录音开始,已取消录音'
          '(等待服务器回执超过 ${armingTimeout.inSeconds} 秒)',
      seconds: armingTimeout.inSeconds,
    );
    _setState(RecordingConsentState.failed);
    _completeArming(false);
  }

  /// 进入宽限期。**已在宽限期内则不重置计时器** —— 否则反复的断线事件
  /// 能把宽限期无限续期,变成「一直没确认却一直在采集」。
  void _enterGrace(
    RecordingConsentNoticeCode code,
    String warning, {
    int? seconds,
  }) {
    _setNotice(code, warning, seconds: seconds);
    if (_graceTimer != null) {
      _notify();
      return;
    }
    _graceTimer = Timer(gracePeriod, _onGraceExpired);
    _notify();
  }

  void _onGraceExpired() {
    _graceTimer = null;
    if (_state != RecordingConsentState.recording) return;
    _abort(
      RecordingConsentNoticeCode.graceExpired,
      '信令中断超过 ${gracePeriod.inSeconds} 秒仍未恢复,'
          '无法确认房间知情,已自动停止录音',
      seconds: gracePeriod.inSeconds,
    );
  }

  /// 无条件中止:撤销采集许可 + 落下中文警告。
  void _abort(
    RecordingConsentNoticeCode code,
    String warning, {
    int? seconds,
  }) {
    final String? circleId = _activeCircleId;
    _cancelTimers();
    _setState(RecordingConsentState.stopping);
    _completeArming(false);

    // 礼貌性地告知服务器我停了。成败无所谓:本机早已停采。
    _emit(<String, dynamic>{
      't': kRecStop,
      'circleId': ?circleId,
    });

    _recorders.remove(userId);
    _rebuildRoom();
    _activeCircleId = null;
    _setNotice(code, warning, seconds: seconds);
    _setState(RecordingConsentState.failed);
  }

  void _reassert() {
    final String? circleId = _activeCircleId;
    if (circleId == null) return;
    _emit(<String, dynamic>{'t': kRecStart, 'circleId': circleId});
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 规则 3:周期性宣告存活,好让服务器在本机崩溃时过期掉残留的录音状态
    // (崩溃的进程发不出 rec_stop,只能靠服务器侧超时兜底)。
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (Timer _) {
      final String? circleId = _activeCircleId;
      if (circleId == null) return;
      _emit(<String, dynamic>{'t': kRecPing, 'circleId': circleId});
    });
  }

  /// 重置「入站静默」看门狗。[livenessTimeout] 为 null 时整体是空操作。
  void _kickLivenessWatchdog() {
    final Duration? timeout = livenessTimeout;
    if (timeout == null) return;
    _livenessTimer?.cancel();
    if (_state != RecordingConsentState.recording) return;
    _livenessTimer = Timer(timeout, () {
      _livenessTimer = null;
      if (_state != RecordingConsentState.recording) return;
      // 半开连接:没有 _disconnected 事件,但久无入站音讯。
      // 按「失去确认」处理,重新声明并起宽限期。
      _reassert();
      _enterGrace(
        RecordingConsentNoticeCode.signalingSilent,
        '长时间未收到信令消息,正在重新确认录音状态',
      );
    });
  }

  // ── 内部工具 ──────────────────────────────────────────────────────────────

  /// 发送出站消息。**吞掉一切异常**:网络层的故障绝不能反过来
  /// 打断状态机,尤其不能让 stop() 停不下来。
  void _emit(Map<String, dynamic> msg) {
    try {
      _send(msg);
    } catch (_) {
      // 有意静默:发送失败不改变本机的采集许可。
      // 起录靠的是回显(收不到自然会超时失败),停录本来就不依赖发送成功。
    }
  }

  /// 落下一条提示。**这是 [_message] / [_notice] 唯一的写入口** ——
  /// 两者必须同生共灭,分开赋值迟早会漂移成「中文说 A、英文说 B」。
  ///
  /// [zh] 是遗留的中文原文(见 [message] 上的说明),[code] 是语义标识,
  /// [seconds] 只给需要把秒数嵌进句子的那两条。
  void _setNotice(
    RecordingConsentNoticeCode code,
    String zh, {
    int? seconds,
  }) {
    _message = zh;
    _notice = RecordingConsentNotice(code, seconds: seconds);
  }

  /// 清空提示。同样必须两者一起清。
  void _clearNotice() {
    _message = null;
    _notice = null;
  }

  void _setState(RecordingConsentState next) {
    _state = next;
    _announceCapture();
    _notify();
  }

  /// 仅在采集许可真的翻转时通知录音服务。
  void _announceCapture() {
    final bool allowed = captureAllowed;
    if (allowed == _lastAnnouncedAllowed) return;
    _lastAnnouncedAllowed = allowed;
    final CapturePermissionChanged? cb = onCaptureAllowedChanged;
    if (cb == null) return;
    try {
      cb(allowed);
    } catch (_) {
      // 订阅方自己的异常不该污染状态机。
    }
  }

  void _completeArming(bool result) {
    final Completer<bool>? completer = _arming;
    _arming = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  void _cancelTimers() {
    _armingTimer?.cancel();
    _armingTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _livenessTimer?.cancel();
    _livenessTimer = null;
  }

  void _rebuildRoom() {
    final List<RemoteRecorder> sorted = _recorders.values.toList()
      ..sort((RemoteRecorder a, RemoteRecorder b) {
        final int byTime = a.since.compareTo(b.since);
        return byTime != 0 ? byTime : a.userId.compareTo(b.userId);
      });
    _room = RoomRecordingState(
      recorders: List<RemoteRecorder>.unmodifiable(sorted),
      localUserId: userId,
    );
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 把 epoch 毫秒转成 [DateTime]。
  ///
  /// 容错:非 int 一律退化为当前时刻。JSON 里整数有时会被解析成 double
  /// (如 `1.7e12`),所以 num 也接。
  DateTime _epochMsToDate(Object? raw) {
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is double && raw.isFinite) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    }
    return _now();
  }

  /// strict-casts 下的安全取字符串:不是 String 就返回 null,不做隐式转换。
  static String? _asString(Object? raw) => raw is String ? raw : null;

  @override
  void dispose() {
    // 顺序要紧:先把采集许可撤掉并通知录音服务,再拆定时器。
    // 否则控制器没了、录音服务还以为许可有效,麦克风就永远热着 ——
    // 这是本模块最不能容忍的结局。
    _state = RecordingConsentState.idle;
    _announceCapture();
    _cancelTimers();
    _completeArming(false);
    _recorders.clear();
    _room = RoomRecordingState.empty;
    _disposed = true;
    super.dispose();
  }
}
