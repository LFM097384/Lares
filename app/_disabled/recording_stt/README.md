# 暂时停用:本地离线语音识别(sherpa-onnx)

这两个文件**不参与编译**。它们被挪出 `lib/` 和 `test/`,不是被删除 ——
代码是完整的、有测试的,只是当前不进构建产物。

## 为什么挪出来

录音功能整体不开放(`LaresConfig.recordingEnabled` 默认 false)。
Dart 侧的 tree-shaking 已经把 `recording/` 下 12 个文件里的 11 个剔除干净,
**但 tree-shaking 对原生库完全无效** —— 原生库由平台构建链接,不经 Dart 编译器。

实测(二进制符号扫描)证据:关闭录音的默认 Windows 构建里,仍然分发了

| 文件 | 体积 |
|---|---|
| `onnxruntime.dll` | 17 MB |
| `sherpa-onnx-c-api.dll` | 4.4 MB |

iOS 上对应的是一个 `.xcframework` 被无条件打进 app bundle。两个后果:

1. 用户白白多下载 22 MB,换一个点不开的功能;
2. 一个「小圈子语音房」App 的包里带着完整的离线语音识别引擎,
   对 App Store 审核的 **2.3.1(hidden/dormant features)** 是不利叙事。

## 文件

| 文件 | 原位置 |
|---|---|
| `stt_sherpa.dart` | `lib/src/recording/stt_sherpa.dart` |
| `recording_stt_test.dart` | `test/recording_stt_test.dart` |

## 恢复步骤

1. `app/pubspec.yaml` 里把依赖加回来:`sherpa_onnx: ^1.13.8`
2. 两个文件挪回上表中的原位置
3. `flutter pub get`
4. 确认 `stt_registry.dart` 能挑到这个后端

> 移走时 `lib/` 下对 `stt_sherpa.dart` 的引用是**零** —— 原作者刻意做了分层,
> `stt_backend.dart` 和 `stt_registry.dart` 都不 import 具体后端。
> 所以挪走不牵连任何代码,挪回来也一样。

## 模型文件

模型(约 228 MB)从来不在仓库里,是运行时按需下载的。本次改动与它无关。
