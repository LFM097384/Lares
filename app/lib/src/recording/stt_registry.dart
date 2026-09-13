/// STT 的**选择层**:挑后端、优雅降级,以及两个后端共用的错误类型。
///
/// 本文件刻意**不 import `sherpa_onnx`、不 import `http`** —— 它只依赖
/// `stt_backend.dart` 里的抽象。这不是洁癖:注册表承载的是"选哪个"这条
/// 业务规则,而这条规则是本模块里最值得反复测的部分。只要它不碰 FFI 和
/// 网络,就能在纯 VM 里用假后端把每条降级分支跑一遍。
///
/// 具体后端由**调用方**构造好再传进来(见 [SttRegistry.new]),
/// 注册表自己不知道 sherpa 或 Groq 的存在。
library;

import 'package:flutter/foundation.dart';

import 'stt_backend.dart';

/// 后端不可用时从 [SttBackend.transcribe] 抛出的异常。
///
/// **为什么放在这个文件**:两个后端实现(本地 / 云端)都要抛它,而它们
/// 彼此不能互相 import —— 那会把 `sherpa_onnx` 拖进云端后端、或者把 `http`
/// 拖进本地后端,两边的可测性一起完蛋。放在这个零依赖的选择层里是唯一
/// 不产生循环、也不污染依赖的位置。
///
/// 携带完整的 [SttAvailability] 而不是一句光秃秃的字符串:调用点拿到它
/// 既能直接展示中文原因,又能读 [SttAvailability.reason] 做分支
/// (比如「模型缺失」引导去下载页,「用户关闭」则干脆什么都不提示)。
class SttUnavailableException implements Exception {
  const SttUnavailableException(this.availability, {this.cause});

  final SttAvailability availability;

  /// 底层原因(如 FFI / HTTP 抛出的原始异常),**仅用于排查日志**,
  /// 不要直接展示给用户 —— 它可能含有英文栈信息之类的噪声。
  final Object? cause;

  /// 给用户看的中文说明,等同于 `availability.message`。
  String get message => availability.message;

  @override
  String toString() => 'SttUnavailableException(${availability.message})';
}

/// 设置页下拉框用的后端选项。
///
/// 加 [off] 这一项是有意义的:用户可能装了模型但就是不想要转写
/// (比如今晚聊的事不想留字),这跟"没装模型"是两回事,后者是能力缺失,
/// 前者是明确意愿。混成一个状态会导致 UI 在用户主动关闭时还去弹
/// "去下载模型吧"的引导,很烦人。
enum SttBackendChoice {
  /// 本地离线识别。**默认项**:0 元、断网可用、音频不出本机。
  local,

  /// 云端识别。质量更好但要花钱、要联网、音频要上传给第三方。
  cloud,

  /// 关闭转写。照常通话、照常录音,只是不出字。
  off,
}

/// 下拉框显示用的中文标签。
extension SttBackendChoiceLabel on SttBackendChoice {
  String get label => switch (this) {
    SttBackendChoice.local => '本地离线识别',
    SttBackendChoice.cloud => '云端识别',
    SttBackendChoice.off => '关闭转写',
  };

  /// 标签下方的中文副标题,把代价说清楚,别让用户在不知情的情况下选到花钱的那项。
  String get description => switch (this) {
    SttBackendChoice.local => '免费、断网可用,语音不离开本机;需先下载离线模型',
    SttBackendChoice.cloud => '识别质量更好,但需要联网、按用量计费,且语音会上传到云端',
    SttBackendChoice.off => '只通话与录音,不生成转写稿',
  };
}

/// 一次后端选择的结果。
///
/// 做成值对象而不是直接返回 `SttBackend?`,是因为"最后用了谁"和
/// "为什么不是用户选的那个"必须一起传给 UI。只返回一个可空后端的话,
/// 用户在设置里选了本地、实际却走了云端(因为模型没装),而界面上
/// 一个字都不提 —— 这属于背着用户花钱,不可接受。
@immutable
class SttSelection {
  const SttSelection({
    required this.requested,
    required this.effective,
    required this.backend,
    required this.availability,
  });

  /// 用户在设置里选的。
  final SttBackendChoice requested;

  /// 实际生效的。与 [requested] 不同即表示发生了降级。
  final SttBackendChoice effective;

  /// 实际可用的后端实例。[effective] 为 [SttBackendChoice.off] 时为 null。
  final SttBackend? backend;

  /// 生效后端的可用性(或者:全都不可用时,说明为什么)。
  final SttAvailability availability;

  /// 是否真的可以转写。
  bool get ready => backend != null && availability.ready;

  /// 是否发生了降级(用户要 A、实际给了 B)。UI 应当据此显示一句提示。
  bool get didFallBack => requested != effective;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SttSelection &&
          other.requested == requested &&
          other.effective == effective &&
          identical(other.backend, backend) &&
          other.availability == availability;

  @override
  int get hashCode =>
      Object.hash(requested, effective, identityHashCode(backend), availability);

  @override
  String toString() =>
      'SttSelection(requested: $requested, effective: $effective, '
      'ready: $ready, availability: $availability)';
}

/// 后端注册表 + 降级策略。
///
/// ## 录音与转写是两件独立的事
/// 这是本文件最重要的一条设计约束,值得写在最显眼的地方:
/// **转写不可用绝不能影响录音**。音频落盘、通话、语音便签全都不依赖 STT;
/// 模型没下载、API key 没填、网断了 —— 这些统统只意味着"这段时间没有字",
/// 音频本身一个字节都不会少。所以本类的任何路径都**不抛异常**,
/// 最坏情况也只是返回一个 `ready == false` 的 [SttSelection],
/// 让上层原样继续录音。谁要是在这里 throw,整条录音链路就会被一个
/// "模型没装"给拖垮,那是荒谬的。
class SttRegistry {
  /// [local] / [cloud] 均可为 null(表示该后端在本次构建里根本没装配)。
  /// 注册表不构造它们,只挑选 —— 这样它就永远不需要认识具体实现。
  const SttRegistry({this.local, this.cloud});

  final SttBackend? local;
  final SttBackend? cloud;

  /// 降级顺序:本地优先。
  ///
  /// 顺序不是随手排的。本地是 0 元且隐私最好的,所以永远排第一;
  /// 云端排第二是因为它**要花钱**,只能在本地实在不行时兜底,
  /// 而且是"用户已经填了 key"才说明他接受这笔开销 —— 没填 key 时
  /// 云端后端自己会报不可用,这个降级链就自然停在"不可用"上,
  /// 不会出现偷偷扣钱的情况。
  static const List<SttBackendChoice> kFallbackOrder = <SttBackendChoice>[
    SttBackendChoice.local,
    SttBackendChoice.cloud,
  ];

  /// 按用户选择挑一个可用后端,不可用则按 [kFallbackOrder] 顺次降级。
  ///
  /// [requested] 默认 [SttBackendChoice.local] —— 这是项目决策:
  /// 默认本地、免费、离线、隐私优先。
  ///
  /// **本方法不抛异常**,任何失败都表达为 `ready == false` 的返回值。
  Future<SttSelection> select({
    SttBackendChoice requested = SttBackendChoice.local,
  }) async {
    if (requested == SttBackendChoice.off) {
      return const SttSelection(
        requested: SttBackendChoice.off,
        effective: SttBackendChoice.off,
        backend: null,
        availability: SttAvailability.disabledByUser(),
      );
    }

    // 先试用户选的那个,再按固定顺序试其余的。用 LinkedHashSet 的去重语义:
    // requested 本身也在 kFallbackOrder 里,不去重会把它查两遍
    // (每次查询都要摸一次文件系统,白白多一次 IO)。
    final List<SttBackendChoice> order = <SttBackendChoice>{
      requested,
      ...kFallbackOrder,
    }.toList(growable: false);

    // 记住**用户首选**的失败原因。降级到最后全军覆没时,要展示的是
    // "你选的那个为什么不行",而不是链条末端某个用户压根没选的后端的原因 ——
    // 用户选了本地却看到「请填写 API Key」,只会一头雾水。
    SttAvailability? firstFailure;

    for (final SttBackendChoice choice in order) {
      final SttBackend? backend = backendFor(choice);
      if (backend == null) {
        firstFailure ??= SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unsupportedPlatform,
          message: '${choice.label}在当前版本中不可用',
          remedy: '请在「设置 - 语音识别」中改选其他识别方式',
        );
        continue;
      }

      // 后端的 checkAvailability 按契约不该抛,但它要摸文件系统甚至试网络,
      // 这里仍然兜一层:一个后端的意外崩溃不该让整个降级链断掉。
      SttAvailability availability;
      try {
        availability = await backend.checkAvailability();
      } catch (e) {
        availability = SttAvailability(
          ready: false,
          reason: SttUnavailableReason.unknown,
          message: '${choice.label}状态检查失败:$e',
          remedy: '请在「设置 - 语音识别」中改选其他识别方式',
        );
      }

      if (availability.ready) {
        return SttSelection(
          requested: requested,
          effective: choice,
          backend: backend,
          availability: availability,
        );
      }
      firstFailure ??= availability;
    }

    return SttSelection(
      requested: requested,
      effective: SttBackendChoice.off,
      backend: null,
      availability: firstFailure ?? kNoSttBackendAvailable,
    );
  }

  /// 取某个选项对应的后端实例(没装配则 null)。
  SttBackend? backendFor(SttBackendChoice choice) => switch (choice) {
    SttBackendChoice.local => local,
    SttBackendChoice.cloud => cloud,
    SttBackendChoice.off => null,
  };
}

/// 一个后端都没装配时的兜底说明。
///
/// 提成顶层 `const` 而不是在 [SttRegistry.select] 里内联构造:它是完全固定
/// 的文案,没必要每次失败都新建对象;而且 UI 可以直接 `identical` 比对
/// "是不是彻底没后端"这种极端状态。
const SttAvailability kNoSttBackendAvailable = SttAvailability(
  ready: false,
  reason: SttUnavailableReason.unknown,
  message: 'STT 不可用:没有任何可用的语音识别后端(通话与录音不受影响)',
  remedy: '请到「设置 - 语音识别」下载离线模型,或填写云端识别的 API Key',
);
