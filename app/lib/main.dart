import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'l10n/gen/app_localizations.dart';
import 'src/chat/chat_service.dart';
import 'src/recording/recording_consent.dart';
import 'src/chat/session_chat_transport.dart';
import 'src/config.dart';
import 'src/e2ee/e2ee_controller.dart';
import 'src/e2ee/e2ee_store.dart';
import 'src/moderation/block_audio_enforcer.dart';
import 'src/moderation/block_store.dart';
import 'src/moderation/consent_store.dart';
import 'src/net/presence_pool.dart';
import 'src/net/signaling_client.dart';
import 'src/p2p/ice_store.dart';
import 'src/p2p/p2p_mesh.dart';
import 'src/platform/foreground_service.dart';
import 'src/platform/widget_service.dart';
import 'src/platform/tray_service_stub.dart'
    if (dart.library.io) 'src/platform/tray_service.dart';
import 'src/platform/window_setup.dart'
    if (dart.library.io) 'src/platform/window_setup_io.dart';
import 'src/rtc/livekit_rtc_service.dart';
import 'src/state/circle_store.dart';
import 'src/state/dev_mode_store.dart';
import 'src/state/identity.dart';
import 'src/state/location_share_stub.dart'
    if (dart.library.io) 'src/state/location_share.dart';
import 'src/state/models.dart';
import 'src/state/room_controller.dart';
import 'src/state/settings_store.dart';
import 'src/state/voice_notes.dart';
import 'src/theme/theme.dart';
import 'src/ui/content_policy_screen.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端窗口配置(Web/移动为空操作)
  await setupDesktopWindow();

  final identity = await Identity.load();
  // 主圈子未显式指定时,优先用打包期配置的圈(常驻挂机机器靠它钉住一键入口)
  final circleStore = await CircleStore.load(
    preferredPrimaryId: LaresConfig.defaultCircleId,
  );
  final settings = await SettingsStore.load();
  // 按圈 E2EE 的开关登记表(默认全关)。只存开关,不存任何密钥材料。
  final e2eeStore = await E2EEStore.load();
  // 内容治理(App Store 审核指南 1.2):屏蔽名单与内容规范同意状态。
  // 放在这里加载是因为下面的自动进圈/托盘入口要先问一句「同意了没有」。
  final blocks = await BlockStore.load();
  final consent = await ConsentStore.load();
  // 开发者模式:连点设置页底部版本号 7 次解锁,技术项收在它后面。
  final devMode = await DevModeStore.load();
  // 点对点直连的 ICE 配置(STUN/TURN)。默认全空 ——
  // 刻意不内置任何公共服务器,内置一个就等于给「不依赖任何人」开了后门。
  final ice = await IceStore.load();

  // 所有「一键进圈」入口(托盘/自动挂机/主屏 Widget)的统一目标:主圈子。
  // 圈子列表为空时回落到打包期默认圈。
  String primaryCircleId() =>
      circleStore.primaryCircleId ?? LaresConfig.defaultCircleId;

  // 信令地址:当前服务器档案优先,其次老的单条覆盖,最后才是打包内置
  // (真机联调局域网 IP 常变,免重打包)
  final signalingUrl =
      settings.effectiveSignalingUrl ?? LaresConfig.signalingUrl;
  // 正在向服务器证明哪个圈子。**凭据必须跟着它走,不能跟着主圈走。**
  //
  // ⚠️ 2026-09-19 真机实测撞到的 bug:这里原本写的是
  //   credentials: () => settings.credentialFor(primaryCircleId())
  // 于是无论 authCircleId 指向哪个圈,拿去算证明的**永远是主圈的口令**。
  //
  // 症状极具迷惑性:用户从邀请链接加了 review 圈、填对了 review 的口令,
  // 客户端却拿 home 的口令去证明 review —— 服务端 4401,界面再次要口令,
  // 用户以为自己输错了,反复重输仍然进不去,而口令其实一直是对的。
  //
  // `_credentialNow()` 里那个「circleId 为 null 才补 authCircleId」的兜底
  // 救不了这条:credentialFor() 返回的 circleId 是非空的主圈 id。
  //
  // ⚠️ 不要写成 `late final SignalingClient signaling` + 回调里自引用。
  // 试过,**会白屏**:级联 `..authCircleId = ...` 在 signaling 赋值
  // **完成之前**执行,setter 内部调 _credentialNow() → 回调读 signaling
  // → LateInitializationError → 启动即崩。
  // 而 `flutter test` 抓不到 —— 没有测试覆盖 main() 的初始化顺序。
  //
  // 改用可空引用:回调触发时它必然已经赋好值(第一次触发最早也在
  // 下面那行 setter 里,那时构造已经返回),而空值有明确的回落。
  SignalingClient? signalingRef;

  // 凭据现取现用:每条 challenge 到达时回调一次,用户改完口令下次重连自然生效。
  // 圈子取自 signaling.authCircleId —— 那是「当前要证明哪个圈」的唯一事实源,
  // 由 RoomController.join / retryJoin 与下面「换主圈」共同维护。
  final signaling = SignalingClient(
    url: signalingUrl,
    userId: identity.userId,
    credentials: () => settings
        .credentialFor(signalingRef?.authCircleId ?? primaryCircleId()),
  );
  signalingRef = signaling;
  // 分开写,不用级联:级联会在变量赋值前触发 setter(见上面的白屏教训)。
  signaling.authCircleId = primaryCircleId();
  // 单独持有引用:聊天传输层要从它拿底层 Room(见 rtc.room 的注释)
  final rtc = LiveKitRtcService(hostOnlyIce: LaresConfig.hostOnlyIce);
  final controller = RoomController(
    signaling: signaling,
    rtc: rtc,
    userId: identity.userId,
    deviceId: identity.deviceId,
    userName: identity.name,
    settings: settings,
    isOnWifi: () async {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    },
  );

  // 按圈端到端加密:开关 + 圈口令 -> 派生密钥 -> 进房前装进 RoomOptions。
  // 密钥从不落盘、从不上传服务器 —— 这正是整个功能的意义。
  final e2ee = E2EEController(
    store: e2eeStore,
    settings: settings,
    rtc: rtc,
  );
  // 每一条走到 rtc.join() 的路径都会先过这个钩子(含闲时降级后的媒体唤醒)
  controller.prepareEncryption = e2ee.prepareFor;

  // 多人点对点(星形):选一个人当主机转发,其他人只上行 1 路。
  //
  // ⚠️ 它**不自动启动** —— 只有用户显式进入直连模式时才同步名单。
  // 主链路(LiveKit)和这条路同时活着会把音频发两遍,
  // 所以谁激活谁负责,默认谁都不激活。
  final mesh = P2PMesh(
    myUserId: identity.userId,
    ice: () => ice.config,
  );
  // 连接码经服务器转交给同圈的人(服务器只当邮差,不解析不存储)
  mesh.onOutgoing = signaling.sendP2PSignal;
  // 收到别人的连接码
  signaling.messages.listen((msg) {
    if (msg['t'] != 'p2p_signal') return;
    final from = msg['from'] as String?;
    final payload = msg['payload'] as String?;
    if (from == null || payload == null) return;
    unawaited(mesh.handleIncoming(
      from,
      msg['fromName'] as String? ?? '',
      payload,
    ));
  });
  // 成员变动时重算主机并同步连接。
  // 只在 mesh 已经有连接(= 用户在用直连)时才动,
  // 否则会在普通 LiveKit 通话里凭空建起 P2P 连接。
  controller.addListener(() {
    if (mesh.peers.isEmpty && mesh.hostId == null) return;
    unawaited(mesh.syncRoster(controller.hostCandidates));
  });

  /// 启动多人直连。
  ///
  /// 多人必须有服务器信令:星形下 3 人也要建 2 条连接、交换 4 段码,
  /// 手动传不现实。而「在房间里」正好等价于「信令连着且知道有谁」——
  /// 所以不在房间里就不给这个入口。
  void startMesh() {
    if (controller.phase != RoomPhase.inRoom) return;
    unawaited(mesh.syncRoster(controller.hostCandidates));
  }

  // 跨服务器「我有空」:主连接之外,对其余每台服务器各开一条只做 presence
  // 的轻连接。服务器之间不通信 —— 聚合发生在这里。
  final presence = PresencePool(
    userId: identity.userId,
    credentialFor: settings.credentialForServer,
  );
  void syncPresenceLinks() {
    presence.syncProfiles(
      settings.serverProfiles.profiles,
      // 主连接已经在用的那台不重复连:它的可约者由主连接自己的消息流提供
      exclude: settings.serverProfiles.activeId,
    );
  }

  syncPresenceLinks();
  // 用户增删服务器档案后要跟着变
  settings.addListener(syncPresenceLinks);
  // 让圈子列表把「别的服务器上谁有空」一并显示出来。
  // UI 只问 controller.availableIn(),不必知道数据来自几条连接。
  controller.remoteAvailableIn = (circleId) => [
        for (final r in presence.availableIn(circleId))
          (userId: r.userId, name: r.name),
      ];
  // 池子有变化时刷新圈子列表(它不在 controller 的通知链上)
  presence.addListener(controller.refresh);
  // 有人在别的服务器上来找我 —— 把主连接切过去。
  // 池子只报告事实,进房始终是主连接的事,不让两条路径都能进房。
  presence.addListener(() {
    final r = presence.reached;
    if (r == null) return;
    presence.consumeReached();
    // 查出那台服务器的地址。查不到就不动 —— 宁可什么都不做,
    // 也不能把主连接切到一个不存在的地址,那会连当前的圈子都回不去。
    String? url;
    for (final p in settings.serverProfiles.profiles) {
      if (p.id == r.serverId) url = p.url;
    }
    if (url == null || url.isEmpty) return;
    unawaited(controller.switchServerAndJoin(
      circleId: r.circleId,
      url: url,
    ));
  });

  // P0 预连接:App 启动即建立信令长连接并上报身份
  controller.preconnect();
  signaling.hello(
    userId: identity.userId,
    deviceId: identity.deviceId,
    name: identity.name,
    platform: LaresConfig.platformName,
  );
  // 把心跳测到的延迟报给同房的人,供多人直连时选主机。
  // 复用既有的 20 秒心跳,零额外网络开销;controller 内部会节流,
  // 变化小于 50ms 就不报(选举本身有 300ms 的切换阈值)。
  Timer.periodic(const Duration(seconds: 20), (_) {
    controller.reportLatency(signaling.latencyMs);
  });

  // P0 预热:提前为主圈子备 RTC token,进房时信令与媒体并行
  controller.prefetchToken(primaryCircleId());
  // 主圈子被改掉:为新的主圈子重新预热,保住一键进圈的 ≤1.5s 目标
  var lastPrimary = primaryCircleId();
  circleStore.addListener(() {
    final now = primaryCircleId();
    if (now == lastPrimary) return;
    lastPrimary = now;
    // circle 模式下换主圈 = 换密钥,要带新圈口令重新握手(其它模式无影响)
    signaling.authCircleId = now;
    controller.prefetchToken(now);
  });

  // 改了服务器/口令:带新凭据干净重连,不必重启 App 才生效
  var lastCred = settings.credentialFor(primaryCircleId());
  settings.addListener(() {
    final now = settings.credentialFor(primaryCircleId());
    if (now == lastCred) return;
    lastCred = now;
    signaling.reconnectWithNewCredential();
  });

  // 常驻挂机模式:启动即自动进主圈(信令连接建立后)
  if (LaresConfig.autoJoin) {
    Timer(const Duration(milliseconds: 1500), () {
      // 同意内容规范之前不许进圈。这条路径绕过了 UI —— 只做一个视觉上的
      // 拦截门是拦不住它的,而「没同意就已经能听到别人说话」正是
      // App Store 审核指南 1.2 明确禁止的情形,所以在这里硬挡一次。
      if (!consent.accepted) return;
      if (controller.phase == RoomPhase.idle) {
        controller.join(primaryCircleId());
      }
    });
  }

  // 桌面托盘:常驻入口,点图标即一键进主圈(Web 为空操作)
  final tray = TrayService(
    onEnterRoom: () {
      // 同上:托盘点一下也能在 HomeScreen 从未渲染的情况下进圈,
      // 同意内容规范之前一律不放行(退出房间不受限制 —— 随时能走)。
      if (controller.phase == RoomPhase.idle) {
        if (!consent.accepted) {
          unawaited(showAndFocusWindow()); // 把窗口叫到前面,让人看到那道同意门
          return;
        }
        controller.join(primaryCircleId());
      } else {
        controller.leave();
      }
    },
    onShowWindow: showAndFocusWindow,
  );
  await tray.init();

  // 主屏幕 Widget + 深链(主圈 presence 推送、一键进主圈、邀请链接;Android/iOS)
  //
  // 第三条绕过路径:深链(主屏小组件、邀请链接、快捷方式)同样能在 HomeScreen
  // 从未渲染的情况下直接进圈。`init()` 里会**消费掉冷启动深链**,所以不能先 init
  // 再补拦截 —— 那时人已经在房间里了。同意内容规范之前整个推迟初始化:
  // 深链留在原生侧不被消费,同意之后再 init 时照样能拿到,一条都不丢。
  // (未同意就能进圈,正是审核指南 1.2 明确禁止的情形。)
  final widgetService = WidgetService();
  if (consent.accepted) {
    await widgetService.init(controller, circleStore: circleStore);
  } else {
    var widgetsInited = false;
    consent.addListener(() {
      if (widgetsInited || !consent.accepted) return;
      widgetsInited = true;
      unawaited(widgetService.init(controller, circleStore: circleStore));
    });
  }

  // 房间状态同步到托盘菜单
  var lastPhase = controller.phase;
  controller.addListener(() {
    final inRoom = controller.phase != RoomPhase.idle;
    final wasInRoom = lastPhase != RoomPhase.idle;
    if (inRoom != wasInRoom) tray.setInRoom(inRoom);
    lastPhase = controller.phase;
  });

  // Android 前台服务:进房且媒体在线时保活,出房/闲时降级释放(§8.3-P1)
  final foreground = ForegroundRoomService()..init();
  controller.addListener(() {
    final mediaOnline =
        controller.phase == RoomPhase.inRoom && !controller.mediaDowngraded;
    if (mediaOnline) {
      foreground.start();
    } else {
      foreground.stop();
    }
  });

  // 语音便签(§2.2):没人时留一条 15s 语音
  final voiceNotes = VoiceNotesController(
    httpBase: httpBaseFromWs(signalingUrl),
    room: controller,
  );

  // 位置共享(Snapchat 式,产品反馈):显式开启,出房即停
  final locationShare = LocationShareService(room: controller);

  // 文字/图片副通道(§2.3 原本不做,本轮由 owner 显式放开):语音仍是一等公民。
  // 传输层跟随房间生命周期自动重建 —— Room 只在 join/leave 之间存活。
  final chat = ChatService(
    transport: SessionChatTransport(rtc: rtc, controller: controller),
    userId: identity.userId,
    userName: identity.name,
    circleIdGetter: () => controller.circleId ?? primaryCircleId(),
    // 屏蔽名单的**文字侧**执行:被屏蔽的人发的消息不进这条流(指南 1.2)
    isBlocked: blocks.isBlocked,
  );

  // 屏蔽名单的**声音侧**执行:把名单同步到 LiveKit 的远端音轨上。
  // 光过滤文字不够 —— 屏蔽之后还能听见对方说话,这一条就过不了审核。
  // 持有引用是为了它别被回收,也为了将来需要时能 dispose。
  //
  // 它在整个 App 生命周期里都活着,没有对应的 dispose 时机(main 里的其它
  // 长生命周期对象同理),故只留一个具名引用便于将来接手。
  // ignore: unused_local_variable
  final blockAudioEnforcer = BlockAudioEnforcer(
    rtc: rtc,
    controller: controller,
    blocks: blocks,
  );

  // 录音同意(需求⑧):录音态的唯一权威。默认关闭,开启需显式确认。
  // livenessTimeout 敢开是因为服务端已对 rec_ping 回 rec_pong(提交 20b8ddf)——
  // 在那之前只有单向心跳,TCP 半开时会误杀正常长录音,故当时默认关闭。
  // 取心跳间隔(15s)的 3 倍,容忍两次丢包。
  //
  // ⚠️ 这里必须跟着 recordingEnabled 走,不能无条件构造。
  // 实测(二进制符号扫描)证据:recording/ 下 12 个文件里 11 个都被 tree-shaking
  // 剔除干净了,唯独 recording_consent.dart 整个留在默认产物里 —— 根因就是
  // 这一行无条件实例化,它让整个文件变成「可达的活代码」。
  // 残留会在包里留下 RecordingConsentController、rec_stop、member_rec
  // 以及 5 条写着「录音」的中文文案,对 2.3.1(hidden/dormant features)
  // 是不利叙事。字段两端本来就是可空的,所以这里给 null 是安全的。
  final recordingConsent = LaresConfig.recordingEnabled
      ? RecordingConsentController(
          userId: identity.userId,
          send: signaling.send,
          livenessTimeout: const Duration(seconds: 45),
        )
      : null;
  controller.recordingConsent = recordingConsent;

  // 回到前台立刻探活。
  //
  // 心跳周期是 20 秒,而后台期间它会被系统挂起(iOS 尤其激进)。
  // socket 很可能已被静默回收 —— **不报 close,只是再也不通**。
  // 不主动戳一下的话,用户会对着一个「显示在房里、实际已断」的界面
  // 操作最长 40 秒才发现。
  //
  // pokeAlive 只发一个 ping(连接还在时),不粗暴重连 ——
  // 大多数情况是短暂切出去又回来,重连要重算 Argon2 证明,既慢又浪费。
  //
  // 这个监听器与 App 同生命周期,不需要 dispose。
  AppLifecycleListener(
    onResume: signaling.pokeAlive,
  );

  runApp(LaresApp(
    controller: controller,
    voiceNotes: voiceNotes,
    circleStore: circleStore,
    settings: settings,
    locationShare: locationShare,
    chat: chat,
    recordingConsent: recordingConsent,
    blocks: blocks,
    consent: consent,
    e2ee: e2ee,
    devMode: devMode,
    ice: ice,
    onStartMesh: startMesh,
  ));
}

class LaresApp extends StatelessWidget {
  const LaresApp({
    super.key,
    required this.controller,
    required this.circleStore,
    required this.settings,
    this.voiceNotes,
    this.locationShare,
    this.chat,
    this.recordingConsent,
    this.blocks,
    this.consent,
    this.e2ee,
    this.devMode,
    this.ice,
    this.onStartMesh,
  });

  final RoomController controller;
  final CircleStore circleStore;
  final SettingsStore settings;
  final VoiceNotesController? voiceNotes;
  final LocationShareService? locationShare;
  final ChatService? chat;
  final RecordingConsentController? recordingConsent;

  /// 本机屏蔽名单(指南 1.2)
  final BlockStore? blocks;

  /// 内容规范同意状态;非空时 [ContentPolicyGate] 会拦在主界面之前
  final ConsentStore? consent;

  /// 按圈端到端加密。为 null 时圈子菜单里不出现加密开关,房间页不显示锁标 ——
  /// 与其它可选协作者一样优雅降级(而不是显示一个假的「未加密」)。
  final E2EEController? e2ee;

  /// 开发者模式(连点版本号 7 次解锁)。为 null 时设置页里完全没有开发者区,
  /// 底部版本号也只是一行普通文字 —— 给测试留一个「天然干净」的默认。
  final DevModeStore? devMode;
  final IceStore? ice;
  final VoidCallback? onStartMesh;

  @override
  Widget build(BuildContext context) {
    final home = HomeScreen(
      controller: controller,
      circleStore: circleStore,
      settings: settings,
      voiceNotes: voiceNotes,
      locationShare: locationShare,
      chat: chat,
      recordingConsent: recordingConsent,
      blocks: blocks,
      consent: consent,
      e2ee: e2ee,
      devMode: devMode,
      ice: ice,
      onStartMesh: onStartMesh,
    );
    final consentStore = consent;
    return MaterialApp(
      // onGenerateTitle 而非 title:后者取不到本地化上下文。
      // 这个标题会出现在 Android 的任务切换器里。
      onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appTitle,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // 跟随系统语言;系统语言不在 supportedLocales 里时回落到英文
      // (而不是中文 —— App Store 主语言是 English)。
      localeResolutionCallback: (locale, supported) {
        if (locale != null) {
          for (final l in supported) {
            if (l.languageCode == locale.languageCode) return l;
          }
        }
        return const Locale('en');
      },
      // 暗色优先(§8.2-2):默认暗色,跟随系统切亮色
      theme: LaresTheme.light(),
      darkTheme: LaresTheme.dark(),
      themeMode: ThemeMode.dark,
      // 同意内容规范之前不放行到主界面(指南 1.2)
      home: consentStore == null
          ? home
          : ContentPolicyGate(consent: consentStore, child: home),
    );
  }
}




