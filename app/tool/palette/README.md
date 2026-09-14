# 名画配色方案对比(离线设计工具)

给产品负责人选色用。**本目录不参与 app 构建**,也没有改动 `app/lib/` 下任何文件
(包括 `tokens.dart`),没有新增任何依赖。

## 怎么跑

```powershell
cd D:\Projects\Lares\app

# 1. 实测对比度 + 色盲可分性(纯 Dart,秒出)
dart run tool/palette/contrast_check.dart
dart run tool/palette/contrast_check.dart --md > tool/palette/CONTRAST.md

# 2. 求解状态色(色相锁死,只解明度/彩度)
dart run tool/palette/optimize_status.dart

# 3. 渲染界面截图(约 4 分钟,输出 11 张 PNG)
flutter test tool/palette/render_test.dart
```

> `render_test.dart` 虽以 `_test.dart` 结尾,但它**不是回归测试**,而是借
> `flutter test` 的 headless 引擎做离线渲染的脚本。它不在 `test/` 目录下,
> 所以 `flutter test`(默认只扫 `test/`)不会捡到它。实测既有 496 项测试全绿。

## 文件

| 文件 | 作用 |
|---|---|
| `palettes.dart` | 5 套 token 全集(4 套名画 + 现有基线对照) |
| `contrast_check.dart` | WCAG 对比度 + CIEDE2000 + 色盲模拟,带自检 |
| `optimize_status.dart` | 状态色求解器(带约束的随机重启爬山) |
| `palette_theme.dart` | 由 Palette 构建 ThemeData,结构对照 `lib/src/theme/theme.dart` |
| `scenes.dart` | 两个场景:房间界面 / 聊天面板 |
| `fonts.dart` | 在测试环境加载真中文字体 + Material Icons |
| `render_test.dart` | 渲染并落盘 PNG |
| `CONTRAST.md` | 生成的实测数据表 |

## 三个踩过的坑(改这里之前先读)

1. **`toImage()` 必须包在 `tester.runAsync()` 里。**
   `testWidgets` 跑在 fake async 时钟下,而光栅化要等引擎线程真干完活;
   假时钟永远推不到那一刻,于是进程**静默卡死** —— 不报错、不超时、CPU 也不高。
   症状极具迷惑性:第一张图能出来,第二张必挂。

2. **别在渲染文本里放 emoji。**
   headless 环境下 Windows 字体没有彩色 emoji 字形,Skia 的字体回退查找会
   直接卡死整个测试进程。真机无此问题,但对比图也不需要 emoji。

3. **必须显式加载字体。**
   `flutter_test` 默认字体是 Ahem —— 所有字形都是实心方块。
   不加载真字体,截出来的是一屏黑方块。

## 忠实度声明(别把这些图当像素级真机截图)

- `SpeakingRipple` 是**直接复用**的真组件,它本来就接受 `color` 参数。
- `AvatarOrb` / `ChatPanel` **无法**直接复用:前者从 `Member.status.color` 取色,
  而 `MemberStatus` 的颜色是写死在枚举上的 `LaresColors` 编译期常量;
  后者依赖 `ChatService` / `BlockStore` 一整套运行时协作者。
  因此按其真实布局重建,尺寸/圆角/间距/字阶全部引用 `LaresRadii` / `LaresSpacing`。
- 五张图结构完全相同,差异**只**来自 token,所以横向对比是成立的。
