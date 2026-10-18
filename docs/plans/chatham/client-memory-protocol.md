# 隐名之约 · 圈子记忆的 WS 协议(客户端假设)

> 受 Chatham House 规则启发 · 非官方。与 Chatham House 无隶属。
> 实现:`app/lib/src/anonym/anonym_controller.dart`(解析 / 发送 / 权限)、`app/lib/src/anonym/anonym_memory.dart`(「圈子记忆」页)。
> 对端:`server/anonym-agent/core/memory.mjs`(`mem.list()` / `mem.retract()`);语义见 `server/anonym-agent/INTERFACE.md` §「v1 愿景」与 §「补充形状」。
> 本文是**客户端的假设**,INTERFACE.md 的 WS 表里还没有这几条;服务器落地时请按此对齐,或告诉客户端改。

## 客户端 → 服务器

| msg | 字段 | 何时发 |
|---|---|---|
| `anon_mem_list` | `circleId` | 打开「圈子记忆」页、下拉刷新、出错后点「再试一次」 |
| `anon_mem_retract` | `circleId, itemId` | 用户在确认框里点「撤回」之后 |

- 两条都**不要求在房间里**:圈子记忆也能从首页长按圈子 →「圈子记忆」打开(人不在房里)。客户端只在**注册的 v2 圈**里显示入口;圈主和普通成员都能看。
- 同一条撤回在等确认时不会重发。

## 服务器 → 客户端

| msg | 字段 | 客户端处理 |
|---|---|---|
| `anon_mem` | `circleId, items:[…]` | 整份替换本地列表。既是 `anon_mem_list` 的回复,也可在撤回后**重发整份**作为确认 |
| `anon_mem_retracted` | `circleId, itemId` | (可选)把该条就地换成墓碑 |
| `anon_error` | `code` | 若此刻在等记忆的回复(列表或撤回),错误归到记忆页;撤回中的条目恢复原状 |

`items[]` 每条(= `mem.list()` 的输出,外加两个可选权限字段):

```js
{ id, circleId, text, kind: 'idea'|'decision'|'todo'|'fact', sid, releasedAt, approvals,
  canRetract?: boolean,      // 服务器替本人算好的「我能撤回」
  approverIds?: string[] }   // 放行人 user id;只用来判断权限,客户端不显示
// 墓碑:
{ id, retracted: true }      // 不含 text;就算带了,客户端也丢弃
```

解析是防御式的:
- `id` 可以是字符串或整数;重复 id 只取第一条;没有 `text` 的非墓碑条目跳过。
- `kind` 不认识 → 显示为「其他」。
- `releasedAt`:毫秒时间戳(数字或数字字符串)或 ISO 8601 字符串;小于 1e11 的数字按**秒**处理。
- `approvals` = 放行签名数 N,显示为「去名 · 经 N 人放行」;缺省时显示「去名 · 经大家放行」。
- 任何说话人相关字段(就算服务器误发)客户端都不读、不显示。

## 撤回权限(客户端显示「撤回」按钮的条件)

满足任一即显示:
1. 本人是该圈**已确认的圈主**;
2. 条目 `canRetract === true`;
3. 条目 `approverIds` 含本人 user id。

墓碑永不显示。**服务器仍须自行鉴权**——客户端只是不给没权限的人按钮。

## 非乐观

点了撤回后,条目保持原样并显示「撤回中…」,直到收到 `anon_mem_retracted{itemId}` 或一份把它标成墓碑 / 去掉的 `anon_mem`;收到 `anon_error` 则恢复可撤回。

## 生命周期

- 圈子记忆是服务器持久化数据,**不随会话销毁**:`anon_ended`、`anon_state{active:false}` 都不清它。
- 离开房间、换圈时清掉本机缓存;下次打开页面重新 `anon_mem_list`。

## 待服务器确认

1. `anon_error` 不带上下文:能否在记忆相关错误里回带 `{circleId, op:'mem_list'|'mem_retract', itemId?}`,让客户端不靠「此刻在等什么」去猜?建议 code:`not_member`、`not_registered`、`not_approver`、`no_such_item`、`already_retracted`。
2. 撤回确认:发 `anon_mem_retracted` 还是重发整份 `anon_mem`?两者客户端都接受;建议前者 + 广播给圈内其他在线成员(他们的页面也会就地变墓碑)。
3. 权限字段:`canRetract` 由服务器按请求者算(推荐,不泄露放行人名单)还是下发 `approverIds`?后者会把「谁放行了哪条」告诉所有成员——这本身可能是一种重识别线索,**建议只发 `canRetract`**。
4. 是否允许不在房间里的成员发 `anon_mem_list`(客户端假设允许,入口在首页长按也有)。
5. 列表排序:客户端按服务器给的顺序显示,建议 `releasedAt` 降序;条目很多时是否需要分页(`before` / `limit`)。
