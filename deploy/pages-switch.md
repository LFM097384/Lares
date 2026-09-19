# docs.laresapp.org 部署方式切换:/docs 目录 → GitHub Actions

> **为什么这份文档在 `deploy/` 而不是 `docs/`**
>
> 任务里原本要求放 `docs/DEPLOY-SWITCH.md`。实际检查了 `docs/_config.yml` 的
> `exclude` 列表:
>
> ```yaml
> exclude:
>   - app-store/
>   - research/
>   - design/
>   - plans/
>   - compliance/
>   - available-protocol.md
>   - recording-consent-protocol.md
>   - l10n-guide.md
> ```
>
> 这是一份**白名单式的显式清单**,不带通配符。`DEPLOY-SWITCH.md` 不在其中,
> Jekyll 会把它渲染并发布到 `https://docs.laresapp.org/DEPLOY-SWITCH` ——
> 一份写着「怎么改仓库设置、怎么回滚」的运维文档出现在审核员可能访问的站点上,
> 不合适。放到 `deploy/` 下与 `ios-ci.md` 作伴,既不会被 Jekyll 碰到,
> 也不会被未来的 Astro 站(只发布 `site/`)带出去。

---

## 一句话

站点内容从 `docs/`(Jekyll)换成 `site/`(Astro),部署方式从「Deploy from a
branch」换成「GitHub Actions」。**切换动作本身有一步只能人工做**,
而且做之前一定要先让 workflow 跑通。

## ⚠️ 这件事为什么要小心

`docs.laresapp.org` 上这四个 URL 已经填进了 App Store Connect,审核员会直接点:

| URL | 用途 |
|---|---|
| `https://docs.laresapp.org/` | 站点首页 |
| `https://docs.laresapp.org/privacy` | 隐私政策(App 隐私页必填) |
| `https://docs.laresapp.org/terms` | 使用条款 |
| `https://docs.laresapp.org/support` | 技术支持 URL(必填) |

审核期间任何一个打不开,轻则 Metadata Rejected 重新排队,重则影响整轮审核。
**所以宁可慢,不可断。**

---

## 切换前后对比

| | 现在(切换前) | 之后(切换后) |
|---|---|---|
| Pages Source | Deploy from a branch(`main` / `/docs`) | GitHub Actions |
| 内容来源 | `docs/*.md` | `site/`(Astro 源码) |
| 构建者 | GitHub 托管的 Jekyll | `.github/workflows/pages.yml` |
| 内部文档怎么挡 | `docs/_config.yml` 的 `exclude` | Astro 只构建 `site/` 里有的页面,内部文档天然不在产物里 |
| 自定义域 | `docs/CNAME` 文件 + 仓库设置 | **仅**仓库设置(产物里的 CNAME 被忽略) |
| 部署触发 | 推 `main` 就重建 | 推 `main` 且改了 `site/**`,或手动 |
| 上线后验证 | 无 | workflow 自动查 7 个 URL(见下) |

---

## 切换顺序(按这个顺序做,404 窗口最小)

### 第 0 步:确认 `site/` 已经就绪

`site/package.json` 存在、本地 `npm run build` 能在 `site/dist/` 里产出
`index.html`,并且 `privacy` / `terms` / `support` 三个页面都有。

> `site/` 还没建好也不要紧 —— `pages.yml` 里的 `preflight` job 检测不到
> `site/package.json` 就会跳过构建,**CI 不会变红**。

### 第 1 步:先手动跑一次 workflow,只构建不部署

Actions → **Deploy Pages** → Run workflow → **把 `deploy` 勾去掉** → 运行。

这一步只做构建 + 上传 artifact,不碰线上。跑完后:

- 确认 job 是绿的
- 在 run 页面下载 `github-pages` artifact,解压检查:
  - `index.html`、`privacy/`、`terms/`、`support/` 都在
  - **没有** `plans/`、`compliance/`、`app-store/` 这些内部目录
  - 有 `build-id.txt`(workflow 注入的构建指纹)

> 这一步是整个流程里最重要的安全阀:**在完全不影响线上的前提下**,
> 先把「产物对不对」确认掉。

### 第 2 步:改仓库设置(**只能人工做**)

> 这一步无法自动化。`actions/configure-pages` 只在「Pages 站点尚不存在」时
> 才会去创建(`build_type=workflow`);我们的站早就存在,它读到现有配置就直接
> 返回了,**不会**把 Source 从 branch 改成 Actions。所以必须手点。

1. 打开仓库 **Settings** → 左侧 **Pages**
2. **Build and deployment** → **Source**:
   从 `Deploy from a branch` 改成 **`GitHub Actions`**
3. 改完立刻看 **Custom domain** 一栏:
   - 如果还是 `docs.laresapp.org`,不用动
   - 如果被清空了,**立刻填回 `docs.laresapp.org` 并 Save**
4. 等 **Enforce HTTPS** 复选框变成可勾(证书签发中时它是灰的),勾上

> 改 Source 的瞬间,旧的 Jekyll 部署仍在 CDN 上服务,**站点不会立刻 404**。
> 真正的空窗出现在「旧部署失效」到「首个 Actions 部署生效」之间 ——
> 所以第 3 步要紧接着做,别隔夜。

### 第 3 步:立刻跑一次完整部署

Actions → **Deploy Pages** → Run workflow →(这次 `deploy` **保持勾选**)→ 运行。

workflow 会自己在部署后验证那 7 个 URL。**绿了才算切换完成。**

### 第 4 步:人工复核

浏览器无痕窗口挨个点一遍那四个 URL,确认:

- 都能打开,**地址栏是 https 且没有证书警告**
- 页面内容是新的 Astro 站,不是旧 Jekyll 站

---

## CNAME 与 HTTPS 证书的注意事项

这是切换里最容易出问题、也最容易被忽略的一块。

### CNAME 文件不再是权威来源

按 GitHub 官方说明:走自定义 Actions workflow 发布时,
**不会**创建 `CNAME` 文件,已有的 `CNAME` 文件**会被忽略、也不需要**。
自定义域完全由仓库 Settings 里的 Custom domain 决定。

含义:

- `site/public/CNAME`(→ `dist/CNAME`)留着无害,但**别指望靠它绑定域名**
- `docs/CNAME` 也不要删 —— 万一要回滚到 /docs 目录方式,还得靠它
- 域名真的掉了,只能去 Settings 里填回去

### 改 Source 可能把自定义域清空

社区反馈过改 Pages 配置后 Custom domain 被清掉的情况。一旦清空:

- 站点退回 `<owner>.github.io/<repo>` 路径
- `docs.laresapp.org` 直接打不开 —— **这正是要避免的 404**

所以第 2 步里特意要求「改完 Source 立刻回头看 Custom domain」。

### HTTPS 证书可能要重签

自定义域重新填写会触发 Let's Encrypt 重新签发:

- 一般几分钟,**最长可能到 1 小时**;官方对 Enforce HTTPS 选项可用的说明是最长 24 小时
- 这期间 `https://` 可能报证书错误 —— 对审核员来说**比 404 更糟**,
  浏览器的证书警告页会让人直接放弃
- 证书没签好之前,**不要**去动 DNS

**如果正在 App Store 审核中,建议干脆等审核结束再切。**
这个切换没有任何时间压力,而审核有。

---

## 回滚:切回 /docs 目录

新站出问题且短时间修不好时,按这个顺序退回去。`docs/` 一直原封不动,
所以回滚是干净的。

1. Settings → Pages → **Source** 改回 **`Deploy from a branch`**
2. Branch 选 **`main`**,目录选 **`/docs`**,Save
3. 检查 **Custom domain** 仍是 `docs.laresapp.org`(空了就填回去)
4. 等 1–2 分钟让 Jekyll 重建,然后验证那四个 URL

> 回滚**不需要**改任何代码,也不需要 revert `pages.yml` ——
> Source 一旦改回 branch,`preflight` 会检测到 `build_type=legacy`,
> 自动跳过部署(灰色 skip,不是红色 failed),不会和 Jekyll 打架。

回滚后若要再试,从第 1 步重来。

---

## workflow 的行为速查

`.github/workflows/pages.yml`,四个 job 串成一条链:

```
preflight ──→ build ──→ deploy ──→ verify
  探测环境     构建 Astro   发布      验证线上
```

| 情况 | 表现 |
|---|---|
| `site/` 不存在 | `build` 及之后全部跳过(灰色),**CI 不红** |
| Pages Source 还是 branch | 构建正常,`deploy` 跳过(灰色),job summary 里写明要做的人工操作 |
| 手动运行且不勾 `deploy` | 只构建 + 传 artifact,供人工下载检查 |
| 部署了但 URL 不通 | `verify` **红**,summary 里列出具体哪个 URL 返回了什么 |

### 自检那一步在查什么

部署完之后,对 `https://docs.laresapp.org` 依次检查:

- **必须 200**:`/`、`/privacy`、`/terms`、`/support`
- **必须 404**:`/plans/identity-and-roles`、`/compliance/encryption-export`、
  `/app-store/submission-kit`

重试策略:**每 15 秒一轮,最多 8 轮(约 2 分钟)**,全通过就提前退出。
CDN 生效有延迟,首轮不通是常态,不会一次不通就判失败。

**关键设计 —— 构建指纹:**

每次构建都会把 `sha=<commit>` 写进 `dist/build-id.txt`。自检**先**拉这个文件、
确认线上就是这次的产物,**再**去查那几个 URL。

为什么非要这一层:切换前旧 Jekyll 站**同样**有 `/privacy`、`/terms`、
`/support`(都是 200),内部文档路径在旧站**同样**是 404(被 `exclude` 挡了)。
只看状态码的话,自检对着一个根本没更新的旧站也会全绿 —— 那等于什么都没验证,
却给出了「已验证」的假信号。有了指纹,指纹不匹配就当作 CDN 还没刷新继续等,
等满 2 分钟仍不匹配就明确报错。

---

## 已知风险点

| 风险 | 后果 | 怎么办 |
|---|---|---|
| 改 Source 时自定义域被清空 | `docs.laresapp.org` 404 | 改完立刻检查 Settings,空了马上填回 |
| 证书重签期间访问 | 浏览器证书警告(比 404 更劝退) | 别在审核期间切;切完等证书好再对外用 |
| Astro 的 URL 尾斜杠行为与 Jekyll 不一致 | `/privacy` 可能 301 到 `/privacy/` | 自检用 `curl -L` 跟随重定向后判断,与浏览器行为一致 |
| Astro 产物里混进内部文档 | 内部资料泄漏到公网 | 自检里三个必须 404 的路径就是防这个;第 1 步也要人工看 artifact |
| `site/` 没有 `package-lock.json` | 无法用 npm 缓存,依赖版本会漂 | workflow 已兼容(退回 `npm install` 并告警),但**建议提交 lock 文件** |
| 切换后忘了 `docs/` | 内容改了旧站却不再发布,造成困惑 | 切换稳定一段时间后,再决定 `docs/` 的去留 |

---

## 硬性约定

- **不要删 `docs/` 下的任何东西**,直到新站稳定运行一段时间 ——
  它是唯一的回滚路径
- **不要动 `.github/workflows/ios-build.yml`**,两条流水线互不相干
- `pages.yml` 里不做任何 `git push`,部署完全走 Pages 官方 action
