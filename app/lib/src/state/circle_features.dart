// 圈级功能开关与用途(契约 docs/plans/features-purpose-contract.md §1/§3)。
//
// 服务器权威:welcome.circle / circle_summary / circle_settings 都带
// `features`(9 个布尔,已解析出派生值)和 `purpose`。老服务器不发 features
// → 一律当全开(和过去的行为一致)。

/// 功能键。语音与文字聊天永远开,不在这里。
enum CircleFeature {
  captions,
  transcript,
  voiceNotes,
  map,
  recording,
  plugins,
  focus,
  p2p,
  devTools;

  /// 线上键名(与服务器一致)
  String get key => name;

  static CircleFeature? fromKey(String k) {
    for (final f in values) {
      if (f.key == k) return f;
    }
    return null;
  }
}

class CircleFeatures {
  const CircleFeatures(this._on);

  /// 老服务器 / 老圈:全开
  static const CircleFeatures legacy = CircleFeatures({
    CircleFeature.captions: true,
    CircleFeature.transcript: true,
    CircleFeature.voiceNotes: true,
    CircleFeature.map: true,
    CircleFeature.recording: true,
    CircleFeature.plugins: true,
    CircleFeature.focus: true,
    CircleFeature.p2p: true,
    CircleFeature.devTools: true,
  });

  final Map<CircleFeature, bool> _on;

  bool isOn(CircleFeature f) => _on[f] ?? true;

  bool get captions => isOn(CircleFeature.captions);
  bool get transcript => isOn(CircleFeature.transcript);
  bool get voiceNotes => isOn(CircleFeature.voiceNotes);
  bool get map => isOn(CircleFeature.map);
  bool get recording => isOn(CircleFeature.recording);
  bool get plugins => isOn(CircleFeature.plugins);
  bool get focus => isOn(CircleFeature.focus);
  bool get p2p => isOn(CircleFeature.p2p);
  bool get devTools => isOn(CircleFeature.devTools);

  /// [raw] 为服务器下发的 `features` 对象。缺的键当开(老服务器的语义)。
  /// [transcript] / [focus] 是派生值:服务器给了就用服务器的,
  /// 没给时用调用方传进来的兜底(圈设置的 transcript 位 / 专注插件状态)。
  factory CircleFeatures.fromJson(Object? raw, {bool? transcript, bool? focus}) {
    final m = <CircleFeature, bool>{};
    if (raw is Map) {
      for (final f in CircleFeature.values) {
        final v = raw[f.key];
        if (v is bool) m[f] = v;
      }
    }
    if (!m.containsKey(CircleFeature.transcript) && transcript != null) {
      m[CircleFeature.transcript] = transcript;
    }
    if (!m.containsKey(CircleFeature.focus) && focus != null) {
      m[CircleFeature.focus] = focus;
    }
    return CircleFeatures(m);
  }

  CircleFeatures copyWith(CircleFeature f, bool on) =>
      CircleFeatures({..._on, f: on});

  Map<String, bool> toJson() =>
      {for (final f in CircleFeature.values) f.key: isOn(f)};

  @override
  bool operator ==(Object other) =>
      other is CircleFeatures &&
      CircleFeature.values.every((f) => isOn(f) == other.isOn(f));

  @override
  int get hashCode => Object.hashAll(CircleFeature.values.map(isOn));
}

/// 圈子当前的用途(只是一块「名牌」;真正生效的是功能与插件)。
class CirclePurposeInfo {
  const CirclePurposeInfo({
    required this.id,
    required this.name,
    this.icon,
    this.description,
    this.builtin = false,
    this.e2eeWarning = false,
  });

  final String id;
  final String name;
  final String? icon;
  final String? description;
  final bool builtin;
  final bool e2eeWarning;

  static CirclePurposeInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final icon = raw['icon'];
    final desc = raw['description'];
    return CirclePurposeInfo(
      id: id,
      name: name,
      icon: icon is String && icon.isNotEmpty ? icon : null,
      description: desc is String && desc.isNotEmpty ? desc : null,
      builtin: raw['builtin'] == true,
      e2eeWarning: raw['e2eeWarning'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CirclePurposeInfo &&
      other.id == id &&
      other.name == name &&
      other.icon == icon &&
      other.description == description &&
      other.builtin == builtin &&
      other.e2eeWarning == e2eeWarning;

  @override
  int get hashCode =>
      Object.hash(id, name, icon, description, builtin, e2eeWarning);
}
