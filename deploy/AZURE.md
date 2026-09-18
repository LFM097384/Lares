# 在 Azure 上部署 Lares(学生订阅)

面向已经拿到 **Azure for Students** 订阅的情况。
从创建虚拟机一路到服务跑起来。

裸 VPS 的通用说明见 [README.md](README.md);
这份只讲 **Azure 特有** 的那些坑。

---

## 先说三个会咬人的地方

**① 网络安全组(NSG)默认拦住一切入站**

这是 Azure 和裸 VPS 最大的区别。RackNerd 那种机器开机就是全端口裸奔,
Azure 则默认只放行 SSH(22)。

**你在系统里 `ufw allow` 了也没用** —— NSG 在虚拟机之外,
流量根本到不了机器。必须去 Azure 门户里单独开。

这是新手在 Azure 上最常卡住的一步:服务明明起来了,外面就是连不上。

**② 公网 IP 默认是动态的**

重启虚拟机 IP 就变,域名解析随之失效。
创建时必须把公网 IP 选成 **静态(Static)**。

改也来得及:门户 → 公共 IP 地址 → 配置 → 分配方式选「静态」。

**③ 订阅到期虚拟机会被强制停机**

学生订阅 12 个月或额度用完即到期,VM 直接 deallocated。
**日历上记一笔,提前续。** 数据盘还在,但服务是断的。

---

## 一、创建虚拟机

Azure 门户 → 「虚拟机」→ 创建 → Azure 虚拟机

| 项 | 填什么 | 为什么 |
|---|---|---|
| 区域 | **West US**(美西) | 按用户所在地选;日本东部对国内延迟更低 |
| 映像 | **Ubuntu Server 24.04 LTS** | 部署脚本按 Debian 系写的 |
| 大小 | **B1s**(1 vCPU / 1 GB) | 免费额度含 750 小时/月 ≈ 全天候一台 |
| 身份验证 | **SSH 公钥** | 别用密码,公网机器会被爆破 |
| 公网 IP | 新建,分配方式 **静态** | 动态 IP 一重启就变 |
| 入站端口 | 先只勾 **SSH (22)** | 其余在 NSG 里按需开,见下 |

> B1s 是**突发型**:CPU 长期高负载会耗尽积分然后被限速到 10%。
> 语音转发本身 CPU 占用很低,正常用不会碰到。但别拿它跑别的重活。

---

## 二、开放端口(NSG)

**这一步不做,服务一定连不上。**

门户 → 你的虚拟机 → 网络设置 → 「添加入站端口规则」,加三条:

| 端口 | 协议 | 用途 |
|---|---|---|
| `80` | TCP | HTTP-01 证书验证 + 跳转 |
| `443` | TCP | HTTPS / WSS 信令 |
| `7881` | TCP | LiveKit RTC 回退通道 |
| `7882` | **UDP** | LiveKit RTC 主通道 |

> ⚠️ **7882 是 UDP**,别选成 TCP —— 选错的话语音连不上,
> 而且症状是「信令通了、进房成功、就是听不见」,很难查。

也可以用 Azure CLI 一次加完:

```bash
# 把 <RG> 和 <NSG> 换成你的资源组名和网络安全组名
for p in "80 tcp 1000" "443 tcp 1001" "7881 tcp 1002" "7882 udp 1003"; do
  set -- $p
  az network nsg rule create \
    --resource-group "<RG>" --nsg-name "<NSG>" \
    --name "lares-$1-$2" --priority "$3" \
    --destination-port-ranges "$1" --protocol "$2" \
    --access Allow --direction Inbound
done
```

---

## 三、域名解析

把域名的 **A 记录**指向虚拟机的公网 IP。

```
rtc.你的域名.com    A    <公网 IP>
```

用 `dig` 确认生效(Windows 上用 `nslookup`):

```bash
dig +short rtc.你的域名.com
```

解析出来的 IP 要和门户里显示的一致。**这一步没生效就别往下走** ——
证书签发依赖它,失败几次会撞上 Let's Encrypt 的速率限制。

---

## 四、装 Docker

```bash
ssh azureuser@<公网 IP>

# 官方脚本,Ubuntu 24.04 直接可用
curl -fsSL https://get.docker.com | sudo sh

# 免 sudo 用 docker(要重新登录才生效)
sudo usermod -aG docker "$USER"
exit
```

重新登录后确认:

```bash
docker --version
docker compose version   # 要 ≥ v2.23.1
```

---

## 五、部署

```bash
git clone https://github.com/LFM097384/Lares.git
cd Lares/deploy
cp .env.example .env
vim .env
```

Azure 专用机器用 **http 模式**(独占 80/443,最省事):

```bash
LARES_DOMAIN=rtc.你的域名.com
LARES_TLS_MODE=http
LARES_HTTPS_PORT=443
LARES_HTTP_PORT=80
LARES_ACME_EMAIL=你的邮箱

# 声明这是专用机器,preflight 就不会为「找不到 xray」报警
LARES_DEDICATED_HOST=1

# 公网必开鉴权 —— 不开的话任何人都能进你的圈子
LARES_AUTH_MODE=circle
LARES_CIRCLE_PASSCODES={"home":"你的口令"}

# LiveKit 密钥:随便生成两串长随机
LIVEKIT_API_KEY=$(openssl rand -hex 16)
LIVEKIT_API_SECRET=$(openssl rand -hex 32)
LIVEKIT_PUBLIC_URL=wss://rtc.你的域名.com
```

然后:

```bash
./preflight.sh    # 只读体检,不改任何东西。必须先过
./deploy.sh
```

`preflight.sh` 会实测 80/443 是否空闲、域名解析对不对、配置有没有自相矛盾。
**它报 fail 就别硬上** —— 那些检查都是踩过坑才加的。

---

## 六、验证

```bash
# 健康检查
curl https://rtc.你的域名.com/health

# 看日志
docker compose logs -f caddy      # 证书签发过程
docker compose logs -f lares      # 信令服务
```

证书首次签发要几十秒。Caddy 日志里出现 `certificate obtained successfully`
就成了。

客户端那边:设置页 → 连点版本号 7 次开开发者模式 → 服务器与口令 →
填 `wss://rtc.你的域名.com/ws` 和圈子口令 → 「测试连接」。

---

## 省钱与保命

**盯住额度**:门户 → 成本管理 → 成本分析。
学生订阅额度烧完订阅就停,虚拟机跟着停。

**设预算告警**:成本管理 → 预算 → 新建,设个比额度低的阈值,
到点发邮件。比事后发现服务没了强。

**不用时停机**:门户里「停止」会释放计算资源(不再计费),
静态公网 IP 保留。但要注意 —— 停机期间服务是断的。

**日历记续订**:学生订阅每 12 个月要重新验证学生身份。
过期不续,VM 被 deallocated。
