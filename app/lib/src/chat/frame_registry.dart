/// 帧类型注册表:把「收到一帧该交给谁」从 switch 变成查表。
///
/// ## 为什么要它
///
/// 原来 `chat_service.dart` 里是一个硬编码 switch:
///
/// ```dart
/// switch (decoded.type) {
///   case chatTypeText: _onTextFrame(h);
///   case chatTypeImage: _assembler.addChunk(h, payload);
///   default: break;
/// }
/// ```
///
/// 每加一种消息类型就要改这个 switch,而它在 ChatService 内部 ——
/// 于是「发文件」这种和聊天无关的能力也得挤进 ChatService。
/// 注册表把这层反过来:类型自己声明「我叫什么、谁来处理我」。
///
/// 这不是为了插件系统才做的抽象。**即使插件永远不做**,
/// 把类型分发从业务类里拆出来,ChatService 也会小一圈。
///
/// ## 命名空间
///
/// 内核类型是裸名(`text`、`img`),插件类型必须带 `x/` 前缀加反向域名:
///
/// ```text
/// text                      内核
/// img                       内核(将来会迁成内置插件)
/// x/com.example.chess       第三方
/// ```
///
/// `x/` 让内核一眼看出「这是插件的,我不认识很正常」,
/// 也保证第三方永远不会撞上将来新增的内核类型。
/// 见 docs/plans/plugin-protocol.md。
library;

import 'dart:typed_data';

/// 插件帧类型的前缀。见本文件头部关于命名空间的说明。
const String kPluginTypePrefix = 'x/';

/// 一帧交给处理器时的样子。**已经解密、已经重组**。
///
/// 处理器拿不到密钥,也拿不到加密后的字节 —— 这是 E2EE 承诺能成立的前提:
/// 即使某个处理器是恶意的,它也只能泄露经手的这一条,
/// 不能解密别人的历史。
class IncomingFrame {
  const IncomingFrame({
    required this.type,
    required this.header,
    required this.payload,
  });

  /// 帧类型,即 header 里的 `t`
  final String type;

  /// 解析好的 header。调用方不应修改。
  final Map<String, dynamic> header;

  /// 二进制载荷,文字帧为空
  final Uint8List payload;
}

/// 处理一帧。返回值无意义 —— 处理器要么消费掉,要么什么都不做。
typedef FrameHandler = void Function(IncomingFrame frame);

/// 帧类型 → 处理器。
///
/// 线程模型:与 ChatService 同线程(Dart 单线程事件循环),
/// 不需要加锁。
class FrameRegistry {
  final Map<String, FrameHandler> _handlers = <String, FrameHandler>{};

  /// 已注册的类型,用于 hello 握手时上报 `caps`。
  ///
  /// 返回副本:调用方拿去塞进 JSON,不该能反过来改注册表。
  List<String> get registeredTypes => List<String>.unmodifiable(_handlers.keys);

  /// 注册一个类型的处理器。
  ///
  /// 重复注册同一类型会**抛异常**而不是覆盖 —— 静默覆盖意味着
  /// 后加载的插件能劫持内核类型(比如接管 `text`),
  /// 那是个安全问题,不是配置问题。
  void register(String type, FrameHandler handler) {
    if (type.isEmpty) {
      throw ArgumentError('帧类型不能为空串');
    }
    if (_handlers.containsKey(type)) {
      throw StateError(
        '帧类型 "$type" 已被注册。重复注册会让后者劫持前者,'
        '这里刻意不允许静默覆盖。',
      );
    }
    _handlers[type] = handler;
  }

  /// 注销。插件卸载时用。
  bool unregister(String type) => _handlers.remove(type) != null;

  /// 是否认识这个类型。
  bool supports(String type) => _handlers.containsKey(type);

  /// 分发一帧。**未知类型不是错误** —— 对方可能装了我们没有的插件,
  /// 静默忽略是正确的向前兼容姿态(原 switch 的 `default: break` 即此意)。
  ///
  /// 返回是否被消费,供调用方统计/调试。
  bool dispatch(IncomingFrame frame) {
    final FrameHandler? h = _handlers[frame.type];
    if (h == null) return false;
    h(frame);
    return true;
  }
}

/// 这个类型是不是插件提供的。
bool isPluginType(String type) => type.startsWith(kPluginTypePrefix);

/// 校验插件类型的命名是否合法:`x/` + 反向域名。
///
/// 只做形状检查,不验证域名真实存在 —— 那既做不到也没必要,
/// 目的只是避免第三方之间、以及第三方与内核之间撞名。
bool isValidPluginType(String type) {
  if (!isPluginType(type)) return false;
  final String body = type.substring(kPluginTypePrefix.length);
  if (body.isEmpty) return false;
  // 至少要有一个点(com.example 这种),且不以点开头/结尾
  if (!body.contains('.')) return false;
  if (body.startsWith('.') || body.endsWith('.')) return false;
  // 只允许 ASCII 字母数字、点、连字符、下划线。
  // 不允许空白与斜杠:前者在 JSON 里易出错,后者会和前缀混淆。
  return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(body);
}
