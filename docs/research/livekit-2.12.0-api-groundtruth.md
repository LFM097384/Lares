# Ground-truth source verification — `livekit_client-2.12.0`

Package root: `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\`

Everything below is transcribed verbatim from the files at the stated paths and line numbers.

---

# SECTION A — `AudioCaptureOptions`

**File (full path):** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart` (569 lines total)

Declaration site — **line 323**:

```dart
class AudioCaptureOptions extends LocalTrackOptions implements AudioProcessingOptions {
```

> **IMPORTANT / DIFFERENT FROM A NAIVE EXPECTATION:** it extends `LocalTrackOptions` **and `implements AudioProcessingOptions`**. `AudioProcessingOptions` is a *separate concrete class* in the same file (line 269) that `AudioCaptureOptions` structurally satisfies. There is **no mixin**.

## A.1 — Constructor signature + every field declaration (verbatim)

### Constructor — lines 382–396, and it **IS `const`**

```dart
  const AudioCaptureOptions({
    this.deviceId,
    this.noiseSuppression = true,
    this.echoCancellation = true,
    this.autoGainControl = true,
    this.highPassFilter = false,
    this.echoCancellationMode = AudioProcessingMode.automatic,
    this.noiseSuppressionMode = AudioProcessingMode.automatic,
    this.autoGainControlMode = AudioProcessingMode.automatic,
    this.highPassFilterMode = AudioProcessingMode.automatic,
    this.voiceIsolation = true,
    this.typingNoiseDetection = true,
    this.stopAudioCaptureOnMute = true,
    this.processor,
  });
```

**Parameter table (all named, NONE `required`, all optional):**

| # | Name | Type | required? | Default |
|---|------|------|-----------|---------|
| 1 | `deviceId` | `String?` | no | `null` (implicit) |
| 2 | `noiseSuppression` | `bool` | no | `true` |
| 3 | `echoCancellation` | `bool` | no | `true` |
| 4 | `autoGainControl` | `bool` | no | `true` |
| 5 | `highPassFilter` | `bool` | no | **`false`** |
| 6 | `echoCancellationMode` | `AudioProcessingMode` | no | `AudioProcessingMode.automatic` |
| 7 | `noiseSuppressionMode` | `AudioProcessingMode` | no | `AudioProcessingMode.automatic` |
| 8 | `autoGainControlMode` | `AudioProcessingMode` | no | `AudioProcessingMode.automatic` |
| 9 | `highPassFilterMode` | `AudioProcessingMode` | no | `AudioProcessingMode.automatic` |
| 10 | `voiceIsolation` | `bool` | no | `true` |
| 11 | `typingNoiseDetection` | `bool` | no | `true` |
| 12 | `stopAudioCaptureOnMute` | `bool` | no | `true` |
| 13 | `processor` | `TrackProcessor<AudioProcessorOptions>?` | no | `null` (implicit) |

There is **exactly one constructor**. **There is NO `AudioCaptureOptions.from(...)` named constructor** (unlike `CameraCaptureOptions.from` at line 75 and `ScreenShareCaptureOptions.from` at line 160). **NO `.communication()` / `.noProcessing()` factories on `AudioCaptureOptions`** — those exist only on `AudioProcessingOptions` (lines 281, 291).

### Field declarations — verbatim, lines 324–380

```dart
  /// The deviceId of the capture device to use.
  /// Available deviceIds can be obtained through `flutter_webrtc`:
  /// ```
  /// import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
  ///
  /// List<MediaDeviceInfo> devices = await rtc.navigator.mediaDevices.enumerateDevices();
  /// ```
  final String? deviceId;                                    // line 331

  /// Attempt to use noiseSuppression option (if supported by the platform)
  /// See https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackSettings/noiseSuppression
  /// Defaults to true.
  @override
  final bool noiseSuppression;                               // line 337

  /// Attempt to use echoCancellation option (if supported by the platform)
  /// See https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackSettings/echoCancellation
  /// Defaults to true.
  @override
  final bool echoCancellation;                               // line 343

  /// Attempt to use autoGainControl option (if supported by the platform)
  /// See https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackConstraints/autoGainControl
  /// Defaults to true.
  @override
  final bool autoGainControl;                                // line 349

  /// Attempt to use highPassFilter options (if supported by the platform)
  /// Defaults to false.
  @override
  final bool highPassFilter;                                 // line 354

  @override
  final AudioProcessingMode echoCancellationMode;            // line 357

  @override
  final AudioProcessingMode noiseSuppressionMode;            // line 360

  @override
  final AudioProcessingMode autoGainControlMode;             // line 363

  @override
  final AudioProcessingMode highPassFilterMode;              // line 366

  /// Attempt to use typingNoiseDetection option (if supported by the platform)
  /// Defaults to true.
  final bool typingNoiseDetection;                           // line 370

  /// Attempt to use voiceIsolation option (if supported by the platform)
  /// Defaults to true.
  final bool voiceIsolation;                                 // line 374

  /// set to false to only toggle enabled instead of stop/replaceTrack for muting
  final bool stopAudioCaptureOnMute;                         // line 377

  /// A processor to apply to the audio track.
  final TrackProcessor<AudioProcessorOptions>? processor;    // line 380
```

All 13 fields are `final` (instance fields). **None are `static const`.** There is no `static const` member on `AudioCaptureOptions` at all.

### Additional non-constructor member — computed getter, lines 398–407

```dart
  AudioProcessingOptions get processing => AudioProcessingOptions(
    echoCancellation: echoCancellation,
    noiseSuppression: noiseSuppression,
    autoGainControl: autoGainControl,
    highPassFilter: highPassFilter,
    echoCancellationMode: echoCancellationMode,
    noiseSuppressionMode: noiseSuppressionMode,
    autoGainControlMode: autoGainControlMode,
    highPassFilterMode: highPassFilterMode,
  );
```

### And `toMap()` override — lines 409–410

```dart
  @override
  Map<String, dynamic> toMap() => processing.toMap();
```

### Base class `LocalTrackOptions` — lines 205–210 (verbatim, complete)

```dart
/// Base class for track options.
abstract class LocalTrackOptions {
  const LocalTrackOptions();

  // All subclasses must be able to report constraints
  Map<String, dynamic> toMediaConstraintsMap();
}
```

**It has NO fields.** So `AudioCaptureOptions` inherits **zero** fields from its superclass — every field listed above is declared directly on `AudioCaptureOptions`.

### The interface it implements: `AudioProcessingOptions` — lines 268–320 (verbatim, complete)

```dart
@experimental
class AudioProcessingOptions {
  const AudioProcessingOptions({
    required this.echoCancellation,
    required this.noiseSuppression,
    required this.autoGainControl,
    required this.highPassFilter,
    this.echoCancellationMode = AudioProcessingMode.automatic,
    this.noiseSuppressionMode = AudioProcessingMode.automatic,
    this.autoGainControlMode = AudioProcessingMode.automatic,
    this.highPassFilterMode = AudioProcessingMode.automatic,
  });

  const AudioProcessingOptions.communication()
    : echoCancellation = true,
      noiseSuppression = true,
      autoGainControl = true,
      highPassFilter = true,
      echoCancellationMode = AudioProcessingMode.automatic,
      noiseSuppressionMode = AudioProcessingMode.automatic,
      autoGainControlMode = AudioProcessingMode.automatic,
      highPassFilterMode = AudioProcessingMode.automatic;

  const AudioProcessingOptions.noProcessing()
    : echoCancellation = false,
      noiseSuppression = false,
      autoGainControl = false,
      highPassFilter = false,
      echoCancellationMode = AudioProcessingMode.automatic,
      noiseSuppressionMode = AudioProcessingMode.automatic,
      autoGainControlMode = AudioProcessingMode.automatic,
      highPassFilterMode = AudioProcessingMode.automatic;

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;
  final bool highPassFilter;
  final AudioProcessingMode echoCancellationMode;
  final AudioProcessingMode noiseSuppressionMode;
  final AudioProcessingMode autoGainControlMode;
  final AudioProcessingMode highPassFilterMode;

  Map<String, dynamic> toMap() => {
    'echoCancellation': echoCancellation,
    'noiseSuppression': noiseSuppression,
    'autoGainControl': autoGainControl,
    'highPassFilter': highPassFilter,
    'echoCancellationMode': echoCancellationMode.constraintValue,
    'noiseSuppressionMode': noiseSuppressionMode.constraintValue,
    'autoGainControlMode': autoGainControlMode.constraintValue,
    'highPassFilterMode': highPassFilterMode.constraintValue,
  };
}
```

> Note: in `AudioProcessingOptions`'s own main constructor the four booleans **ARE `required`** (lines 271–274). In `AudioCaptureOptions` they are **not** required — they have defaults. Do not confuse the two.

## A.2 — PRESENT / ABSENT confirmation for each requested member

All checks are against `class AudioCaptureOptions` in `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart`.

| Member | Verdict | Line | Exact declaration |
|---|---|---|---|
| `noiseSuppression` | **PRESENT** | 337 | `final bool noiseSuppression;` (with `@override` on 336) |
| `echoCancellation` | **PRESENT** | 343 | `final bool echoCancellation;` (with `@override` on 342) |
| `autoGainControl` | **PRESENT** | 349 | `final bool autoGainControl;` (with `@override` on 348) |
| `highPassFilter` | **PRESENT** | 354 | `final bool highPassFilter;` (with `@override` on 353) |
| `voiceIsolation` | **PRESENT** | 374 | `final bool voiceIsolation;` |
| `typingNoiseDetection` | **PRESENT** | 370 | `final bool typingNoiseDetection;` |
| `stopAudioCaptureOnMute` | **PRESENT** | 377 | `final bool stopAudioCaptureOnMute;` |
| `echoCancellationMode` | **PRESENT** | 357 | `final AudioProcessingMode echoCancellationMode;` |
| `noiseSuppressionMode` | **PRESENT** | 360 | `final AudioProcessingMode noiseSuppressionMode;` |
| `autoGainControlMode` | **PRESENT** | 363 | `final AudioProcessingMode autoGainControlMode;` |
| `highPassFilterMode` | **PRESENT** | 366 | `final AudioProcessingMode highPassFilterMode;` |
| `processor` | **PRESENT** | 380 | `final TrackProcessor<AudioProcessorOptions>? processor;` |
| `deviceId` | **PRESENT** | 331 | `final String? deviceId;` |

### **ALL 13 REQUESTED MEMBERS ARE PRESENT. THERE ARE ZERO ABSENCES.**

**No member you asked about is missing.** Every one of `noiseSuppression`, `echoCancellation`, `autoGainControl`, `highPassFilter`, `voiceIsolation`, `typingNoiseDetection`, `stopAudioCaptureOnMute`, `echoCancellationMode`, `noiseSuppressionMode`, `autoGainControlMode`, `highPassFilterMode`, `processor`, and `deviceId` exists as a declared `final` instance field **and** as a named constructor parameter **and** as a `copyWith` parameter.

**Deviations from a plain-expectation worth flagging LOUDLY:**

- **`highPassFilter` DEFAULTS TO `false`, not `true`** (line 387). Every other boolean defaults to `true`. Its doc comment at line 352 explicitly says "Defaults to false."
- **`voiceIsolation` is a declared field but is NEVER read by `toMediaConstraintsMap()`.** In the non-bypass branch, line 439 emits `{'voiceIsolation': noiseSuppression}` — it uses **`noiseSuppression`**, NOT `voiceIsolation`. **Setting `voiceIsolation: false` has NO effect on the generated media constraints.** It is also not present in `AudioProcessingOptions.toMap()`. It is carried through `copyWith` (line 492) and stored, but is dead with respect to constraint generation. **This looks like an upstream bug; do not rely on `voiceIsolation`.**
- **The four `*Mode` fields are NOT used by `toMediaConstraintsMap()` at all.** They only travel via `toMap()` → `AudioProcessingOptions.toMap()` (lines 310–319) → the native `setAudioProcessingOptions` / `startLocalRecording` method-channel path. They are **capture-constraint-invisible**.
- **`stopAudioCaptureOnMute` is likewise not used in `toMediaConstraintsMap()`** — it is consumed elsewhere in the track lifecycle.
- **`AudioProcessingOptions`, `AudioProcessingMode`, `AudioProcessingFailureReason`, `AudioProcessingException` are all annotated `@experimental`** (lines 248, 268, 521, 560) via `import 'package:meta/meta.dart';` at line 17. `AudioCaptureOptions` itself is **not** marked experimental.

## A.3 — `AudioProcessingMode` enum

**IT EXISTS.** Declared in the same file.

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart`
**Lines 245–257**, verbatim and complete:

```dart
/// Selects whether a voice-processing component uses platform or software processing.
///
/// Experimental: this API may change in a future release.
@experimental
enum AudioProcessingMode {
  automatic('auto'),
  platform('platform'),
  software('software');

  const AudioProcessingMode(this.constraintValue);

  final String constraintValue;
}
```

**ALL enum values (exactly three):**

| Dart value | line | `constraintValue` (wire string) |
|---|---|---|
| `AudioProcessingMode.automatic` | 250 | `'auto'` |
| `AudioProcessingMode.platform` | 251 | `'platform'` |
| `AudioProcessingMode.software` | 252 | `'software'` |

> **Note the asymmetry: the Dart value is `automatic` but its wire string is `'auto'`** (not `'automatic'`).

### Related enums found elsewhere (for completeness)

`C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\audio\audio_processing_state.dart` **lines 22–38**:

```dart
@experimental
enum AudioProcessingImplementation {
  unknown('unknown'),
  disabled('disabled'),
  software('software'),
  platform('platform'),
  softwareAndPlatform('softwareAndPlatform');

  const AudioProcessingImplementation(this.value);

  final String value;

  static AudioProcessingImplementation fromValue(String? value) => AudioProcessingImplementation.values.firstWhere(
    (e) => e.value == value,
    orElse: () => AudioProcessingImplementation.unknown,
  );
}
```

`...\lib\src\track\options.dart` **lines 521–534**:

```dart
@experimental
enum AudioProcessingFailureReason {
  /// The requested mode combination is invalid for the native audio module.
  invalidCombination,

  /// The platform or device cannot provide the requested processing path.
  platformUnavailable,

  /// The native layer attempted to apply the options but failed.
  applyFailed,

  /// The native layer returned an unrecognized or malformed result.
  unknown,
}
```

Native-side counterparts of `AudioProcessingMode` (string ⇄ native enum mapping), all verified present:
- `...\android\src\main\kotlin\io\livekit\plugin\LiveKitPlugin.kt` lines 355–358 (`"platform"`→`AudioProcessingMode.PLATFORM`, `"software"`→`SOFTWARE`, else→`AUTOMATIC`) and lines 379–382 (reverse mapping, `AUTOMATIC`→`"auto"`).
- `...\shared_swift\LiveKitPlugin.swift` lines 722, 750; identical copies at `...\ios\Classes\LiveKitPlugin.swift`, `...\ios\livekit_client\Sources\livekit_client\LiveKitPlugin.swift`, `...\macos\Classes\LiveKitPlugin.swift`, `...\macos\livekit_client\Sources\livekit_client\LiveKitPlugin.swift` (same line numbers) — `static func audioProcessingMode(from string: String?) -> RTCAudioProcessingMode`.

## A.4 — Exact declared type of `processor`

**Declaration** — `...\lib\src\track\options.dart` line 380:

```dart
  /// A processor to apply to the audio track.
  final TrackProcessor<AudioProcessorOptions>? processor;
```

So the type is exactly **`TrackProcessor<AudioProcessorOptions>?`** — nullable, your expectation matches.

### Where `TrackProcessor` is declared

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\processor.dart`
**Lines 15–29**, verbatim and complete (whole file is 29 lines):

```dart
abstract class TrackProcessor<T extends ProcessorOptions> {
  String get name;

  Future<void> init(T options);

  Future<void> restart(T options);

  Future<void> destroy();

  Future<void> onPublish(Room room);

  Future<void> onUnpublish();

  MediaStreamTrack? get processedTrack;
}
```

And its bound, same file, lines 6–13:

```dart
class ProcessorOptions<T extends TrackType> {
  T kind;
  MediaStreamTrack track;
  ProcessorOptions({
    required this.kind,
    required this.track,
  });
}
```

### Where `AudioProcessorOptions` is declared — **CONDITIONAL IMPORT, TWO DEFINITIONS**

`...\lib\src\track\options.dart` line 25:

```dart
import 'processor_native.dart' if (dart.library.js_interop) 'processor_web.dart';
```

**Native/mobile/desktop definition** — `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\processor_native.dart` **lines 6–10** (whole file is 16 lines):

```dart
class AudioProcessorOptions extends ProcessorOptions {
  AudioProcessorOptions({
    required MediaStreamTrack track,
  }) : super(kind: TrackType.AUDIO, track: track);
}
```

(same file, lines 12–16, for symmetry:)

```dart
class VideoProcessorOptions extends ProcessorOptions {
  VideoProcessorOptions({
    required MediaStreamTrack track,
  }) : super(kind: TrackType.VIDEO, track: track);
}
```

**Web definition** exists at `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\processor_web.dart` **line 7** (`class AudioProcessorOptions extends ProcessorOptions {`).

Both are re-exported publicly by `...\lib\livekit_client.dart` line 66:

```dart
export 'src/track/processor_native.dart' if (dart.library.js_interop) 'src/track/processor_web.dart';
```

and `TrackProcessor` itself by line 65:

```dart
export 'src/track/processor.dart';
```

## A.5 — `toMediaConstraintsMap()` — verbatim, all versions

### A.5.1 — The abstract declaration (`LocalTrackOptions`)

**Path:** `...\lib\src\track\options.dart`, **line 209** (inside class at 205–210):

```dart
  Map<String, dynamic> toMediaConstraintsMap();
```

No body. `AudioCaptureOptions` therefore has **NO `super.toMediaConstraintsMap()` to call**, and correctly does not call one.

### A.5.2 — `AudioCaptureOptions.toMediaConstraintsMap()` — **lines 412–464**

**Path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart`
**Line range: 412–464** (annotation on 412, signature on 413, closing brace on 464).

```dart
  @override
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = <String, dynamic>{};

    if (Native.bypassVoiceProcessing) {
      constraints['optional'] = <Map<String, dynamic>>[
        <String, dynamic>{'googEchoCancellation': false},
        <String, dynamic>{'googEchoCancellation2': false},
        <String, dynamic>{'googNoiseSuppression': false},
        <String, dynamic>{'googNoiseSuppression2': false},
        <String, dynamic>{'googAutoGainControl': false},
        <String, dynamic>{'googHighpassFilter': false},
        <String, dynamic>{'googTypingNoiseDetection': false},
        <String, dynamic>{'noiseSuppression': false},
        <String, dynamic>{'echoCancellation': false},
        <String, dynamic>{'autoGainControl': false},
        <String, dynamic>{'voiceIsolation': false},
        <String, dynamic>{'googDAEchoCancellation': false},
      ];
    } else {
      /// in we platform it's not possible to provide optional and mandatory parameters.
      /// deviceId is a mandatory parameter
      if (!kIsWeb || (kIsWeb && deviceId == null)) {
        constraints['optional'] = <Map<String, dynamic>>[
          <String, dynamic>{'echoCancellation': echoCancellation},
          <String, dynamic>{'noiseSuppression': noiseSuppression},
          <String, dynamic>{'autoGainControl': autoGainControl},
          <String, dynamic>{'voiceIsolation': noiseSuppression},
          <String, dynamic>{'googDAEchoCancellation': echoCancellation},
          <String, dynamic>{'googEchoCancellation': echoCancellation},
          <String, dynamic>{'googEchoCancellation2': echoCancellation},
          <String, dynamic>{'googNoiseSuppression': noiseSuppression},
          <String, dynamic>{'googNoiseSuppression2': noiseSuppression},
          <String, dynamic>{'googAutoGainControl': autoGainControl},
          <String, dynamic>{'googHighpassFilter': highPassFilter},
          <String, dynamic>{'googTypingNoiseDetection': typingNoiseDetection},
        ];
      }
    }

    if (deviceId != null && deviceId!.isNotEmpty) {
      if (kIsWeb) {
        if (isChrome129OrLater()) {
          constraints['deviceId'] = {'exact': deviceId};
        } else {
          constraints['deviceId'] = {'ideal': deviceId};
        }
      } else {
        constraints['optional'].cast<Map<String, dynamic>>().add(<String, dynamic>{'sourceId': deviceId});
      }
    }
    return constraints;
  }
```

**Behavioral facts readable directly from this body:**

- The `'optional'` key holds a **`List<Map<String, dynamic>>`** — a list of single-entry maps, not a flat map. This is flutter-webrtc's legacy "optional" constraint array form.
- The bypass branch emits **12** entries, all hard-coded `false`, **completely ignoring every field on the object** (`echoCancellation`, `noiseSuppression`, `autoGainControl`, `highPassFilter`, `typingNoiseDetection`, `voiceIsolation` are all discarded).
- The normal branch emits **12** entries. `highPassFilter` maps **only** to `'googHighpassFilter'` (lowercase `p` in `passFilter` → `Highpassfilter` spelled `googHighpassFilter`). There is no plain `'highPassFilter'` constraint key.
- **`'voiceIsolation'` is fed from `noiseSuppression`** (line 439) — see the LOUD note in A.2.
- **Web + non-null `deviceId` skips the `'optional'` list entirely** (guard at line 434). In that case `constraints` contains **only** `'deviceId'`, so **all audio-processing booleans are silently dropped on Web when a deviceId is specified.**
- Line 460 does `constraints['optional'].cast<...>().add(...)`. On non-web this is safe because the `!kIsWeb` guard always populated `'optional'`. **But if `kIsWeb` is false it is fine; on web it is unreachable.** No null-check bug in practice, but note `'sourceId'` — not `'deviceId'` — is what native gets.
- `isChrome129OrLater()` comes from `import '../support/platform.dart';` (line 20).

### A.5.3 — Inherited/sibling versions in the same file (for contrast, NOT inherited by `AudioCaptureOptions`)

`VideoCaptureOptions.toMediaConstraintsMap()` — **line 241–242**:

```dart
  @override
  Map<String, dynamic> toMediaConstraintsMap() => params.toMediaConstraintsMap();
```

`CameraCaptureOptions.toMediaConstraintsMap()` — **lines 87–110**:

```dart
  @override
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = <String, dynamic>{
      ...super.toMediaConstraintsMap(),
      if (deviceId == null) 'facingMode': cameraPosition == CameraPosition.front ? 'user' : 'environment',
    };
    if (deviceId != null && deviceId!.isNotEmpty) {
      if (kIsWeb) {
        if (isChrome129OrLater()) {
          constraints['deviceId'] = {'exact': deviceId};
        } else {
          constraints['deviceId'] = {'ideal': deviceId};
        }
      } else {
        constraints['optional'] = [
          {'sourceId': deviceId},
        ];
      }
    }
    if (maxFrameRate != null) {
      constraints['frameRate'] = {'max': maxFrameRate};
    }
    return constraints;
  }
```

`ScreenShareCaptureOptions.toMediaConstraintsMap()` — **lines 186–201**:

```dart
  @override
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = super.toMediaConstraintsMap();
    if (useiOSBroadcastExtension && lkPlatformIs(PlatformType.iOS)) {
      constraints['deviceId'] = 'broadcast-manual';
    }
    if (lkPlatformIsDesktop()) {
      if (deviceId != null) {
        constraints['deviceId'] = {'exact': deviceId};
      }
      if (maxFrameRate != 0.0) {
        constraints['mandatory'] = {'frameRate': maxFrameRate};
      }
    }
    return constraints;
  }
```

### A.5.4 — Where `toMediaConstraintsMap()` is actually CALLED for audio

**Path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\local\local.dart`
**Lines 246–258**:

```dart
  /// Creates a [rtc.MediaStream] from [LocalTrackOptions].
  @internal
  static Future<rtc.MediaStream> createStream(
    LocalTrackOptions options,
  ) async {
    final constraints = <String, dynamic>{
      'audio': options is AudioCaptureOptions
          ? options.toMediaConstraintsMap()
          : options is ScreenShareCaptureOptions
          ? (options).captureScreenAudio
          : false,
      'video': options is VideoCaptureOptions ? options.toMediaConstraintsMap() : false,
    };
```

Complete list of call sites in the package (`grep toMediaConstraintsMap` over `lib\`):
- `...\lib\src\track\options.dart`: 88, 90, 187, 188, 209, 242, 413
- `...\lib\src\track\local\local.dart`: 253, 257
- `...\lib\src\types\video_parameters.dart`: 65

## A.6 — const-constructible? `copyWith`?

**Const-constructible: YES.** The constructor at line 382 is declared `const AudioCaptureOptions({...})`, and all 13 fields are `final`, and the superclass `LocalTrackOptions` has `const LocalTrackOptions();` (line 206). So `const AudioCaptureOptions()` compiles.

**`copyWith`: YES.** `...\lib\src\track\options.dart` **lines 466–497**, verbatim:

```dart
  AudioCaptureOptions copyWith({
    String? deviceId,
    bool? noiseSuppression,
    bool? echoCancellation,
    bool? autoGainControl,
    bool? highPassFilter,
    AudioProcessingMode? echoCancellationMode,
    AudioProcessingMode? noiseSuppressionMode,
    AudioProcessingMode? autoGainControlMode,
    AudioProcessingMode? highPassFilterMode,
    AudioProcessingOptions? processing,
    bool? voiceIsolation,
    bool? typingNoiseDetection,
    bool? stopAudioCaptureOnMute,
    TrackProcessor<AudioProcessorOptions>? processor,
  }) {
    return AudioCaptureOptions(
      deviceId: deviceId ?? this.deviceId,
      noiseSuppression: processing?.noiseSuppression ?? noiseSuppression ?? this.noiseSuppression,
      echoCancellation: processing?.echoCancellation ?? echoCancellation ?? this.echoCancellation,
      autoGainControl: processing?.autoGainControl ?? autoGainControl ?? this.autoGainControl,
      highPassFilter: processing?.highPassFilter ?? highPassFilter ?? this.highPassFilter,
      echoCancellationMode: processing?.echoCancellationMode ?? echoCancellationMode ?? this.echoCancellationMode,
      noiseSuppressionMode: processing?.noiseSuppressionMode ?? noiseSuppressionMode ?? this.noiseSuppressionMode,
      autoGainControlMode: processing?.autoGainControlMode ?? autoGainControlMode ?? this.autoGainControlMode,
      highPassFilterMode: processing?.highPassFilterMode ?? highPassFilterMode ?? this.highPassFilterMode,
      voiceIsolation: voiceIsolation ?? this.voiceIsolation,
      typingNoiseDetection: typingNoiseDetection ?? this.typingNoiseDetection,
      stopAudioCaptureOnMute: stopAudioCaptureOnMute ?? this.stopAudioCaptureOnMute,
      processor: processor ?? this.processor,
    );
  }
```

> **`copyWith` takes a 14th parameter NOT present on the constructor: `AudioProcessingOptions? processing`.** When supplied it **takes precedence over** the individual `echoCancellation`/`noiseSuppression`/`autoGainControl`/`highPassFilter` + the four `*Mode` arguments (`processing?.X ?? X ?? this.X`). **So passing both `processing:` and e.g. `echoCancellation:` silently ignores the latter.**
>
> **`copyWith` CANNOT null out `deviceId` or `processor`** — the `?? this.x` pattern means passing `null` keeps the old value. There is no sentinel/`ValueOrAbsent` mechanism here (note: the package *does* have `lib\src\support\value_or_absent.dart`, exported at `...\lib\src\audio\audio_session.dart:15`, but it is **not** used by `AudioCaptureOptions.copyWith`).
>
> **There is NO `==` / `hashCode` / `toString()` override on `AudioCaptureOptions`.** Identity comparison only.

## A.7 — `AudioPublishOptions` — **IT IS IN A DIFFERENT FILE**

> **DIFFERENT FROM YOUR EXPECTATION: `AudioPublishOptions` is NOT in `lib\src\track\options.dart`.**

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\options.dart` (557 lines total) — note: `lib\src\options.dart`, **not** `lib\src\track\options.dart`.

Declaration at **line 503**. Verbatim, lines 502–549:

```dart
/// Options used when publishing audio.
class AudioPublishOptions extends PublishOptions {
  static const defaultMicrophoneName = 'microphone';

  /// Preferred encoding parameters.
  /// Defaults to [AudioEncoding.presetMusic] when not set.
  final AudioEncoding? encoding;

  /// Whether to enable DTX (Discontinuous Transmission) or not.
  /// https://en.wikipedia.org/wiki/Discontinuous_transmission
  /// Defaults to true.
  final bool dtx;

  /// red (Redundant Audio Data)
  final bool? red;

  /// Mark this audio as originating from a pre-connect buffer.
  /// Used to populate protobuf audioFeatures (TF_PRECONNECT_BUFFER).
  final bool preConnect;

  const AudioPublishOptions({
    super.name,
    super.stream,
    this.encoding,
    this.dtx = true,
    this.red = true,
    this.preConnect = false,
  });

  AudioPublishOptions copyWith({
    AudioEncoding? encoding,
    bool? dtx,
    String? name,
    String? stream,
    bool? red,
    bool? preConnect,
  }) => AudioPublishOptions(
    encoding: encoding ?? this.encoding,
    dtx: dtx ?? this.dtx,
    name: name ?? this.name,
    stream: stream ?? this.stream,
    red: red ?? this.red,
    preConnect: preConnect ?? this.preConnect,
  );

  @override
  String toString() => '${runtimeType}(encoding: ${encoding}, dtx: ${dtx}, red: ${red}, preConnect: ${preConnect})';
}
```

**Constructor parameter table** (`const`, all optional):

| Name | Type | required? | Default |
|---|---|---|---|
| `name` | `String?` | no | `null` (super param, from `PublishOptions`) |
| `stream` | `String?` | no | `null` (super param, from `PublishOptions`) |
| `encoding` | `AudioEncoding?` | no | `null` |
| `dtx` | `bool` | no | `true` |
| `red` | `bool?` | no | `true` |
| `preConnect` | `bool` | no | `false` |

Its base class `PublishOptions` — same file, **lines 401–414**, verbatim:

```dart
class PublishOptions {
  /// Name of the track.
  final String? name;

  ///  Set stream name for the track. Audio and video tracks with the same stream name
  ///  will be placed in the same `MediaStream` and offer better synchronization.
  ///  By default, camera and microphone will be placed in a stream; as would screen_share and screen_share_audio
  final String? stream;

  const PublishOptions({
    this.name,
    this.stream,
  });
}
```

`AudioPublishOptions` **is** const-constructible and **has** `copyWith` (no `processing` extra param there).

---

# SECTION B — `Native.bypassVoiceProcessing`

## B.1 — Exhaustive occurrence list

Two greps were run over the **entire package root** (all subfolders, all file types): `bypassVoiceProcessing` and the case-insensitive `(?i)bypassvoiceprocessing`. **Both returned the identical 16 matches.** There are no case variants.

> **LOUD NOTE: there are ZERO occurrences in any native source file.** Not in any `.kt`, `.swift`, `.java`, `.m`, `.h`, or `.podspec` under the package. The token appears **only** in Dart files, the CHANGELOG, and the example. The string is forwarded to flutter_webrtc's `WebRTC.initialize` and handled *inside the flutter_webrtc package*, which is outside this package root.

### Occurrence 1 — `...\lib\src\support\native.dart` line 38 — **THE DECLARATION**

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\support\native.dart`

Lines 26–48 verbatim:

```dart
// Method channel methods to call native code.
class Native {
  @internal
  static final channel = _createChannel();

  static MethodChannel _createChannel() {
    final channel = MethodChannel('livekit_client');
    channel.setMethodCallHandler(_handleMethodCall);
    return channel;
  }

  @internal
  static bool bypassVoiceProcessing = false;

  /// Configures (and caches) the Apple audio session.
  ///
  /// When [automatic] is true, the native audio-engine delegate owns activation
  /// timing: the configuration is cached and (re)applied on engine lifecycle
  /// events, and only applied immediately here if the engine is already
  /// running. When false (manual mode / explicit apply) it is applied
  /// immediately.
  @internal
  static Future<bool> configureAudio(
```

### Occurrence 2 — `...\lib\src\track\options.dart` line 416 — **THE ONLY READ**

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart`

Lines 409–431 verbatim (~15 lines of surrounding context):

```dart
  @override
  Map<String, dynamic> toMap() => processing.toMap();

  @override
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = <String, dynamic>{};

    if (Native.bypassVoiceProcessing) {
      constraints['optional'] = <Map<String, dynamic>>[
        <String, dynamic>{'googEchoCancellation': false},
        <String, dynamic>{'googEchoCancellation2': false},
        <String, dynamic>{'googNoiseSuppression': false},
        <String, dynamic>{'googNoiseSuppression2': false},
        <String, dynamic>{'googAutoGainControl': false},
        <String, dynamic>{'googHighpassFilter': false},
        <String, dynamic>{'googTypingNoiseDetection': false},
        <String, dynamic>{'noiseSuppression': false},
        <String, dynamic>{'echoCancellation': false},
        <String, dynamic>{'autoGainControl': false},
        <String, dynamic>{'voiceIsolation': false},
        <String, dynamic>{'googDAEchoCancellation': false},
      ];
    } else {
```

Enabled by the import at line 19 of the same file: `import '../support/native.dart';`

### Occurrences 3–7 — `...\lib\src\livekit.dart` lines 30, 52, 56, 59, 62 — **THE ONLY WRITE IN `lib\`**

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\livekit.dart`

Lines 23–72 verbatim (complete class, 72-line file):

```dart
/// Main entry point to connect to a room.
/// {@category Room}
class LiveKitClient {
  static const version = '2.12.0';

  /// Initialize the WebRTC plugin.
  ///
  /// Optional: call once at startup to enable [bypassVoiceProcessing] before
  /// connecting, or to apply Android [initialAudioSessionOptions] before WebRTC
  /// creates its audio device module. Otherwise WebRTC initializes lazily with
  /// defaults.
  ///
  /// LiveKit owns the platform audio session, and flutter_webrtc's own native
  /// audio management is disabled automatically when the LiveKit plugin loads
  /// (done natively at registration), so that does not depend on this call.
  ///
  /// Configure explicit runtime audio-session behavior through [AudioManager]
  /// before connecting, e.g.
  /// `await AudioManager.instance.setAudioSessionManagementMode(...)` and
  /// `await AudioManager.instance.setAudioSessionOptions(...)`.
  ///
  /// [initialAudioSessionOptions] currently affects Android's WebRTC
  /// initialization-time playout attributes, such as media vs voice
  /// communication usage. It also seeds [AudioManager]'s initial automatic
  /// runtime session policy until the app explicitly replaces it with
  /// [AudioManager.setAudioSessionOptions]. A future SDK/WebRTC integration may
  /// make those Android playout attributes runtime-updatable; for now, pass them
  /// here before WebRTC initializes.
  static Future<void> initialize({
    bool bypassVoiceProcessing = false,
    AudioSessionOptions? initialAudioSessionOptions,
  }) async {
    if (lkPlatformIsMobile()) {
      // bypassVoiceProcessing controls only WebRTC voice processing. Android
      // playout attributes are passed here because WebRTC reads them when it
      // creates the audio device module.
      Native.bypassVoiceProcessing = bypassVoiceProcessing;
      await rtc.WebRTC.initialize(
        options: liveKitWebRTCInitializeOptions(
          bypassVoiceProcessing: bypassVoiceProcessing,
          initialAudioSessionOptions: initialAudioSessionOptions,
          includeAndroidAudioConfiguration: lkPlatformIs(PlatformType.android),
        ),
      );
      if (lkPlatformIs(PlatformType.android) && initialAudioSessionOptions != null) {
        AudioManager.instance.setInitialAudioSessionOptions(initialAudioSessionOptions);
      }
    }
  }
}
```

### Occurrences 8–9 — `...\lib\src\support\webrtc_initialize_options.dart` lines 22, 26

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\support\webrtc_initialize_options.dart`

Lines 15–29 verbatim (end of the 29-line file):

```dart
import 'package:meta/meta.dart';

import '../audio/android_audio_session_adapter.dart';
import '../audio/audio_session.dart';

@internal
Map<String, dynamic> liveKitWebRTCInitializeOptions({
  required bool bypassVoiceProcessing,
  required AudioSessionOptions? initialAudioSessionOptions,
  required bool includeAndroidAudioConfiguration,
}) => {
  if (bypassVoiceProcessing) 'bypassVoiceProcessing': bypassVoiceProcessing,
  if (includeAndroidAudioConfiguration && initialAudioSessionOptions != null)
    'androidAudioConfiguration': androidAudioSessionConfigurationToMap(initialAudioSessionOptions.android),
};
```

> Note: the key is **only added when `true`** (collection-`if` at line 26). When false the map omits the key entirely.

### Occurrence 10 — `...\CHANGELOG.md` line 275

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\CHANGELOG.md`

```
* chore: Remove `bypassVoiceProcessing = true` settings for connect page. (#693)
```

### Occurrences 11–12 — `...\example\lib\main.dart` lines 23, 27 — **THE OFFICIAL USAGE EXAMPLE (COMMENTED OUT)**

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\example\lib\main.dart`

Lines 14–30 verbatim:

```dart

  WidgetsFlutterBinding.ensureInitialized();
  /*if (lkPlatformIsDesktop()) {
    await FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await onWindowShouldClose?.call();
      return true;
    });
  }*/

  /// for livestreaming app, you can initialize the bypassVoiceProcessing = true
  /// here to get better audio quality
  ///
  /// await LiveKitClient.initialize(
  ///  bypassVoiceProcessing: lkPlatformIsMobile(),
  /// );
  runApp(const LiveKitExampleApp());
}
```

### Occurrences 13–16 — `...\test\audio\audio_session_test.dart` lines 35, 849, 854, 870

**Full path:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\test\audio\audio_session_test.dart`

Lines 25–44 verbatim (occurrence at line 35):

```dart
import 'package:livekit_client/src/support/native.dart';
import 'package:livekit_client/src/support/native_audio.dart' as native_audio;
import 'package:livekit_client/src/support/webrtc_initialize_options.dart';
import 'package:livekit_client/src/track/options.dart' as track_options;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AudioManager.instance.resetForTest();
    Native.bypassVoiceProcessing = false;
  });

  native_audio.NativeAudioConfiguration resolveApplePolicy(
    AudioSessionOptions options, {
    bool preferSpeakerOutput = true,
    bool forceSpeakerOutput = false,
    bool automatic = true,
  }) => ResolvedAudioSessionPolicy(
    options: options,
```

> **Note the test imports `package:livekit_client/src/support/native.dart` directly** — i.e. it reaches into `src/`, which is exactly what an app would have to do too. See B.4.

Lines 845–877 verbatim (occurrences at 849, 854, 870):

```dart
  group('liveKitWebRTCInitializeOptions', () {
    test('includes Android audio configuration for Android startup', () {
      expect(
        liveKitWebRTCInitializeOptions(
          bypassVoiceProcessing: true,
          initialAudioSessionOptions: const AudioSessionOptions.mediaPlayback(),
          includeAndroidAudioConfiguration: true,
        ),
        {
          'bypassVoiceProcessing': true,
          'androidAudioConfiguration': {
            'manageAudioFocus': true,
            'androidAudioMode': 'normal',
            'androidAudioFocusMode': 'gain',
            'androidAudioStreamType': 'music',
            'androidAudioAttributesUsageType': 'media',
            'androidAudioAttributesContentType': 'unknown',
          },
        },
      );
    });

    test('omits Android audio configuration on non-Android startup', () {
      expect(
        liveKitWebRTCInitializeOptions(
          bypassVoiceProcessing: false,
          initialAudioSessionOptions: const AudioSessionOptions.mediaPlayback(),
          includeAndroidAudioConfiguration: false,
        ),
        isEmpty,
      );
    });
  });
```

## B.2 — What declares it, and its exact nature

**Declaring class:** `class Native`, at `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\support\native.dart` line 27:

```dart
// Method channel methods to call native code.
class Native {
```

**The member**, lines 37–38:

```dart
  @internal
  static bool bypassVoiceProcessing = false;
```

Facts, verbatim from the declaration:
- It is a **`static`** field on `Native` — a **process-global mutable singleton**, not per-`Room`, not per-track, not per-`AudioCaptureOptions`.
- Type: **`bool`** (non-nullable).
- Default value: **`false`**.
- It is **NOT `final`** and **NOT `const`** — it is freely reassignable at any time.
- It is annotated **`@internal`** (from `import 'package:meta/meta.dart';` at line 19 of `native.dart`). **This is a LOUD warning: it is declared as package-internal API.** Writing to it from an app triggers the `invalid_use_of_internal_member` analyzer diagnostic.
- `Native` has no constructor, no instance state relevant here; every other member is `static` too.

## B.3 — Exact effect on audio constraints / capture — the read path, traced

**The value is read in exactly ONE place in the entire package.**

**Read site:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\options.dart` **line 416**, inside `AudioCaptureOptions.toMediaConstraintsMap()` (lines 412–464). Verbatim of the branch it controls (lines 413–450):

```dart
  Map<String, dynamic> toMediaConstraintsMap() {
    final constraints = <String, dynamic>{};

    if (Native.bypassVoiceProcessing) {
      constraints['optional'] = <Map<String, dynamic>>[
        <String, dynamic>{'googEchoCancellation': false},
        <String, dynamic>{'googEchoCancellation2': false},
        <String, dynamic>{'googNoiseSuppression': false},
        <String, dynamic>{'googNoiseSuppression2': false},
        <String, dynamic>{'googAutoGainControl': false},
        <String, dynamic>{'googHighpassFilter': false},
        <String, dynamic>{'googTypingNoiseDetection': false},
        <String, dynamic>{'noiseSuppression': false},
        <String, dynamic>{'echoCancellation': false},
        <String, dynamic>{'autoGainControl': false},
        <String, dynamic>{'voiceIsolation': false},
        <String, dynamic>{'googDAEchoCancellation': false},
      ];
    } else {
      /// in we platform it's not possible to provide optional and mandatory parameters.
      /// deviceId is a mandatory parameter
      if (!kIsWeb || (kIsWeb && deviceId == null)) {
        constraints['optional'] = <Map<String, dynamic>>[
          <String, dynamic>{'echoCancellation': echoCancellation},
          <String, dynamic>{'noiseSuppression': noiseSuppression},
          <String, dynamic>{'autoGainControl': autoGainControl},
          <String, dynamic>{'voiceIsolation': noiseSuppression},
          <String, dynamic>{'googDAEchoCancellation': echoCancellation},
          <String, dynamic>{'googEchoCancellation': echoCancellation},
          <String, dynamic>{'googEchoCancellation2': echoCancellation},
          <String, dynamic>{'googNoiseSuppression': noiseSuppression},
          <String, dynamic>{'googNoiseSuppression2': noiseSuppression},
          <String, dynamic>{'googAutoGainControl': autoGainControl},
          <String, dynamic>{'googHighpassFilter': highPassFilter},
          <String, dynamic>{'googTypingNoiseDetection': typingNoiseDetection},
        ];
      }
    }
```

**The effect, stated strictly from this code:**

When `Native.bypassVoiceProcessing == true`, `AudioCaptureOptions.toMediaConstraintsMap()` emits a **fixed** `'optional'` list of **12 constraints, every one hard-coded `false`**, and **entirely ignores the instance's own `echoCancellation`, `noiseSuppression`, `autoGainControl`, `highPassFilter`, `typingNoiseDetection`, and `voiceIsolation` fields.**

> **THIS IS THE KEY, LOUD FINDING: `Native.bypassVoiceProcessing = true` is a GLOBAL OVERRIDE that silently DEFEATS whatever you pass to `AudioCaptureOptions`.** `const AudioCaptureOptions(echoCancellation: true)` produces `{'echoCancellation': false, ...}` when the flag is set. There is no per-track escape hatch and no warning logged.

Also note the bypass branch **has no `kIsWeb` guard** — unlike the else-branch (line 434), it always writes `'optional'`. But since the only writer (`LiveKitClient.initialize`) is behind `if (lkPlatformIsMobile())` (line 55), the flag can only ever become `true` on mobile in practice — unless an app writes the static field directly.

**Then the constraint map flows here:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\src\track\local\local.dart` lines 248–258:

```dart
  static Future<rtc.MediaStream> createStream(
    LocalTrackOptions options,
  ) async {
    final constraints = <String, dynamic>{
      'audio': options is AudioCaptureOptions
          ? options.toMediaConstraintsMap()
          : options is ScreenShareCaptureOptions
          ? (options).captureScreenAudio
          : false,
      'video': options is VideoCaptureOptions ? options.toMediaConstraintsMap() : false,
    };
```

…i.e. it becomes the `'audio'` value of the `getUserMedia` constraints.

**Second, independent effect — the WebRTC init option.** The same boolean value (the *argument*, not the static field) is separately funnelled into `rtc.WebRTC.initialize` via `liveKitWebRTCInitializeOptions`:

`...\lib\src\livekit.dart` lines 59–66:

```dart
      Native.bypassVoiceProcessing = bypassVoiceProcessing;
      await rtc.WebRTC.initialize(
        options: liveKitWebRTCInitializeOptions(
          bypassVoiceProcessing: bypassVoiceProcessing,
          initialAudioSessionOptions: initialAudioSessionOptions,
          includeAndroidAudioConfiguration: lkPlatformIs(PlatformType.android),
        ),
      );
```

`...\lib\src\support\webrtc_initialize_options.dart` line 26:

```dart
  if (bypassVoiceProcessing) 'bypassVoiceProcessing': bypassVoiceProcessing,
```

> **These are TWO SEPARATE mechanisms driven from one call.** The static field only affects constraint generation inside this package; the map key is consumed by the **flutter_webrtc** package's native plugin (which sets up the ADM without the hardware/software voice-processing path). **Setting `Native.bypassVoiceProcessing = true` by hand does NOT reach `WebRTC.initialize` — you get only half the behavior.** No code in this package root reads the `'bypassVoiceProcessing'` map key; the consumer lives in flutter_webrtc, outside the verified tree.

## B.4 — How an application sets it

**The intended, supported way** (from the doc comment at `...\lib\src\livekit.dart` lines 28–33 and the example at `...\example\lib\main.dart` lines 23–28) — the app writes:

```dart
await LiveKitClient.initialize(
  bypassVoiceProcessing: true,
);
```

or, as the shipped example literally shows:

```dart
await LiveKitClient.initialize(
  bypassVoiceProcessing: lkPlatformIsMobile(),
);
```

**Direct assignment is also syntactically possible** (this is what the test does at `audio_session_test.dart:35`):

```dart
import 'package:livekit_client/src/support/native.dart';
Native.bypassVoiceProcessing = true;
```

…but see B.5 — this requires importing a `src/` path, and the field is `@internal`.

**Ordering constraints, as readable from the code:**

1. **`LiveKitClient.initialize()` must be called before WebRTC initializes**, per the doc comment at lines 28–33: *"call once at startup to enable [bypassVoiceProcessing] before connecting … Otherwise WebRTC initializes lazily with defaults."* The `rtc.WebRTC.initialize` call on line 60 is the one-shot.
2. **It is gated on mobile: `if (lkPlatformIsMobile())` at line 55.** **LOUD: on Web, Windows, macOS, and Linux, `LiveKitClient.initialize(bypassVoiceProcessing: true)` is a COMPLETE NO-OP** — the static field is never assigned and `WebRTC.initialize` is never called. `lkPlatformIsMobile` is imported at line 20 from `support/platform.dart`.
3. For the **constraint-generation** half specifically, the field only needs to be `true` at the moment `AudioCaptureOptions.toMediaConstraintsMap()` runs — i.e. **before the local audio track is created** (`LocalTrack.createStream`, `local.dart:248`). It is read fresh on every call, so it is not latched at construction of `AudioCaptureOptions`; a `const AudioCaptureOptions()` created earlier still picks up a later flag change. **The flag is read at capture time, not at options-construction time.**

## B.5 — Is `Native` exported from `package:livekit_client/livekit_client.dart`?

### **NO. `Native` IS NOT EXPORTED FROM THE PUBLIC LIBRARY.**

**Checked file:** `C:\Users\Liu_F\AppData\Local\Pub\Cache\hosted\pub.dev\livekit_client-2.12.0\lib\livekit_client.dart` (97 lines, read in full).

It contains **77 `export` directives (lines 17–92)**. **`src/support/native.dart` is NOT among them.** The only `support/` export is:

```dart
export 'src/support/platform.dart';          // line 58
```

For completeness, the neighbouring exports that *do* exist and that one might mistake for it:

```dart
export 'src/livekit.dart';                   // line 35   <-- gives you LiveKitClient.initialize
export 'src/support/platform.dart';          // line 58
export 'src/audio/audio_manager.dart';       // line 51
export 'src/audio/audio_session.dart';       // line 53
export 'src/audio/audio_processing_state.dart'; // line 59
export 'src/track/options.dart';             // line 64   <-- gives you AudioCaptureOptions + AudioProcessingMode
export 'src/track/processor.dart';           // line 65
export 'src/track/processor_native.dart' if (dart.library.js_interop) 'src/track/processor_web.dart'; // line 66
```

**Re-export chain check:** a grep for `^export` across the whole `lib\src\` tree returned only **9** matches, and **none of them is `native.dart`**:

```
...\lib\src\audio\audio_manager.dart:32:  export 'audio_engine_availability.dart';
...\lib\src\audio\audio_manager.dart:33:  export 'microphone_mute_mode.dart';
...\lib\src\audio\audio_session.dart:15:  export '../support/value_or_absent.dart';
...\lib\src\proto\livekit_metrics.pb.dart:19: export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;
...\lib\src\proto\livekit_metrics.pb.dart:21: export 'livekit_metrics.pbenum.dart';
...\lib\src\proto\livekit_models.pb.dart:22:  export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;
...\lib\src\proto\livekit_models.pb.dart:24:  export 'livekit_models.pbenum.dart';
...\lib\src\proto\livekit_rtc.pb.dart:21:    export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;
...\lib\src\proto\livekit_rtc.pb.dart:23:    export 'livekit_rtc.pbenum.dart';
```

**Also confirmed:** grep for `export .*native` across `lib\` returns exactly **one** hit, and it is the *processor* file, not `support/native.dart`:

```
...\lib\livekit_client.dart:66: export 'src/track/processor_native.dart' if (dart.library.js_interop) 'src/track/processor_web.dart';
```

**Conclusion, loudly:** **`import 'package:livekit_client/livekit_client.dart';` does NOT give you `Native`.** To touch `Native.bypassVoiceProcessing` an app must do what the test does — reach into the private `src/` tree:

```dart
import 'package:livekit_client/src/support/native.dart';
```

which (a) violates the `src/`-is-private convention and (b) hits the `@internal` annotation on the field. **The only sanctioned way to set this is `await LiveKitClient.initialize(bypassVoiceProcessing: true);`, and `LiveKitClient` IS exported — `lib\livekit_client.dart` line 35: `export 'src/livekit.dart';`.**

---

# Consolidated "loud" list of surprises

1. **`Native.bypassVoiceProcessing = true` silently OVERRIDES every audio-processing field on `AudioCaptureOptions`** — all 12 emitted constraints become hard-coded `false` (`options.dart:416–430`).
2. **`Native` is NOT exported from `package:livekit_client/livekit_client.dart`** and the field is `@internal` (`native.dart:37–38`). Use `LiveKitClient.initialize(bypassVoiceProcessing: …)`.
3. **`LiveKitClient.initialize(bypassVoiceProcessing: true)` is a NO-OP on Web and desktop** — gated by `if (lkPlatformIsMobile())` at `livekit.dart:55`.
4. **`voiceIsolation` is a dead field for constraint purposes** — line 439 emits `'voiceIsolation': noiseSuppression`, not `voiceIsolation`.
5. **`highPassFilter` defaults to `false`**, unlike every other boolean (`options.dart:387`).
6. **The four `*Mode` fields never reach `toMediaConstraintsMap()`** — they go only through `toMap()` → native method channel.
7. **On Web with a non-null `deviceId`, ALL audio-processing constraints are dropped** (guard at `options.dart:434`).
8. **`AudioPublishOptions` lives in `lib\src\options.dart`, NOT `lib\src\track\options.dart`.**
9. **`copyWith` has an extra `processing` parameter that silently outranks the individual boolean/mode arguments** (`options.dart:476`, 484–491).
10. **`AudioCaptureOptions` has no `.from()` constructor, no `==`/`hashCode`/`toString`.**
11. **`bypassVoiceProcessing` appears in ZERO native (.kt/.swift/.m/.h/.podspec) files in this package** — the map key is consumed by flutter_webrtc, outside this tree.
