# systemd 方案(Docker 的替代路线)

> **这是备选方案。主线仍是 `deploy/docker-compose.yml`。**
> 只有当你判断「这台 1GB 机器上 Docker 的常驻开销不划算」时才用这里的东西。

## 什么时候该考虑它

先看数字(详细推导见 `../README.md` 的「内存预算」一节):

| 项 | Docker 方案 | systemd 方案 | 省下 |
|---|---:|---:|---:|
| dockerd + containerd 常驻 | ~110 MB | 0 | **110 MB** |
| 每容器一个 containerd-shim(3 个) | ~30 MB | 0 | **30 MB** |
| LiveKit | ~90 MB | ~90 MB | 0 |
| lares-server(Node 22) | ~55 MB | ~55 MB | 0 |
| Caddy | ~30 MB | ~30 MB | 0 |
| **合计** | **~315 MB** | **~175 MB** | **~140 MB** |

在一台总共 1GB、还要养着 xray 的机器上,**140MB 是实打实的一大块**
(大约相当于总内存的 14%,或 xray 稳态占用的 3~5 倍)。

**结论(诚实版):**
如果这台机器只跑 Lares,我会直接推荐 systemd。
但考虑到:

1. 主人已经有一套 compose 配置和使用习惯;
2. Docker 的资源隔离(`mem_limit`)恰恰是保护机场的有效手段 ——
   systemd 要用 `MemoryMax=` 才能达到同等效果(下面的 unit 已经写了);
3. 140MB 在**加了 1GB swap 之后**不再是生死线;

所以主线保持 compose。**但如果你部署后发现 `free -m` 长期紧张,
换到 systemd 是完全合理的决定,而且这里的文件是现成的。**

真正省内存的第三条路:**用 LiveKit Cloud 跑媒体,本机只留 lares-server**。
那样本机常驻只剩 ~55MB(Node)+ ~30MB(Caddy),彻底没有内存焦虑。
对中国用户延迟也更好 —— 见主 README 的「两种拓扑」一节。

## 前置条件

```bash
# Node 22(lares-server 需要)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Caddy(DNS-01 需要带插件的构建版,见下)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
# LiveKit 二进制
curl -sSL https://get.livekit.io | sudo bash
```

> ⚠️ DNS-01 同样需要带 Cloudflare 插件的 Caddy。
> apt 装的官方包不含插件,得用 `xcaddy` 自行构建后替换 `/usr/bin/caddy`,
> 或到 <https://caddyserver.com/download> 勾选 `caddy-dns/cloudflare` 下载。

## 安装

```bash
# 1. 建用户与目录(全部不涉及 xray/3x-ui 的任何路径)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin lares
sudo mkdir -p /opt/lares /var/lib/lares /etc/lares
sudo chown -R lares:lares /var/lib/lares

# 2. 放代码
sudo cp -r ../../server/src ../../server/package.json /opt/lares/
cd /opt/lares && sudo npm ci --omit=dev

# 3. 配置(同 .env,但格式是 systemd EnvironmentFile)
sudo cp lares.env.example /etc/lares/lares.env
sudo chmod 600 /etc/lares/lares.env
sudo vim /etc/lares/lares.env

# 4. LiveKit 配置
sudo cp livekit.yaml /etc/lares/livekit.yaml
sudo vim /etc/lares/livekit.yaml     # 填 keys

# 5. 装 unit
sudo cp lares-server.service lares-livekit.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lares-livekit lares-server
```

## 校验

```bash
systemctl status lares-livekit lares-server
curl -s http://127.0.0.1:8787/health
ss -tulpn | grep -E ':(7881|7882|8787)'
```

## 卸载

```bash
sudo systemctl disable --now lares-server lares-livekit
sudo rm /etc/systemd/system/lares-{server,livekit}.service
sudo systemctl daemon-reload
# 数据在 /var/lib/lares,确认不要了再删
```

## ⚠️ 与机场共存的注意事项

- 这些 unit 只叫 `lares-*`,**不会**与 `x-ui.service` / `xray.service` 重名。
- unit 里设了 `MemoryMax=`,超限时被杀的是 Lares 自己,不会波及 xray。
- 建议给 xray 加一层 OOM 保护(这是**改机场的 systemd 配置**,
  属于主人自己的决定,本项目的脚本绝不会替你做):
  ```bash
  sudo systemctl edit xray      # 或 x-ui
  # 加入:
  # [Service]
  # OOMScoreAdjust=-500
  ```
  这会让 OOM killer 优先挑别的进程下手。
