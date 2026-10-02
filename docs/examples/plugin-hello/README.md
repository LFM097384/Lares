# plugin-hello —— Lares 插件示例

一个最小但完整的插件,同时演示两种形态(完整说明见 [`docs/plugin-api.md`](../../plugin-api.md)):

- **网页小程序**(`index.html` + `app.js`):显示圈子和在房成员、一个所有人共享的计数器、发一条聊天、在本机记住昵称、实时显示进出房和字幕。纯静态,不需要构建。
- **服务端插件**(`webhook-receiver.mjs`):接收签名的 webhook,校验后打印事件。

| 文件 | 作用 |
|---|---|
| `manifest.json` | 插件描述,安装时用 |
| `index.html` `app.js` | 网页小程序,经 `window.lares` 桥工作;在普通浏览器打开会显示「请在 Lares 里打开」 |
| `webhook-receiver.mjs` | Node ≥18 webhook 接收端,无依赖 |

## 1. 托管网页

把 `index.html`、`app.js`(以及想用 URL 安装的话,`manifest.json`)放到任意 **https** 静态托管上:GitHub Pages、Cloudflare Pages、对象存储都行。然后把 `manifest.json` 里的 URL 改成你自己的:

- `entry.url` → `index.html` 的地址
- `homepage` → 你的介绍页(可删)
- `webhook.url` → `webhook-receiver.mjs` 对外的地址;不需要服务端部分就**整个删掉 `webhook` 字段**
- `id` → 换成你自己的反向域名,如 `io.github.yourname.hello`(`lares.` 开头保留)

manifest 只允许这些顶层字段:`id name version description author homepage entry permissions webhook settingsSchema`,多一个都会被拒绝(`bad_manifest`)。

本地调试:在服务器上设 `LARES_PLUGIN_ALLOW_PRIVATE=1`,`entry.url` / `webhook.url` 就可以是 `http://192.168.x.x:…` 这样的内网地址。**生产别开。**

```powershell
# 本地起一个静态服务器(任选其一)
npx --yes http-server docs/examples/plugin-hello -p 8080
python -m http.server 8080 -d docs/examples/plugin-hello
```

## 2. 安装

只有圈主能装。在 App 的「圈子设置 → 插件」里二选一:

- **从 URL 安装**:填 `https://你的域名/plugin-hello/manifest.json`。服务器去抓(https、≤16 KB、5 秒超时、不跟随重定向、不能是内网地址)。
- **粘贴 manifest**:把 `manifest.json` 的内容整段贴进去。

对应的信令消息分别是 `{t:'plugin_install', circleId, ownerKey, manifestUrl}` 和 `{…, manifest}`。

因为 manifest 带了 `webhook`,安装回执里会一次性给出插件 token(`plg_…`)和 webhook 密钥(`whsec_…`)。**把密钥抄下来**,它不会再显示;token 另外会经签名的 `installed` webhook 自动送到你的接收端。

成员第一次在房间里打开插件时,App 会弹同意页列出权限;权限集变了会重新问。

## 3. 跑 webhook 接收端

```powershell
$env:LARES_WEBHOOK_SECRET = 'whsec_…'   # 安装时拿到的密钥
$env:PORT = '8788'                       # 可选,默认 8788
node docs/examples/plugin-hello/webhook-receiver.mjs
```

它接受任意路径的 POST,校验 `X-Lares-Signature`(HMAC-SHA256,时间戳 ±300 秒),对的回 200 并打印事件,不对回 401。生产环境需要放到 https 反代后面。

## 4. 权限说明

| 权限 | 本示例用它做什么 |
|---|---|
| `circle:read` | `getCircle()` 显示圈子 id 与是否端到端加密 |
| `members:read` | `getMembers()` / `getSelf()` 列成员;`join` `leave` 事件;webhook 的 `join` `leave` |
| `chat:send` | 「说你好」按钮,`sendChat()` |
| `state:read` | `getState()` 读计数器,`state` 事件;webhook 的 `plugin_state` |
| `state:write` | `setState({counter})` —— 让**成员**能改共享计数器 |
| `storage` | `storage.get/set('nickname')`,只存在本机 |
| `captions:read` | `caption` 事件,把定稿字幕写进事件日志 |

注意:共享状态(这里的计数器)存在服务器上、**服务器可见**,端到端加密的圈子也一样。
