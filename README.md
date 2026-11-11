# ag-egress

**让 Google Antigravity 在网络受限地区正常工作。**

Self-hosted egress for Google Antigravity: a Windows client (DLL hook + local proxy) plus a
VPS you control. The client makes `language_server.exe` send its traffic through your own
server, so Google sees a US egress IP instead of a blocked region.

> ⚠️ **This is not a public proxy service.** There is no shared server here. You need your
> own VPS (Oracle Cloud free tier works) and your own credentials. The repo ships the client
> and the deployment playbook — not a tunnel.

---

## 1. 问题

Antigravity 在有地区限制的网络里，带凭据的请求会被拒：

```
HTTP 400 FAILED_PRECONDITION: User location is not supported for the API use.
```

根因不是网络不通，是**出口 IP 的国家**。所以方向很明确：让请求从一个被接受的国家出去。

**几个已经验证过的错误方向**（省下你同样的时间）：

| 尝试 | 结果 |
|---|---|
| 直接裸连 | 出口判 CN → 400。**这是起点，不是诊断项。** |
| Cloudflare WARP | 出口仍判 CN（WARP 是承载，不是出口） |
| Cloudflare Worker 中转 | Worker 出口段 `104.28.x` 被 GeoIP 双库判 CN，Smart Placement 部署 8 小时无效 → **CF 侧无解** |
| mihomo TUN 模式 | 与 WARP 抢路由（最长前缀匹配压过 metric），失败 |

**成立的方向**：自己的 VPS 当出口。核心价值很朴素 —— **出口 IP 从"共享池"变成"独享"**，不是造了什么新协议。

---

## 2. 架构

```
  language_server.exe  (Antigravity 的语言服务器)
        │
        │  version.dll   ← MinHook 钩 Winsock，仅对目标进程生效
        ▼
  mihomo  127.0.0.1:7897            ← 规则分流（国内直连 / 其余走隧道）
        │
        │  socks5 → 127.0.0.1:7899
        ▼
  hysteria.exe (Hysteria2 客户端)    ← 主力：QUIC / UDP 8443
        │
        ├──────────────► 你的 VPS  ──►  Google API
        │                   (US egress)
        │
        └─ 兜底：mihomo 内 ss2022 / TCP 443（慢很多，但 hy2 挂掉时不断网）
```

**为什么主力是 Hysteria2**：同机同分钟、同一个 10 MB 文件实测 —— ss2022/TCP443 只有
9–16 KB/s（被 RTT 600 ms × 64 KB 窗口卡死，再加 1.8% 丢包），Hysteria2 跑到 **1.65 MB/s**。
QUIC 的接收窗口不受这个限制。旧的 ss2022 节点保留在 fallback 组里当兜底。

---

## 3. 快速开始（客户端）

### 前提

- **x64 Windows 10 / 11**，PowerShell 5.1（系统自带）
- 一个已经部署好的 VPS（见 §5），或别人的服务端 + 凭据
- **Cloudflare WARP 必须关闭**（或用 `warp-cli tunnel ip add <VPS_IP>` 把 VPS 排除出隧道）
- 端口 `7897` / `7898` / `7899` 空闲
- **不需要管理员权限**，脚本全程不提权
- 杀软可能拦截（要改系统代理 + 写注册表），必要时把目录加白名单

### 三步

```powershell
git clone https://github.com/<you>/ag-egress.git
cd ag-egress

powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
```

`setup.ps1` 会问三样东西，然后生成三份**含凭据的本地配置**（已被 `.gitignore` 排除，永不入库）：

| 问什么 | 从哪来 |
|---|---|
| VPS host / IP | 你的服务器公网地址 |
| shadowsocks-2022 密码 | 44 字符 base64，服务端生成 |
| hysteria2 密码 | 服务端生成 |

然后双击：

```
start-ag-proxy.bat
```

看到自检 `[E]` 段的**出口国家不是 `CN`**，就可以启动 Antigravity 了。

用完双击 `stop-ag-proxy.bat`。

> 除了 `setup.ps1` 之外没有别的安装步骤 —— 依赖的 mihomo 内核、hysteria 客户端、GeoIP 数据
> 和 DLL 都已经在仓库里，不需要另外下载。

---

## 4. 自检输出怎么读

`ag-proxy-check.ps1` 分六段 `[A]`–`[F]`。**别只看最后的 RESULT。**

- `[A]` WARP 状态 —— 好状态是 `Disconnected`（`Get-Service` 会误报，脚本问的是 `warp-cli`）
- `[B]` mihomo 在听 7897
- `[B2]` hysteria 在听 7899
- `[D]` Cloud Code 端点 —— **`401` 只代表链路通，不代表地区检查通过**
- ★ `[E]` **隧道出口国家** —— 这才是有意义的前置判据，必须 **不是 CN**
- `[F]` 直连对照 —— 通常是 CN，用来证明隧道确实改变了出口

> **唯一真正的验收标准**：启动 Antigravity，发一条消息，能正常回答。
> 无 token 的请求根本不触发地区检查，所以 401 永远不是绿灯。

---

## 5. 服务端

服务端是一台 Linux 主机（本项目用 Oracle Cloud Always Free，Ubuntu 24.04），需要：

- **TCP 443** —— sing-box / shadowsocks-2022（兜底链路）
- **UDP 8443** —— Hysteria2（主力链路）
- 云控制台 Security List **和** 实例 `iptables` **两层都放行**

完整步骤见：

- [`OCI出口搭建指南-Antigravity.md`](OCI出口搭建指南-Antigravity.md) — 从零建实例、两层防火墙、三态诊断
- [`oci-egress/REBUILD-CHECKLIST.md`](oci-egress/REBUILD-CHECKLIST.md) — 实例被收回时的重建清单
- [`oci-egress/rebuild-server.sh`](oci-egress/rebuild-server.sh) — 一键重建（`sudo bash rebuild-server.sh '<KEY>'`）
- [`oci-egress/install-hysteria2.sh`](oci-egress/install-hysteria2.sh) — 部署 Hysteria2

> 文档里出现的 `203.0.113.10` 是示例地址（RFC 5737 保留段），换成你自己的 VPS 地址。
> `198.51.100.20` 同理，用来表示"直连时的本地出口"。

---

## 6. 目录结构

```
start-ag-proxy.bat            起：hysteria → mihomo → 自检 → 系统代理
stop-ag-proxy.bat             停
fix-network.bat               ★ 开机后网络不通时双击它
setup.ps1                     ★ 首次配置：生成含凭据的本地配置
ag-proxy-check.ps1            六段自检
system-proxy.ps1              系统代理开/关（HKCU）
system-proxy-autoclean.ps1    重启后自动撤销系统代理
net-rescue.ps1                fix-network.bat 的本体

ag-proxy-dll/                 version.dll（Winsock 钩子）+ config.json
mihomo/                       mihomo 内核 + GeoIP 数据 + config.example.yaml
hy2/                          hysteria.exe + client.example.yaml
oci-egress/                   服务端部署与重建脚本
_tools/                       U 盘打包器、A/B 测试配置

OCI出口搭建指南-Antigravity.md  ★ 服务端完整手册
GCP出口搭建指南.md             备选方案 / 计费说明
多端接入计划-OCI出口.md         手机 / PC 多端接入与性能实测
docs/OCI-全部配置总览.md        ★ 两台 OCI 实例的全部配置（公开脱敏档案）
skills/oci-a1-ops/              A1 执行端运维 / 签到排障 skill + 脚本
BACKLOG.md                    待办与"明确不做"的事
```

**文件名里的 `.example`**：模板。`setup.ps1` 从它生成真实配置（`config-proxy.yaml`、`client.yaml`），
真实文件在 `.gitignore` 里。

**要拷到另一台电脑 / U 盘**，别手工挑文件，跑打包器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _tools\build-usb-package.ps1
```

它会输出一个自包含目录（含 `MANIFEST.txt` 和每个文件的 MD5），并强制校验 `.bat` 是 CRLF。

---

## 7. 排障

| 症状 | 先查这里 |
|---|---|
| Antigravity 仍然 400 | `[E]` 出口国家。是 CN 就说明隧道没生效 |
| 开机后整台机器"断网" | 双击 `fix-network.bat`。最常见原因是上次没停代理，系统代理指向死端口 |
| 到 VPS 的 443 全超时，但 22 能连 | WARP。`warp-cli status`，断开或把 VPS 加进 Exclude |
| 能连但极慢 | 看 `[B2]`：hy2 没起来就退回 ss 兜底了（慢 100 倍） |
| `[0/4]` 显示 `[SKIP]` | 没装 Antigravity。**不是错误** —— 此时它就是普通系统代理 |
| 改了服务器 IP 后全挂 | `mihomo/config-proxy.yaml` 的 `server` 和 `hy2/client.yaml` 的 `server` 都要改 |

### 三态诊断（连不上时分辨是哪一层）

| 现象 | 含义 |
|---|---|
| `TIMEOUT`（静默丢弃） | 云控制台 **Security List** 没放行 |
| `no route to host` | 实例 **iptables** 在 REJECT |
| `Connection refused` | 两层都通了，只是服务没起 |

> 注意：对默认拒绝的云主机做 TCP 探测，`TIMEOUT` 是正常现象，**不要**据此断言"IP 被封"。

---

## 8. 安全与责任

- **仓库里没有任何凭据**。`setup.ps1` 生成的三个文件、所有日志、`local/` 都在 `.gitignore` 里。
  如果你 fork 了这个仓库，**不要把自己的配置提交上去**。
- `ag-proxy-dll/version.dll` 是一个 MinHook 编译产物（**本仓库不含其源码**），只注入
  `language_server.exe` / `agy.exe` 等目标进程，作用是让这些进程的 socket 走本地代理。
  杀软可能报毒 —— 这是二进制注入类工具的常态，请自行判断是否接受。
- 这套方案依赖**你自己的** VPS 与**你自己的** Google 账号。请遵守你所在地的法律法规，
  以及 Google 的服务条款。作者不对使用后果承担任何责任。
- 服务器 IP 一旦公开就等于公开了攻击面。**别把真实 IP 提交到这个仓库。**

---

## 9. License

代码部分 MIT，见 [LICENSE](LICENSE)。
随仓库分发的第三方二进制（mihomo、hysteria、GeoIP 数据）遵循各自许可证，见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
