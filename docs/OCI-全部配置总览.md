# OCI 全部配置总览（公开脱敏版）

> 本文归档**两台 OCI 实例**从创建到日常运行的全部配置：云层网络、主机层服务、数据、
> 自动化与运维纪律。目标是「下次接上就能接着干」，不是教程。
>
> 🔴 **本文所有地址、域名、账号、口令均为占位符。** 真实值只存在于
> `local/ENDPOINT.local.md`（本机，已 `.gitignore`）和实例上的 env 文件里。
> **照抄本文连不上任何服务** —— 这是刻意设计，不是文档缺陷。
>
> 文档状态：2026-11-11。配套 skill：[`skills/oci-a1-ops/SKILL.md`](../skills/oci-a1-ops/SKILL.md)。

---

## 0. 占位符对照与存放位置

| 占位符 | 实际含义 | 真实值在哪 |
|---|---|---|
| `203.0.113.10` | 老机器（ag-egress）公网 IP | `local/ENDPOINT.local.md` |
| `198.51.100.20` | 直连时的本地出口 IP（对照组） | 同上 |
| `198.51.100.30` | A1 执行端公网 IP | 同上 |
| `egress.example.com` | 老机器载体域名 | 同上 |
| `photos.example.com` / `music.example.com` | Immich / Navidrome 公网入口 | Cloudflare Tunnel 配置 |
| `gallery.example.com` | 家庭相册门户公网域名 | 同上 |
| `100.64.0.10` / `.20` / `.30` | Tailscale：A1 / 手机 / PC | Tailscale Admin Console |
| `a1.<TAILNET>.ts.net` | A1 的 MagicDNS 名 | 同上 |
| `<ACCOUNT_EMAIL>` | 三个客户端共用的登录账号 | 客户端 UI |
| `<GALLERY_PASSWORD>` | 相册门户密码 | 实例 `/etc/family-gallery.env` |
| `<BACKUP_BUCKET>` | OCI 私有冷备 bucket | OCI Object Storage |
| `<COMPARTMENT_OCID>` / `<OCI_FINGERPRINT>` | OCI SDK 标识 | 本机 `~/.oci/config` |
| `<A1_SSH_KEY>` | `~/.ssh/id_ed25519_a1` | 本机 |
| `C:\Users\<you>` | 本机用户目录 | — |

**绝不入库的东西**：三份含密钥的隧道配置（`mihomo/config-proxy.yaml`、`hy2/client.yaml`、
`oci-egress/sing-box-server-config.json`）、相册密码、冷备对称密钥 `local/a1-backup.key`、
设备码登录链接、客户端 token、`local/` 整个目录、`.workbuddy/` 工作区。

---

## 1. 两台实例

| | **ag-egress**（旧） | **a1-exec**（★ 当前主线，2026-11-08 上线） |
|---|---|---|
| 公网 | `203.0.113.10` | `198.51.100.30` |
| 机型 | `VM.Standard.E2.1.Micro`（AMD x86_64） | `VM.Standard.A1.Flex` 2 OCPU / 12 GB（ARM64） |
| 系统 | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS ARM64 |
| 启动盘 | 47 GB（默认最小） | 150 GB |
| 区域 | Ashburn / AD-1 | Ashburn / AD-1 |
| 用途 | Antigravity 的 GeoIP 出口代理 | **24h 在线执行端**：手机派单、家里 PC 不长开 |
| SSH | `~/.ssh/id_ed25519`（用户 `ubuntu`） | `~/.ssh/id_ed25519_a1`（用户 `ubuntu`） |
| Tailscale | — | `100.64.0.10` |

🔴 **这是两台独立机器，别搞混。** 老机器全程未改动，A1 是后加的第二台。

### 1.1 为什么恰好是两台（额度硬约束）

Always Free 正本（官方查证，别沿用网传旧说法）：

- A1.Flex **2 OCPU / 12 GB** = 1,500 OCPU·h + 9,000 GB·h/月
- 2 × `E2.1.Micro`
- 块存储 **200 GB 总池且最多 2 个卷**
- 出网 10 TB/月，**仅家乡区免费**
- **4C24G 不免费常驻**；A1 官方明确不支持 Windows
- 闲置回收 = 7 天窗口内 CPU(95p) / 网络 / 内存 三项 **同时** <20%；
  另有**账号级**条款：30 天不登录可能被判 abandoned

创建 A1 前用 SDK 实测：已有 1 个 boot 卷 47 GB，`+150 = 197/200 GB、2/2 卷` →
**刚好不超额，也因此第二台 Micro 不能再开**（卷池只剩 3 GB 且卷数已满）。

> 结论：额度不是「还能开几台」的问题，是**卷池先满**。开新实例前先查 `list_boot_volumes`。

### 1.2 PAYG 与预算

账号已升 **PAYG**（超额真扣钱），Always Free 额度照旧免费，只对超出部分计费。
升级后第一件事是设 **Budgets**（已设一个 1 SGD 级预算，目的不是省钱，是异常时能收到邮件）。
升级可能有临时预授权冻结，3–5 天自动解除、不产生实际扣款。
PAYG 豁免闲置回收属**高置信但非官方逐字**（官方只写 "Idle **Always Free** instances"）。

---

## 2. 云层网络：真正的边界

### 2.1 A1 用独立 NSG

`a1-exec-nsg` 只放三条：

| 方向 | 协议 | 用途 |
|---|---|---|
| ingress | 22/TCP | SSH |
| ingress | 41641/UDP | Tailscale 直连 |
| egress | all | 出网 |

🔴 **云层 NSG 才是真边界**：Docker 发布的端口绕得过 UFW。
把 VNIC 放进 NSG 后，子网 Security List 不再作用于它 —— 这样也避免了继承老机器
公网 443 / 8443 的放行规则。

### 2.2 老机器是「两层」模型

```
外部 →【① 云端 Security List（控制台）】→ 公网 IP
     →【② 实例内 iptables】→ 服务
```

两层是「与」关系，只改一层一定不通。OCI Ubuntu 镜像的 `/etc/iptables/rules.v4`
末尾有一条 `-A INPUT -j REJECT --reject-with icmp-host-prohibited`，除 22 外全拒绝
（**OCI 独有**，AWS/GCP 镜像没有）→ 放行规则必须用 `-I INPUT 1` 插到链首，
用 `-A` 会永远不生效。完整三态诊断见 [`OCI出口搭建指南-Antigravity.md`](../OCI出口搭建指南-Antigravity.md)。

| 现象 | 卡在哪层 |
|---|---|
| `TIMEOUT`（静默丢包） | ① 云端 Security List |
| `no route to host` | ② 实例内 iptables 的 REJECT |
| `Connection refused` | 两层都通，只是服务没起 |

> `TIMEOUT` 还有第二个来源：**本机侧隧道**（WARP / Clash TUN）把流量吃掉。
> 区分方法是查连接的本地源 IP，或用外部多节点探测反证。

### 2.3 公网 IP 的行为

`reboot` / `Stop-Start` **不换 IP**；只有「手动 unassign」或「终止重建」才换
→ **不需要 Reserved Public IP**。网传「保留 IP 收费 $0.01/h」是未证实的第三方说法，
易与 AWS 2024 起 $0.005/h 混淆。

### 2.4 WARP 必须排除 VPS IP

本机 WARP 若开着且未排除，`VPS:443` 会 8/8 TIMEOUT、UDP 8443 也断，整条隧道死。
用 `warp-cli tunnel ip add <VPS_IP>`；**换 IP 要重新 add**。
`Get-Service CloudflareWARP` 在断开时仍显示 Running → 必须问 `warp-cli status`。
应用层 socket 绑物理网卡地址会被拒 `WSAEACCES (10013)`，绕不过，只能真断开或加排除。

---

## 3. Tailscale

| 设备 | 地址 |
|---|---|
| A1 执行端 | `100.64.0.10` |
| 手机（派单台） | `100.64.0.20` |
| 家里 PC | `100.64.0.30` |

- MagicDNS：`a1.<TAILNET>.ts.net`
- ACL 保持**默认全互通**。曾经把「主要用来看照片音频」误读成访问控制边界，
  设计了只放行 2283/4533 的 ACL —— 这与「手机指挥 A1 上三个客户端干活」自相矛盾。
  **「主要是 X」是用途优先级，不是授权策略。**
- **Exit node**：A1 已 `--advertise-exit-node`，Admin Console 已批准，
  客户端**未强制启用**（按需）。配套开了 IPv4 forwarding + UFW route allow。
- ⚠️ 加密隧道仍走物理互联网，OCI 出网照计量（10 TB/月内 0 元）、手机蜂窝照耗
  → 「免费」成立，「不占任何流量」不成立。
- 🔴 **不要叠 Cloudflare Mesh**：Mesh 用 `100.96.0.0/12` 与 Tailscale 重叠，
  且 Mesh 节点官方最低 vCPU ≥ 3（A1 只有 2）。流量经 CF 边缘中继、非 P2P。

---

## 4. Cloudflare Tunnel 与公网暴露面

要点：**管理入口一律 404，只放行分享与必要 API**。

| 域名 | 后端 | 说明 |
|---|---|---|
| `photos.example.com` | `127.0.0.1:2283` | Immich 分享访问 |
| `music.example.com` | `127.0.0.1:4533` | Navidrome（暂缓，仍 0 首） |
| `gallery.example.com` | `127.0.0.1:8099` | 家庭相册门户（密码门） |

ingress 白名单逐个放过（漏一个，前端就卡在 pending / 404）：

- `/share/*`、`/s/*`
- `api/shared-links`、`api/assets`、`api/download`
- Immich 前端依赖：`/_app`、`/assets`、`/fonts`、`/light_skeleton.png`
- 排障时补过：`api/server/(config|features|media-types|version|about|apk-links|ping)`、
  `api/albums`、`api/timeline`、`api/search`

**始终拒绝**：`/`、`/auth/login`、`/api/users` 等管理入口。

> 教训：分享页「一直 pending」不是索引没做完，是 ingress 少放行了一个 API。
> 逐项补完并用无头浏览器验证照片网格后才算闭环。

**备用线只留档、不启用、不删除**：R2 图床、Tailscale Funnel、Cloudflare Tunnel 其它走法。
「现在不需要」≠「把备选删掉」。

---

## 5. A1 主机层

### 5.1 基线

- Ubuntu 24.04 ARM64，时区 `Asia/Shanghai`
- 🔴 镜像里 `ubuntu` = **UID 1001**、`opc` = UID 1000 → 别硬编码 `chown 1000:1000`
- Xvfb `:99`，systemd **system** unit（`xvfb.service`），只监听本地
- 所有 GUI 客户端都是 systemd **user** unit + `loginctl enable-linger`
  （否则登出就被杀，24h 常驻不成立）
- 客户端一律 `--no-sandbox`

### 5.2 客户端清单

| unit | 版本 | 状态 | 说明 |
|---|---|---|---|
| `workbuddy.service` | WorkBuddy **CN** 5.6.2 | active | 官方 Linux ARM64 deb |
| `trae.service` | TRAE **CN** 2.3.100185 | active | 官方 Linux ARM64 deb |
| `qoder-cn.service` | Qoder **CN** 0.5.7 | active | 带 `--remote-debugging-port=9227` |
| `qoder.service` | Qoder **国际版** | **failed / 停用（留档不删）** | 曾误装，与 CN 账号/权益/移动端都不匹配 |
| `QoderWake.service` | — | active | `127.0.0.1:19820`，连 `openapi.qoder.sh` |

🔴 **用户核心需求是「手机操控 VPS」** → 客户端一律 **CN 版**并开启
`Enable remote control`。国际版的账号体系、权益中心和移动端对不上，装了也没法派单。
QoderWake 是**无 GUI 的后台执行引擎**：删掉不影响网盘/签到，但会影响手机派给
Qoder 的后台 agent 任务。

### 5.3 安装要点（都踩过）

- 三个 CN 版**都有官方 Linux ARM64 deb**。TRAE 静态下载页只标 x64，
  但运行时 API manifest 的 `manifest.linux.download[]` 明确有 arm64 →
  「Linux 装不了 / 只能 x64」是错结论。
- TRAE `.desktop` 的 `Exec` 是 wrapper，systemd 必须**直指真二进制**：
  ```
  /usr/share/trae-cn/trae-cn --ozone-platform=x11 --no-sandbox
  ```
  否则无限重启堆窗口。
- Qoder CN 的 unit 模板（脱敏）：
  ```ini
  [Unit]
  Description=Qoder CN 24h client on Xvfb :99
  [Service]
  Environment=DISPLAY=:99
  ExecStart=/opt/Qoder-CN/qoder-cn --no-sandbox --remote-debugging-port=9227
  Restart=always
  [Install]
  WantedBy=default.target
  ```
- Qoder CN 登录用**设备码链接**（`Log in` → `Copy sign-in link`），
  用户在本机浏览器点一下即可，**不必在 VPS 侧闭环**。短时效链接一生成就单独交付，
  不要夹在长任务里。
- ⚠️ 客户端进程非正常重启可能丢登录态；恢复流程见 §8.5。

---

## 6. 服务清单

| 服务 | 类型 | 端口 / 路径 | 用途 |
|---|---|---|---|
| `xvfb.service` | system | `:99` | 虚拟显示 |
| `family-gallery.service` | system | `127.0.0.1:8099` | 密码门相册门户 |
| `cloudflared` | — | Tunnel | 公网白名单入口 |
| Immich | Docker Compose ×3 | `100.64.0.10:2283` | 照片；`immich_server` / `immich_postgres` / `immich_redis` |
| Navidrome | Docker | `100.64.0.10:4533` | 音频（暂缓） |
| `immich-db-dump.timer` | system | 03:30 | `pg_dump -Fc` → `/srv/backup/`，留 7 份 |
| `checkin-capture.timer` | user | 08:05 | **只读**截图，不是签到 |
| `checkin-claim.timer` | user | 08:10 | WorkBuddy 签到 |
| `checkin-trae.timer` | user | 08:15 | TRAE CN 签到 |
| `checkin-qoder-cn.timer` | user | 10:05 | Qoder CN 权益中心 100 credits（10:00 UTC+8 重置） |

Immich 按官方要求禁 ML、缩略图 +10–20%、Postgres 必须本地 SSD；
官方原话 **"Immich is not a backup on its own"** → 所以才有 §9 的冷备。

---

## 7. 照片库与公网门户

### 7.1 外部库（关键坑）

Immich 用 **Postgres 记资产**，直接把文件拷进 `/srv/media/photos` **不进时间线**。
必须走 REST `/api/assets` 或 External Library。最终采用后者：

- `immich_server` 加只读挂载：`/srv/staging/photo:/mnt/staging:ro`
- Postgres 里把该 library 的 `importPaths` 改成 `{/mnt/staging}`
- 重建容器后，在管理页点 **Scan Library**

按 `split_part("originalPath", '/', 4)`（顶层文件夹）用 SQL 批量建 8 个相册，
写入 `album_user(role='owner')`、`album_asset` 和封面。

### 7.2 分享收敛成一个入口

- 不再发多个公网裸链，改为**一个带密码的门户** `https://gallery.example.com`
- 门户用 Python 标准库 HTTP server + HMAC 签名 cookie；密码与签名密钥放
  `/etc/family-gallery.env`（**不入库**）
- 模板占位符用 `@@ERR@@` / `@@COUNT@@` / `@@CARDS@@` 替换，
  **不要用 `%s`** —— CSS 里的 `%` 会让字符串格式化直接崩
- 删掉《老照片》的独立分享、清空可猜测的 slug → 门户展示 7 个相册
- 旧短链全部失效

### 7.3 音频

Navidrome 常驻但 0 首，源目录已定位。用户明确「暂时不着急」→ **不删、不推进**。

---

## 8. 每日自动签到

### 8.1 原则

> **官方 UI 模拟点击最安全 > 网页 headless > 逆向 API（最高风险）**

🔴 **绝不让 Agent 去签到**：论坛实测一次 Agent 任务耗 199.99 积分 > 领到的 100。
签到脚本全部是「看图 + 精确点击」，不调用任何未公开接口。

### 8.2 三个客户端的 guard

| 客户端 | 判据 | 点击 |
|---|---|---|
| WorkBuddy | 左侧栏 `Claim Now` 白按钮框 `(65,693)-(163,721)` 白像素比 ≥0.55 | `(114,707)`；点后白像素比减半才算 `DONE` |
| TRAE CN | 账号菜单 `Check in` 黑按钮框 `(211,361)-(281,390)` 暗像素比 ≥0.40 | `(245,377)`；点后变灰才算 `DONE` |
| Qoder CN | 权益中心卡片含 `100 Credits` **且**存在精确文本 `Claim` 且未禁用 | DOM click；点后复读卡片 |

共同纪律：**按钮不在预期状态就 SKIP，绝不盲点坐标**（尤其 TRAE 菜单里
`Upgrade Plan` / `Log Out` 就在附近）。

### 8.3 两个真实故障与修法

**① TRAE 的 11.11 促销弹窗**
`11.11 sale: Up to 30% off membership` 模态框盖住左下角账号区，
点 `(101,766)` 完全无效 → 日志是 `SKIP - no black Check in button`。
→ 修法：先 `xdotool key Escape`，再用暗像素比检测黑横幅
`(430,185)-(850,360)`（阈值 0.50）兜底点 X `(847,202)`，最后加一次受控重试。
复跑拿到服务端回执 `checkin_credits/claim 200 OK`，证明早上是**漏点而非已领**。

**② Qoder CN 的跨域 iframe（最费劲的一个）**

权益中心不是普通页面，点菜单项后 CDP 会**新增一个 `type=iframe` 的独立 target**
`https://gateway.qoder.com.cn/growth-page/activity-iframe`（OOPIF）。

| 尝试 | 结果 |
|---|---|
| `get_by_text("Rewards center", exact=True)` | 侧栏提示串是 `Rewards center, benefits available`，精确匹配永远失败 |
| 用 `[role=menuitem]` 点开 + 同一进程内重连 CDP | Playwright 不把新 OOPIF 映射成 `pg.frames`，找不到 |
| 独立子进程重连 | 仍不稳定（只有一次偶然成功） |
| **原生 CDP WebSocket 直连该 target**（v7，终解） | ✅ 稳定 |

**v7 架构**（脚本见 `skills/oci-a1-ops/scripts/a1_checkin_qoder_cn_v7.py`）：

1. Playwright **只负责点官方 UI 入口**：`button[aria-label="Open user menu"]` →
   `div[role=menuitem]` 中文本为 `Rewards center` 的项。
2. 用 `/json/list` 确认 `growth-page` target 出现 —— 这个判据**独立于 Playwright**，最可靠。
3. 用标准库手写的最小 WebSocket 客户端（零依赖、不装包）直连该 target 的
   `webSocketDebuggerUrl`，`Runtime.evaluate` 读 `document.body.innerText`，
   校验 `100 Credits` + 精确 `Claim` 按钮未禁用 → 点击 → 复读卡片。

🔴 **禁止对该 iframe target 调 `/json/close`**：实测会带崩 Qoder CN 主窗口，
systemd 重启后登录态丢失。这条已写进脚本注释。

### 8.4 登录态恢复

客户端非正常重启后可能变成 `Log in`。恢复流程：

```
主界面 Log in → Waiting for browser → Copy sign-in link
→ 读剪贴板（navigator.clipboard.readText() 或 DISPLAY=:99 xclip -o）
→ 得到短时效设备码链接 → 交给用户在本机浏览器点一下
```

**登录不必在 VPS 侧闭环**；用户在本机协助即可。恢复后核对
`~/.qoder-cn/.qoder-app-status.json` 的 `logged_in: true`。

### 8.5 版本演进留痕

`v2 → v3 → v4 → v5 → v6 → v7`，每版在实例 `~/.local/bin/` 都有
`.bak-*-20261111` 备份。**别回退到 v3~v6**：它们依赖 Playwright 映射 OOPIF，不稳定。

---

## 9. 备份

| 层 | 做法 |
|---|---|
| 数据库 | `immich-db-dump.timer` 每天 03:30 `pg_dump -Fc` → `/srv/backup/immich-*.dump`，留 7 份 |
| 配置冷备 | SSH 把关键配置拉回本机 → `openssl enc -aes-256-cbc -pbkdf2` 本地加密 → 上传 OCI 私有 bucket `<BACKUP_BUCKET>` |
| 密钥 | `local/a1-backup.key` **只在本机，绝不上传** |

冷备踩过的坑：超时、后台 SSH 更新 `known_hosts` 被沙箱误报、私钥 `Permission denied`、
相对路径导致 32 字节空包。最终改为**前台拉包 → 本机加密 → 上传**三步，成功对象约 21 MB。

> 判断后台任务成败看**远端日志 + 重连**，不看任务状态标记
> （SSH 更新 `known_hosts` 会让后台任务标 failed 但 `exit=0`）。

---

## 10. ag-egress 链路（摘要）

```
language_server.exe → version.dll(MinHook 钩 Winsock) → mihomo 127.0.0.1:7897
  → socks5 127.0.0.1:7899 → hysteria QUIC/UDP 8443 → OCI → Google API
  ↳ 兜底 ss2022 TCP 443（慢 100×，挂了自动降级不断网）
```

- 同机同分钟实测：ss/TCP443 9–16 KB/s，hy2 **1.65 MB/s**（≈100–180×）
- 走隧道 `ipinfo.io/json` 判 **US** 达成；直连判 CN
- DLL 在 `Programs\Antigravity\resources\bin\`，**每次升级会清空**
  （启动脚本自动重部署）；补完必须**完全重启** Antigravity
- 自检看 `ag-proxy-check.ps1` 的 `[E]` 出口国家 + `[B2]` hy2 是否在听，**别只看 RESULT**
- DNS 已改回国内 `223.5.5.5 / 119.29.29.29`：节点是 IP，mihomo 不解析任何域名

**链路演进别走回头路**：纯 WARP 裸连（判 CN）→ TUN 抢路由失败 →
DLL hook ✅ → CF Worker 出口（`104.28.240.x` 判 CN，CF 侧无解）→ OCI 自建出口 ✅。

完整手册见 [`OCI出口搭建指南-Antigravity.md`](../OCI出口搭建指南-Antigravity.md)，
重建见 [`oci-egress/REBUILD-CHECKLIST.md`](../oci-egress/REBUILD-CHECKLIST.md)。

---

## 11. 运维纪律

### 11.1 推送

- 🔴 **`git commit` 与 `git push` 必须分开发**：串在一条命令里会 push 静默丢失，
  判断 commit 只看 `git log`
- 走本机 7897 代理（**别试直连**，也别用内置 62849）：
  ```bash
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    git -c http.proxy=http://127.0.0.1:7897 \
        -c https.proxy=http://127.0.0.1:7897 push origin main
  ```
- 66 MB 二进制刻意入库（clone 免下载，代价是国内 ≈30 KB/s、20 分钟级）
- 忽略清单：`.workbuddy*` `_usb-package/` `_deprecated/` `local/` `*.log` `cache.db` `_tools/diag-*`

### 11.2 工具链禁令

- `.bat` / `.ps1` 一律**纯 ASCII**（GBK 吞引号会连锁崩）
- `.ps1` 用 `ipinfo.io/json`，**别用** `myip.ipip.net`（GBK 乱码）
- `(& curl.exe ...)` 多行输出是数组，先 `-join` 再 `-match`
- 🔴 禁止从 Bash 调 `powershell.exe`；PowerShell 工具禁 `cmd.exe`；
  Bash 跑 `.bat` 会被内部 `reg.exe` 黑名单整体 SIGTERM → `.bat` 只能 Explorer 双击
- 工具里起进程用 `Start-Process`；Bash 起的后台进程**会话结束即消失**
- OCI SDK 用本机 Python 3.13 解释器；`list_boot_volumes` 是 keyword-only，
  块卷叫 `list_volumes` 不是 `list_block_volumes`

### 11.3 判断纪律（都踩过）

1. **因果纪律**：定因果要机制证据 + 排除混杂 + 可复现；
   跨设备对照是「本地 vs 路径」最强判据。单次无对照的 before/after 不算实锤。
2. `TIMEOUT` ≠ 被封（默认拒绝的云主机正常现象）；`401` ≠ 绿灯（只证明管道通）。
3. **复述 ≠ 复核**：同一结论每复述一次回原始出处核一遍，
   「可以」会在复述里漂成「必须」。找不到原文的「必须/唯一」降级为待核。
4. 先线上实证再读代码下结论；架构一换，回头审计依赖已废弃组件的旧结论。
5. **不替用户砍线**：「不启用」≠「删除」、「主要是 X」≠「只能做 X」、
   描述性别偷偷升级成约束。用户对当前范围的描述不是授权收缩未来选项。
6. 计费/定价类问题**先看用户 UI 里实际显示什么**，再拿文档交叉验证；
   刊例价 ≠ 个人版实际扣费。

### 11.4 外部视角判据

本地全 TIMEOUT 时用 `viewdns.info/portscan/?host=<IP>`：
22/443 open = 实例健康，问题在中国侧。

---

## 12. 恢复要点（A1）

1. 从冷备对象取回配置（本机解密，密钥 `local/a1-backup.key`）
2. 重建实例时先查卷池余量；NSG 只放 22/TCP + 41641/UDP + egress all
3. 恢复 `/srv/staging/photo` → 挂只读到 `/mnt/staging` → Postgres `importPaths`
4. `systemctl --user` 四个 unit + 四个 timer，确认 `loginctl enable-linger`
5. 三个客户端重新登录（设备码链接），核对 `logged_in: true`
6. 确认 `Enable remote control` 仍为 Enabled（手机端实际派一单验证）
7. 恢复 Cloudflare Tunnel ingress 白名单与 `/etc/family-gallery.env`
8. 跑一次三个签到 service，看 `ExecMainStatus` 与日志，不要只看 timer 的 NEXT

---

## 附录 A：三款客户端的模型阵容（2026-11-11 官方快照）

> A1 上装的**全是 CN 版**，下表是**国际版**，不等于 VPS 上实际可用。
> 三家官方文档都写明「以客户端模型选择器实际显示为准」；模型列表变动极快。

| 产品 | 国际版主要模型 | 与 CN 版的关键差异 |
|---|---|---|
| TRAE（`docs.trae.ai/ide/models`） | GPT-6.1/GPT-6/GPT-5.6 系列、GPT-5.5/5.4/5.2、Gemini-3.1-Pro/3-Flash、Kimi-K3/K2.x、DeepSeek-V4 系、GLM-5.2、MiniMax-M3/M2.7、Seed-2.1-Turbo；**美国区**另有 Grok-4.7/4.6、Gemini-2.5 系，且 Seed/MiniMax/GLM 在美国不可用 | CN 版全是国产模型（Seed/MiMo/Step/GLM/DeepSeek/Kimi/MiniMax/Qwen），无 GPT/Gemini/Grok/Claude |
| Qoder（`docs.qoder.com/qoder/model-selector`） | Tier 路由 Auto ~0.5× / Ultimate ~2.0× / Fast ~0.8× / Efficient 0.3×；官方公开的具体模型是 Qwen3.8、DeepSeek-V4、GLM-5.3、Kimi-K3.1/K2.8、MiniMax-M3.1 | 官方该页**未列** Claude/GPT/Gemini 具体型号；第三方测评的「内置自动路由」疑为旧信息 |
| WorkBuddy（`workbuddy.ai`） | 官方文章：Claude + GPT-5 + Gemini；更新的活动文列 GLM/Kimi/DeepSeek/GPT/Gemini | CN 版：混元 + DeepSeek + GLM + Kimi + MiniMax |

官方当前内置表**没有 Claude**（TRAE）；Claude/Grok 在 WorkBuddy 只有二手来源，需看 UI 坐实。

> 反例留痕：有二手文章称「官方已永久关闭每日签到」，但实例上连续两天
> `Claim Now` 点击成功、TRAE 有 `/claim 200 OK` 回执 → **文档与实例冲突时以实例为准**。

---

## 附录 B：刻意保留 / 暂缓（不是欠账）

- **备用线**：R2 图床、Tailscale Funnel、Cloudflare Tunnel 其它走法 —— 不部署、不启用、**不删除**
- **国际版 `qoder.service`**：failed 且停用，留档不删
- **音频**：Navidrome 0 首，用户明确「暂时不着急」
- **Tailscale exit node**：Admin Console 已批准，客户端未强制启用（按需）
- **Cloudflare Mesh / OCI Vault / Bastion / 卷备份**：有意暂缓；Mesh 还有网段冲突与 vCPU 门槛
- **常驻监控面板**：明确不做（告警 ≠ 面板）

---

## 相关文件

| 文件 | 内容 |
|---|---|
| [`README.md`](../README.md) | 仓库首页 / 客户端快速开始 |
| [`OCI出口搭建指南-Antigravity.md`](../OCI出口搭建指南-Antigravity.md) | 老机器完整实操 |
| [`oci-egress/REBUILD-CHECKLIST.md`](../oci-egress/REBUILD-CHECKLIST.md) | 实例被收/误删的恢复路径 |
| [`多端接入计划-OCI出口.md`](../多端接入计划-OCI出口.md) | hy2 切换全过程与性能天花板 |
| [`BACKLOG.md`](../BACKLOG.md) | 待办与「明确不做」 |
| [`skills/oci-a1-ops/SKILL.md`](../skills/oci-a1-ops/SKILL.md) | 配套的 A1 运维 / 签到排障 skill |
