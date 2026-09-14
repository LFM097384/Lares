### 余烬(现有基线) — 现有 app/lib/src/theme/tokens.dart

| token | hex |
|---|---|
| bg | `#121016` |
| surface | `#1C1922` |
| surfaceHigh | `#26222E` |
| brand | `#FF8A5C` |
| onBrand | `#1A120C` |
| textPrimary | `#F2EEE9` |
| textSecondary | `#9A93A3` |
| statusFree | `#6FD08C` |
| statusBusy | `#E8B45A` |
| statusEars | `#6FA8D0` |
| statusAway | `#6E6878` |

| 实测对比度 | 值 | 门槛 | 结论 |
|---|---|---|---|
| 正文 textPrimary vs bg | **16.36:1** | ≥4.5 | 通过 |
| 次要 textSecondary vs bg | **6.37:1** | ≥3.0 | 通过 |
| 正文 vs surface | 15.01:1 | ≥4.5 | 通过 |
| 次要 vs surface | 5.84:1 | ≥3.0 | 通过 |
| 正文 vs surfaceHigh | 13.46:1 | ≥4.5 | 通过 |
| 品牌色 vs bg | 8.14:1 | ≥3.0 | 通过 |
| 主按钮文字 onBrand vs brand | 7.96:1 | ≥4.5 | 通过 |

| 状态色 vs bg(环可见性,≥3.0) | 值 |
|---|---|
| free 随时聊 `#6FD08C` | 9.97:1 |
| busy 在忙 `#E8B45A` | 9.99:1 |
| ears 耳朵在 `#6FA8D0` | 7.37:1 |
| away 有事先走 `#6E6878` | 3.52:1 |

| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |
|---|---|---|---|---|
| free 随时聊 ↔ busy 在忙 | 33.58 | 8.46 | 13.43 | 41.86 |
| free 随时聊 ↔ ears 耳朵在 | 37.70 | 41.11 | 39.57 | 7.41 |
| free 随时聊 ↔ away 有事先走 | 41.93 | 40.54 | 35.31 | 34.67 |
| busy 在忙 ↔ ears 耳朵在 | 46.21 | 48.48 | 53.36 | 42.41 |
| busy 在忙 ↔ away 有事先走 | 42.96 | 44.02 | 45.46 | 33.38 |
| ears 耳朵在 ↔ away 有事先走 | 29.46 | 23.25 | 22.32 | 29.26 |

### 夜巡 — 伦勃朗《夜巡》(1642),阿姆斯特丹国立博物馆

| token | hex |
|---|---|
| bg | `#141109` |
| surface | `#1E1A10` |
| surfaceHigh | `#2B2417` |
| brand | `#EFAE46` |
| onBrand | `#1B1204` |
| textPrimary | `#F7EDD8` |
| textSecondary | `#B6A98D` |
| statusFree | `#B9CF73` |
| statusBusy | `#E0824D` |
| statusEars | `#8FBDDD` |
| statusAway | `#8E8371` |

| 实测对比度 | 值 | 门槛 | 结论 |
|---|---|---|---|
| 正文 textPrimary vs bg | **16.21:1** | ≥4.5 | 通过 |
| 次要 textSecondary vs bg | **8.12:1** | ≥3.0 | 通过 |
| 正文 vs surface | 14.92:1 | ≥4.5 | 通过 |
| 次要 vs surface | 7.48:1 | ≥3.0 | 通过 |
| 正文 vs surfaceHigh | 13.21:1 | ≥4.5 | 通过 |
| 品牌色 vs bg | 9.71:1 | ≥3.0 | 通过 |
| 主按钮文字 onBrand vs brand | 9.53:1 | ≥4.5 | 通过 |

| 状态色 vs bg(环可见性,≥3.0) | 值 |
|---|---|
| free 随时聊 `#B9CF73` | 10.98:1 |
| busy 在忙 `#E0824D` | 6.71:1 |
| ears 耳朵在 `#8FBDDD` | 9.42:1 |
| away 有事先走 `#8E8371` | 5.06:1 |

| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |
|---|---|---|---|---|
| free 随时聊 ↔ busy 在忙 | 38.52 | 14.37 | 9.00 | 28.67 |
| free 随时聊 ↔ ears 耳朵在 | 41.40 | 43.13 | 45.02 | 16.21 |
| free 随时聊 ↔ away 有事先走 | 27.19 | 24.91 | 23.10 | 21.47 |
| busy 在忙 ↔ ears 耳朵在 | 41.77 | 42.98 | 47.32 | 43.71 |
| busy 在忙 ↔ away 有事先走 | 21.63 | 14.82 | 19.05 | 20.05 |
| ears 耳朵在 ↔ away 有事先走 | 29.82 | 32.14 | 33.66 | 31.52 |

### 星夜 — 梵高《罗讷河上的星夜》(1888),奥赛美术馆

| token | hex |
|---|---|
| bg | `#0B1124` |
| surface | `#141C33` |
| surfaceHigh | `#1F2946` |
| brand | `#F5C542` |
| onBrand | `#161003` |
| textPrimary | `#EEF2FA` |
| textSecondary | `#A3B2D0` |
| statusFree | `#75D8B5` |
| statusBusy | `#F09A5A` |
| statusEars | `#81A8E4` |
| statusAway | `#757F9E` |

| 实测对比度 | 值 | 门槛 | 结论 |
|---|---|---|---|
| 正文 textPrimary vs bg | **16.71:1** | ≥4.5 | 通过 |
| 次要 textSecondary vs bg | **8.78:1** | ≥3.0 | 通过 |
| 正文 vs surface | 15.05:1 | ≥4.5 | 通过 |
| 次要 vs surface | 7.91:1 | ≥3.0 | 通过 |
| 正文 vs surfaceHigh | 12.79:1 | ≥4.5 | 通过 |
| 品牌色 vs bg | 11.56:1 | ≥3.0 | 通过 |
| 主按钮文字 onBrand vs brand | 11.67:1 | ≥4.5 | 通过 |

| 状态色 vs bg(环可见性,≥3.0) | 值 |
|---|---|
| free 随时聊 `#75D8B5` | 10.94:1 |
| busy 在忙 `#F09A5A` | 8.46:1 |
| ears 耳朵在 `#81A8E4` | 7.73:1 |
| away 有事先走 `#757F9E` | 4.72:1 |

| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |
|---|---|---|---|---|
| free 随时聊 ↔ busy 在忙 | 44.44 | 17.01 | 21.64 | 46.84 |
| free 随时聊 ↔ ears 耳朵在 | 33.84 | 35.16 | 28.91 | 9.16 |
| free 随时聊 ↔ away 有事先走 | 36.19 | 34.64 | 28.09 | 25.10 |
| busy 在忙 ↔ ears 耳朵在 | 42.62 | 50.82 | 55.85 | 43.12 |
| busy 在忙 ↔ away 有事先走 | 38.73 | 43.51 | 47.71 | 37.04 |
| ears 耳朵在 ↔ away 有事先走 | 16.12 | 15.27 | 14.81 | 16.45 |

### 珍珠 — 维梅尔《戴珍珠耳环的少女》(1665),莫瑞泰斯皇家美术馆

| token | hex |
|---|---|
| bg | `#0A0A0D` |
| surface | `#141419` |
| surfaceHigh | `#1F1F27` |
| brand | `#E9AE4A` |
| onBrand | `#181104` |
| textPrimary | `#F1EBE1` |
| textSecondary | `#A09CA8` |
| statusFree | `#80CAAC` |
| statusBusy | `#DC7F68` |
| statusEars | `#739EE0` |
| statusAway | `#7E7A88` |

| 实测对比度 | 值 | 门槛 | 结论 |
|---|---|---|---|
| 正文 textPrimary vs bg | **16.67:1** | ≥4.5 | 通过 |
| 次要 textSecondary vs bg | **7.36:1** | ≥3.0 | 通过 |
| 正文 vs surface | 15.48:1 | ≥4.5 | 通过 |
| 次要 vs surface | 6.83:1 | ≥3.0 | 通过 |
| 正文 vs surfaceHigh | 13.80:1 | ≥4.5 | 通过 |
| 品牌色 vs bg | 10.00:1 | ≥3.0 | 通过 |
| 主按钮文字 onBrand vs brand | 9.47:1 | ≥4.5 | 通过 |

| 状态色 vs bg(环可见性,≥3.0) | 值 |
|---|---|
| free 随时聊 `#80CAAC` | 10.32:1 |
| busy 在忙 `#DC7F68` | 6.85:1 |
| ears 耳朵在 `#739EE0` | 7.25:1 |
| away 有事先走 `#7E7A88` | 4.73:1 |

| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |
|---|---|---|---|---|
| free 随时聊 ↔ busy 在忙 | 47.68 | 15.54 | 17.66 | 45.04 |
| free 随时聊 ↔ ears 耳朵在 | 33.62 | 35.46 | 29.97 | 9.02 |
| free 随时聊 ↔ away 有事先走 | 34.46 | 27.07 | 21.84 | 27.11 |
| busy 在忙 ↔ ears 耳朵在 | 39.07 | 44.20 | 50.77 | 44.85 |
| busy 在忙 ↔ away 有事先走 | 26.78 | 26.86 | 32.24 | 25.61 |
| ears 耳朵在 ↔ away 有事先走 | 22.42 | 19.72 | 19.68 | 22.11 |

### 狮守 — 亨利·卢梭《沉睡的吉普赛人》(1897),纽约现代艺术博物馆

| token | hex |
|---|---|
| bg | `#0A1417` |
| surface | `#121F23` |
| surfaceHigh | `#1C2C31` |
| brand | `#EFAC66` |
| onBrand | `#16110A` |
| textPrimary | `#EBF1EF` |
| textSecondary | `#9AAFAD` |
| statusFree | `#76CC9E` |
| statusBusy | `#E08A6E` |
| statusEars | `#75A0CC` |
| statusAway | `#7C8A90` |

| 实测对比度 | 值 | 门槛 | 结论 |
|---|---|---|---|
| 正文 textPrimary vs bg | **16.32:1** | ≥4.5 | 通过 |
| 次要 textSecondary vs bg | **8.09:1** | ≥3.0 | 通过 |
| 正文 vs surface | 14.74:1 | ≥4.5 | 通过 |
| 次要 vs surface | 7.31:1 | ≥3.0 | 通过 |
| 正文 vs surfaceHigh | 12.63:1 | ≥4.5 | 通过 |
| 品牌色 vs bg | 9.56:1 | ≥3.0 | 通过 |
| 主按钮文字 onBrand vs brand | 9.62:1 | ≥4.5 | 通过 |

| 状态色 vs bg(环可见性,≥3.0) | 值 |
|---|---|
| free 随时聊 `#76CC9E` | 9.69:1 |
| busy 在忙 `#E08A6E` | 7.14:1 |
| ears 耳朵在 `#75A0CC` | 6.80:1 |
| away 有事先走 `#7C8A90` | 5.24:1 |

| 状态色两两色差 ΔE2000 | 正常 | 红色盲 | 绿色盲 | 蓝色盲 |
|---|---|---|---|---|
| free 随时聊 ↔ busy 在忙 | 47.79 | 11.15 | 12.52 | 44.68 |
| free 随时聊 ↔ ears 耳朵在 | 33.99 | 36.91 | 33.25 | 9.08 |
| free 随时聊 ↔ away 有事先走 | 27.61 | 25.37 | 21.27 | 19.91 |
| busy 在忙 ↔ ears 耳朵在 | 38.00 | 39.74 | 46.19 | 42.42 |
| busy 在忙 ↔ away 有事先走 | 31.78 | 23.88 | 30.04 | 33.45 |
| ears 耳朵在 ↔ away 有事先走 | 14.54 | 15.71 | 15.83 | 12.69 |

══════════════════════════════════════════
未通过项(1):
  ✗ [余烬(现有基线)] free 随时聊 ↔ ears 耳朵在 蓝色盲 ΔE=7.41 < 8.0
Running build hooks...Running build hooks...
