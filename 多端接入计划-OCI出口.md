# 多端接入计划 —— 复用现有 OCI 出口到 PC 与安卓

> 2026-09-20 · 目标：**PC（Windows）+ 安卓手机**都用上已跑通的 OCI 出口
> （`203.0.113.10`，Ashburn / US），且不破坏现有 Antigravity 链路。

---

## 0. 一句话结论

| 端 | 做什么 | 服务端要改吗 |
|---|---|---|
| **安卓** | 装 CMFA（或 SFA），填一个 ss2022 节点 | **不用**（阶段三可选加端口） |
| **Windows** | 不动现有链路，把系统代理指向已有的 `127.0.0.1:7897` | **不用** |

**顺序建议：先做手机**（纯增量、零风险），PC 侧最后再说。

---

## 1. 现状：服务端参数（照抄即可）

| 项 | 值 |
|---|---|
| 服务器 | `203.0.113.10`（OCI 临时公网 IP，终止重建才会变） |
| 端口 | **443** |
| 协议 | Shadowsocks **2022-blake3-aes-256-gcm** |
| 密码 | 见 `mihomo/config-proxy.yaml` 的 `password` 字段，或 `oci-egress/sing-box-server-config.json` |
| 服务端软件 | sing-box（systemd：`sing-box`） |
| 出口归属 | `US` / Ashburn / AS31898 Oracle ✅ |
| 客户端现有 | Windows：mihomo（`D:\v2rayN_v5.39\v2rayN-Core\Clash.Meta-windows-amd64-compatible.exe`），端口 `7897` |

---

## 2. 动手前必须接受的三个现实

### ① 「50 Mbps 机型上限」= ⚠️ **未核实，别当事实用**

🔴 **2026-09-20 复核：这个数字没有官方出处。** Oracle 官方 Always Free 页面只写
AMD / 最多 2 台 / 单个 AD / 绑定家乡区，**不写 OCPU、内存、带宽**。第三方有写 0.48 Gbps 的。

**实测（2026-09-20，服务器上跑的）**：出口到 Cloudflare 10.5 MB/s、到中国阿里镜像 5.8 MB/s，
`load average` 0.08～0.48（CPU 空闲）。**服务器侧根本不是瓶颈**，
真正的瓶颈是「用户侧 ISP ↔ 美东」的国际链路（RTT 580–650 ms + 约 1.8% 丢包）。
详见 §3.7 与坑清单。

### ② 10 TB/月免费出站额度，理论上是能跑超的

算一下：6.25 MB/s × 2,592,000 秒（30 天）≈ **16 TB > 10 TB**（按上条的存疑速率推的，量级参考即可）。
也就是**持续满速跑满一个月会超额并真扣钱**（已升 PAYG，保护已失效）。

日常刷网页、看视频远达不到持续满速，实际安全。
**但别拿它挂机下载 / 跑 P2P / 做旁路中转。** 那种用法几天就能烧掉额度。

> 这正是 §已设 1 SGD 预算的意义 —— 真超了你会先收到邮件。

### ③ ★ 服务端只放行了 **TCP** 443，UDP 443 是断的

现有两层防火墙：
- 云控制台 Security List：`IP Protocol = TCP`，`Destination Port Range = 443`
- 实例 iptables：`-p tcp --dport 443`

**UDP 443 在云防火墙就被静默 DROP**（不会报错，只会 TIMEOUT）。

> 🔴 **2026-09-20 修正（之前这里写错了）**：
> 我原先写「手机端必须把 UDP 关掉」—— **这条作废**。
> - `udp: false` 是 **mihomo / CMFA 专有**字段；**Hiddify（sing-box）和 v2rayNG（xray）根本没有这个开关**，那条建议在这两个客户端上没法执行。
> - 实测 `sudo ss -lntup | grep 443`：sing-box **本来就在听 UDP 443**（`network` 字段默认 "all"），
>   只是被两层防火墙挡着。**所以正解不是关 UDP，是开 UDP。**
> - 想让 ping 之外的 QUIC 类应用正常，补两处即可：Security List 加 **UDP 443** 入站
>   + `iptables -I INPUT 1 -p udp --dport 443 -j ACCEPT` + 持久化。**sing-box 配置一个字都不用改。**

**现状（2026-09-20）**：Hysteria2 已部署在 **UDP 8443**，与 sing-box（TCP 443）并存。
UDP 8443 的 Security List 入站规则是主人手动加的；`ss -lntup` 可见三个监听器同时在。

---

## 3. 阶段一：安卓手机（主力，今天能做完）

### 3.1 客户端选型

| 客户端 | 内核 | 为什么选 / 不选 | 结论 |
|---|---|---|---|
| **Clash Meta for Android（CMFA）** | mihomo | 和 PC 同一个内核 → 规则语法、术语、排查方法**完全一致**，一套知识两处用。UI 最成熟，支持分应用。 | ✅ **首选** |
| **sing-box for Android（SFA）** | sing-box | 与**服务端**同内核，配置可直抄服务端那份 JSON。 | ⚠️ 备选：想让两端内核统一时选它 |
| v2rayN / 各类"一键"客户端 | 混杂 | 来源不明的多，且本场景用不上 | ❌ |

> 我的建议是 **CMFA**。理由：你 PC 上的配置、规则、坑清单全是 mihomo 语义，
> 手机换成 sing-box 等于要维护两套心智模型，出问题还得重新学一套排查方法。
> 除非你明确想让"手机和服务端同内核"，否则别自找麻烦。
>
> ⚠️ **但 CMFA 不在 Google Play**（只走 GitHub releases）。
> 如果只愿从商店装，见下面 3.1b 的商店路线。

### 3.1b 只想从 Google Play 装 —— 那就这么选

| App | 内核 | ss2022 | Hysteria2 | 结论 |
|---|---|---|---|---|
| **Hiddify Next** | sing-box | ✅ | ✅ **实测已通**（2026-09-20） | ✅ **首选** —— 认 `ss://` 扫码，UI 友好，跨平台 |
| **v2rayNG** | xray | ✅（xray 官方 method 列表含 `2022-blake3-aes-256-gcm`） | ❌ | ✅ 可用（**只能连 ss 节点**） |
| **sing-box（SFA）** | sing-box 官方 | ✅ 原生 | ✅ | ⚠️ **不推荐走扫码** —— 见下方红框 |
| **v2rayTun** | **xray**（GitHub `LXST-CODE/v2RayTun` 自述 "based on Xray core and AWG core"） | ✅ | ❌ **不支持** | ⚠️ **只能连 ss 节点**，喂 hy2 链接必然不通 |
| **NekoBox / V2Box** | sing-box | ✅ | ✅（均在 Hysteria2 官方第三方列表内） | ✅ hy2 备选 |
| **Shadowrocket** | — | — | — | ❌ **别装 —— 山寨** |

> #### ★ 为什么 v2rayTun 用不了 Hysteria2（2026-09-20 查证，不是猜测）
>
> 1. **内核是 xray**。仓库 `LXST-CODE/v2RayTun` 自述 "Proxy client based on Xray core
>    and AWG core"。Xray **出站协议列表里只有 `Hysteria`（一代），没有 Hysteria2**
>    （来源：xtls.github.io/config/outbounds/）。一代和二代协议不兼容。
> 2. **Hysteria2 官方维护的第三方客户端列表里没有 v2RayTun**
>    （数据源 `apernet/hysteria-website/docs/assets/3p.json`）。
>    列表里安卓端的 hy2 客户端是：Bedlam、Clash.Meta、Hiddify Next、Kitty Pro、
>    NekoBox for Android、sing-box、V2Box。
> 3. v2RayTun 自己的介绍也只列 **VLESS / VMess / Trojan / Shadowsocks / SOCKS**。
>
> → **v2rayTun 不是坏了，是拿错了节点。给它 `ss://`，别给它 `hysteria2://`。**
> 三条证据互相印证，可以定案。

> #### ⚠️ SFA 不能扫 `ss://` 二维码（实测报错，2026-09-20）
>
> 用 SFA 扫 `ss://` 二维码会报 **"Not a valid sing-box remote profile URI"**。
> 这是 SFA 的设计：它的扫码器只接受
> `sing-box://import-remote-profile` 链接 / 远程配置 URL / 编码后的 profile 内容，
> **不解析 Shadowsocks 分享链接**。
>
> 同一张二维码在 **v2rayNG / Surfboard / Shadowrocket** 里都能正常导入
> （GitHub 233boy/sing-box#64 有同样的报告）。
>
> **SFA 官方支持的导入方式只有这些**（见 sing-box-for-android 源码 `ProfileImportHandler`）：
> 1. 本地 JSON 配置文件（系统文件选择器）
> 2. `sing-box://import-remote-profile` 链接
> 3. 远程配置 URL（Remote profile，支持后台同步）
> 4. QR Stream（QRS，多帧，用于超长配置）
>
> → 想留在 SFA 就得**导入完整 JSON 配置**，而那需要把文件传到手机上，
>   跟下面「别用传文件」的原则冲突。**所以换客户端更省事。**

**★ Shadowrocket 没有安卓版。** 它官方是 **iOS 独占**（App Store 列的是
iPhone / iPad / Mac / Apple TV），从未发布安卓版。
Google Play 上挂这个名字的全是仿冒品 —— 真实风险是**窃取节点密钥**、插广告、带木马。
手上已经有真密钥了，别喂给来路不明的 App。

**★ 通用硬判据（30 秒，比任何评测都准）**：
加节点时看「加密方式 / 密码套件」下拉框里有没有 **`2022-blake3-aes-256-gcm`**。

- ✅ 有 → 能用，直接填（IP `203.0.113.10` / 端口 `443`）
- ❌ 只有 `chacha20-ietf-poly1305` / `aes-256-gcm` → 那是**老版 Shadowsocks**，
  和本服务端对不上，连上了也不通 → 卸载换下一个

> ⚠️ 装完必须**关 UDP**（§2③：服务端 UDP 443 在云防火墙被静默 DROP）。
> ⚠️ **别同时装多个并都开着** —— Android 只允许一个 VPN 连接，第二个会抢掉第一个。

### 3.2 下载来源（★ 只从官方，别用第三方 APK 站）

| 客户端 | 官方来源 | 当前版本（2026-09） | 包名 |
|---|---|---|---|
| CMFA | GitHub `MetaCubeX/clashmetaForAndroid` 的 Releases | 2.11.33 | `com.github.metacubex.clash.meta` |
| SFA | GitHub `SagerNet/sing-box` Releases 的 `sing-box-for-android-*.apk`，或 **F-Droid** | 1.14.0 | `io.nekohasekai.sfa` |

安装时会要求「允许未知来源」+ 首次启动要授予 **VPN 权限**（这是它接管流量的方式，正常，必须允许）。

### 3.3 节点参数（照抄）

| 字段 | 值 |
|---|---|
| 类型 | Shadowsocks |
| 服务器 / 地址 | `203.0.113.10` |
| 端口 | `443` |
| 加密方式 / 密码套件 | `2022-blake3-aes-256-gcm` |
| 密码 | 从 `mihomo/config-proxy.yaml` 复制 |
| **UDP** | ❌ **关闭**（见 §2③，服务端 UDP 443 不通） |
| 名称 | `ag-oci` |

### 3.4 导入方式（★ 别用"传文件"）

| 方式 | 做法 | 评价 |
|---|---|---|
| ✅ **扫码** | PC 上生成 `ss://` 链接的二维码 → 手机客户端扫码导入 | **推荐**。密钥不过任何第三方，屏幕上扫一下就行 |
| ⚪ 手输 | 手动填 5 个字段 | 可行，密码 44 字符，容易打错且错了**不报错只是连不上** |
| ❌ 传 yaml / 截图发微信 | 把配置发到微信/邮件/云盘再在手机打开 | **别做**。含密钥，会在这些服务里留痕 |

> 需要的话我可以本地生成 `ss://` 链接和二维码 PNG，你扫一下即可 —— 全程不出本机。

### 3.5 模式选择

| 模式 | 效果 | 建议 |
|---|---|---|
| **规则（Rule）** | 国内直连、境外走隧道 | ✅ **日常用这个**。省额度、国内 App 不绕美国 |
| 全局（Global） | 全部走隧道 | ❌ 慢，且白烧出站额度 |
| 分应用 | 只让指定 App 走 | ✅ 想精确控制时用 |

### 3.6 验证（一条就够）

手机浏览器打开：

```
https://ipinfo.io/json
```

| 看到 | 结论 |
|---|---|
| `"country": "US"`，`ip` = `203.0.113.10` | ✅ 成功 |
| `country` 是 `CN` 或显示你本地出口 | ❌ 没走隧道，检查节点是否选中、VPN 权限是否授予 |
| 一直转圈 | 先查 §3.7 的 IPv6（最常见），再查密码是否打错 |

### 3.7 ★★ Hiddify 必调两项：关 IPv6 路由 + DNS 域名策略改 ipv4_only

> **为什么**：OCI 这台 VM **完全没有全局 IPv6**（`ip -6 addr show scope global` 为空，
> `curl -6` 返回 000）。但手机侧会把域名解析出 AAAA，然后把 **IPv6 连接**送进隧道 →
> 服务端只能回 `dial tcp6 ...: connect: network is unreachable`。
> **每一个 IPv6 连接都是必死的，跟网站没关系。**
>
> 实测日志（2026-09-20，主人手机 198.51.100.20）：
> ```
> reqAddr=[2606:4700:7::da]:443     → Cloudflare   network is unreachable
> reqAddr=[2a04:4e42:400::396]:443  → Fastly       network is unreachable
> reqAddr=[2607:f8b0:4004:c29::64]:443 → Google    network is unreachable
> reqAddr=[2620:1ec:33::11]:443     → Microsoft    network is unreachable
> reqAddr=[2600:1901:0:47fc::]:443  → Google Cloud network is unreachable
> ```
> 症状表现：**Cloudflare 系站点最惨**（`speed.cloudflare.com` 这类），
> 其他站点靠 Happy Eyeballs 回退到 IPv4 所以看起来"没事"。

**改两处（Hiddify → 配置选项）：**

| 位置 | 项目 | 改成 |
|---|---|---|
| 路由选项 | **IPv6 路由** | **关闭 / 禁用** |
| DNS 选项 | **远程 DNS 域名策略** | **`ipv4_only`**（`prefer_ipv4` 次之） |
| DNS 选项 | **直连 DNS 域名策略** | **`ipv4_only`** |

改完**断开重连一次**（清 DNS 缓存）。

> ⚠️ 网上普遍说"别乱关 IPv6"—— 那条建议的前提是**出口有 IPv6**。
> 我们这台没有，所以这里是**例外**：不关就是每个 IPv6 连接都撞墙。

**改完自测**：手机浏览器开 `https://speed.cloudflare.com/` 应该能正常出数了。
服务端可复核：`sudo journalctl -u hysteria-server -n 50` 里 `dial tcp6` 报错应消失。

**替代方案（更彻底但要动控制台）**：给 OCI VCN / 子网 / VNIC 加 IPv6 CIDR，
让服务器真正有 IPv6。属于结构性改造，不是修 bug 的必要条件，**先不做**。

---

## 4. 阶段二：Windows PC

### 4.1 先说结论：**框架不动，只换上游**（2026-09-20 更新）

> 🔴 **本节原来的结论是「不要动现有链路」，已作废。**
> 原因：实测发现原来的 ss/TCP443 上游**本身是坏的** ——
> 同一台 PC、同一分钟、同一个 10 MB 文件，ss 只有 **9~16 KB/s**，
> 换成 hy2 是 **1.65 MB/s（约 100~180 倍）**。这不是"要不要优化"的问题，是"原来就是残废"。
> 详见 §9.1。

**改的只是上游那一段，外面这圈一律不动：**
- `start-ag-proxy.bat` → mihomo:7897 → DLL hook → Antigravity **这套框架保持原样**
- mihomo 仍然负责**全部规则分流**（`GEOSITE,cn` 直连等），仍然监听 7897
- DLL hook、系统代理开关、自检脚本的入口都没变
- 只把 mihomo 的上游从「ss/TCP443」换成「本地 hy2 的 SOCKS5」，
  并且保留 ss 作为 **fallback 兜底**（挂了自动降级，不断网）

**不换 GUI 客户端的理由没变**：端口冲突、DLL 部署步骤丢失，收益只是"多个托盘图标"。
真正的瓶颈从来不是 GUI，是协议。**所以 PC 侧仍然是"复用"路线，不重装。**
具体改动清单与实测结果见 **§9.7**。

### 4.2 路线 A（推荐先做）：系统代理指向已有的 7897

mihomo 的 `mixed-port: 7897` 已经是 HTTP + SOCKS 合一的端口，
**直接把 Windows 系统代理指过去就能用，不用装任何新东西。**

步骤：
1. 先跑 `start-ag-proxy.bat`（必须，否则代理端口没人监听）
2. Windows 设置 → 网络和 Internet → 代理 → 手动设置代理 → 打开
   - 地址：`127.0.0.1`
   - 端口：`7897`
3. 浏览器访问 `https://ipinfo.io/json` → 应为 `US`

⚠️ **一个必须记住的副作用**：
`stop-ag-proxy.bat` 停掉 mihomo 之后，**系统代理仍指向 7897，但那个端口已经没人听了 → 整个浏览器断网**。
表现为"关了代理反而上不了网"。

→ 建议：给 `start` / `stop` 两个 bat 各加一步自动开关系统代理（改注册表 `Internet Settings`）。
这一步我可以顺手加，你说一声。

### 4.3 路线 B（可选升级）：用现代 GUI 客户端接管

如果手动开关确实烦，再考虑升级。**前提是把现有链路整个迁过去，不是并行跑。**

推荐 **Clash Verge Rev**（Tauri 2 + 内置 mihomo 内核，2026 年仍在维护），
比 `mihomo-party` 更适合本场景（跨平台、TUN/系统代理一键切换、配置管理清晰）。

迁移要点：
- 让它**导入现有 `mihomo/config-proxy.yaml`**，并把 **mixed-port 设为 7897**
  —— 这样 Antigravity 的 DLL hook 不用改，仍然指向 7897
- ⚠️ **端口冲突是最大的坑**：`start-ag-proxy.bat` 会启动一个 mihomo 占 7897。
  两者同时跑 → 后者起不来或被前者抢端口 → **必须二选一，不能并存**
- ⚠️ **`start-ag-proxy.bat` 里的 DLL 部署步骤不能丢**（Antigravity 升级会清空 `resources\bin`）。
  迁移后这一步要另外安排（保留一个只做 DLL 部署的脚本）

### 4.4 为什么不直接用现成的 v2rayN

`D:\v2rayN_v5.39\` 里**只有 `v2rayN-Core` 一个目录**，GUI 主程序 `v2rayN.exe` 在它里面，
版本 5.39，核心文件是 **2022 年**的（xray/v2ray 2022-06，clash 2022-08）。

- 它现在只是被当作 **mihomo 内核的存放目录**在用，GUI 本身是闲置状态
- 5.39 太旧，对 2022 协议（ss2022）的支持和规则数据文件都是老版本
- 要 GUI 就上现代客户端，不要起一个 4 年前的壳

---

## 5. 阶段三（可选，但推荐做）：给手机单独端口 + 独立密钥

### 为什么要做

现在 PC 和手机**共用同一个密码**。技术上没问题（ss2022 每个连接独立 salt，多设备并发无冲突），
但有两个实实在在的好处值得花这 10 分钟：

1. **凭据可单独吊销** —— 手机丢了、或哪天把配置误发出去了，只需改手机那个端口的密码，PC 不受影响
2. **服务端可按端口区分设备** —— 排查"到底是手机还是 PC 在烧流量"时一眼看清

### 改动三处（缺一不可，参考 `OCI出口搭建指南-Antigravity.md` §4「两层防火墙」）

**① 服务端 `sing-box` 配置**（`/etc/sing-box/config.json`）—— 加一个 inbound：

```json
{
  "type": "shadowsocks",
  "tag": "ss-phone",
  "listen": "::",
  "listen_port": 8443,
  "method": "2022-blake3-aes-256-gcm",
  "password": "<给手机新生成一个，别和 PC 共用>"
}
```

生成新密码：`sudo sing-box generate rand --base64 32`（必须是这个，32 字节 base64 = 44 字符）

然后：`sudo systemctl restart sing-box` → `sudo ss -lntp | grep 8443` 确认在听

**② 云控制台 Security List** —— 加一条入站：
`Source CIDR 0.0.0.0/0` / `IP Protocol TCP` / `Destination Port Range 8443`

**③ 实例 iptables** —— 插到 REJECT 之前：

```bash
sudo iptables -I INPUT 1 -p tcp --dport 8443 -j ACCEPT
sudo netfilter-persistent save
sudo grep -c 8443 /etc/iptables/rules.v4     # 返回 >=1 才算持久化成功
```

> 三层都要改。**只改服务端配置不改防火墙 = 手机连上来是 TIMEOUT**，
> 而且这个 TIMEOUT 不报错，很容易误判成"密码错了"。

改完把新配置同步留档到 `oci-egress/sing-box-server-config.json`。

---

## 6. 验收清单

**手机**
- [ ] 从官方源安装 CMFA（或 SFA），授予 VPN 权限
- [ ] 节点填对：IP `203.0.113.10` / 端口 `443` / `2022-blake3-aes-256-gcm`
- [ ] **UDP 已关闭** ★
- [ ] 规则模式（不是全局）
- [ ] `https://ipinfo.io/json` → `country = US`

**PC**
- [ ] `start-ag-proxy.bat` 已跑，自检 `[E]` = `US`
- [ ] Windows 系统代理 = `127.0.0.1:7897`
- [ ] `https://ipinfo.io/json` → `country = US`
- [ ] 记住：**停了 mihomo 就要关系统代理**，否则断网

**两端共存**
- [ ] Antigravity 仍正常（手机加进来不应影响 PC 链路）
- [ ] 服务端 `systemctl status sing-box` 正常

---

## 7. 坑清单

| 现象 | 真正原因 | 解法 |
|---|---|---|
| ★ **某些站点（尤其 Cloudflare 系）完全打不开，其他站点正常** | **手机把域名解析成 AAAA，把 IPv6 连接送进隧道；OCI VM 没有全局 IPv6** → `dial tcp6: network is unreachable` | **关 IPv6 路由 + DNS 策略改 `ipv4_only`**（§3.7） |
| 手机连不上，TIMEOUT | 端口/密码错，或**只改了服务端没改防火墙** | 三态诊断：TIMEOUT = 云层；`no route to host` = 实例 iptables |
| PC 关了代理反而断网 | 系统代理仍指向 7897，但 mihomo 已停 | 关系统代理（§4.2） |
| 新装 GUI 后 Antigravity 400 | 7897 被两个 mihomo 抢，或 DLL 没部署 | 二选一，别并存；保留 DLL 部署步骤 |
| 手机慢（~104 KB/s 卡住不动） | **RTT 600 ms × 64 KB 窗口**给的硬天花板（≈107 KB/s），不是丢包、不是机型 | 走 Hysteria2（QUIC）；或做多连接聚合 |
| Hysteria2 连上但流量全断 | 服务端设了 `bandwidth:` → brutal CC 按设定速率猛灌 → 丢包 ~97% | **删掉 `bandwidth:`**，回退自适应 BBR |
| 月末收到 OCI 预算告警邮件 | 出站流量超 10 TB，或误开了付费资源 | 去 `Cost Analysis` 按服务维度查是谁 |

---

## 8. 密钥处理纪律

- 密码在 `mihomo/config-proxy.yaml` 和 `oci-egress/sing-box-server-config.json` 里，**README 已标注"含密钥，勿外传"**
- 导到手机**走扫码，不走文件传输**（§3.4）
- 阶段三做了之后，PC 与手机用**不同密码**，任一泄露只影响一端
- 别把含密钥的 yaml 截图发到任何聊天/云服务
- `_tools/hy2-bbr.yaml`、`_tools/hy2-brutal.yaml` 里也有 hy2 密码 → 同样别外传

---

## 9. ★ 性能实测与天花板（2026-09-20 22:00–22:40 实测）

### 9.1 最重要的一条：**PC 现有的 ss 链路是坏的，hy2 快 100 倍以上**

同一台 PC、同一时刻、同一个 10 MB 文件（`speed.cloudflare.com/__down?bytes=10000000`）：

| 链路 | 结果 |
|---|---|
| **旧：ss2022 / TCP 443**（经 mihomo 7897） | 60 s 超时，只拿到 560 KB / 938 KB → **9,346 / 15,646 B/s** |
| **新：hy2 / UDP 8443**（官方 hysteria 客户端） | 10 MB 完整下完 → **1,690,200 / 1,648,303 B/s** |

**≈ 100–180 倍。** 原因不是配置错，是 **TCP 在这条链路上的物理天花板**：
RTT 600 ms，单条 TCP 窗口 64 KB → 上限 ≈107 KB/s，再叠加 1.8% 丢包就掉到 10 KB/s 级。
QUIC/hy2 的接收窗口是 20 MB → 完全不受这条限制。

→ **PC 侧也应当走 hy2。** 但 `D:\v2rayN_v5.39\v2rayN-Core\Clash.Meta-*.exe` 是
**Clash Meta v1.13.1（2022-08-29）**，**不支持 Hysteria2**（v1.15.0 才加）。
两条可行路径（都还没做，等决定）：
1. **换新版 mihomo 内核**（仍监听 7897，DLL 钩子不用改）→ 直接加 hy2 节点。
2. **保持旧 mihomo，把 hy2 挂成上游**：hysteria 客户端开 SOCKS5 `127.0.0.1:7899`，
   mihomo 里加一个 `type: socks5` 的节点指向它 → 规则分流全保留，零下载。

### 9.2 手机 vs PC：**手机侧还有约 6 Mbps 没挖出来**

| 设备 | 速度 |
|---|---|
| PC（hy2，连打 6 次，稳定爬升） | 17.1 → 22.7 → 21.9 → 23.9 → 25.1 → **25.8 Mbps** |
| 手机（hy2，speed.cloudflare.com） | 20 Mbps |

同一条隧道、同一个家庭出口 IP。→ 差距在**手机端**。最可疑的一条：

★ **Hiddify 的「TUN 实现」如果是 `gvisor`，吞吐会明显低于 `system`**
（gVisor 是用户态 TCP/IP 栈，多一次内存拷贝和协议栈开销）。
位置：**配置选项 → 入站选项 → TUN 实现**。改成 `system` 后重连再测。
这是零风险、可回退的一步。

### 9.3 服务器侧天花板

| 测点 | 数值 |
|---|---|
| 服务器 → 中国阿里镜像（38.5 MB） | **3.96 MB/s ≈ 31.7 Mbps** |
| 服务器 → Cloudflare 10 MB | 8.4 MB/s ≈ 67 Mbps |
| 服务器 `load average` | 0.17（空闲） |

**隧道已用掉实测天花板约 80%。** 剩余空间理论上还有 ~20%，但那是另一条路由的数值，
参考意义有限。

### 9.4 ⚠️ 以后测速别再用 speed.cloudflare.com

实测它现在在限速，会把结果压得很低，容易得出错误结论：
- `bytes=15000000` → **直连也 403**（不是代理的问题）
- `bytes=20000000` → 200 但**被截断到约 10 MB**
- 同一条 hy2 隧道：Cloudflare 17 Mbps vs OVH 28.9 Mbps

**换用**：`https://proof.ovh.net/files/100Mb.dat`（大文件，但也别连打太多次），
或直接下 Google Play 里的大 App 计时。

### 9.5 明确不做的（附理由，省得白折腾）

| 想做的事 | 为什么不做 |
|---|---|
| 调 QUIC 接收窗口 | 默认 stream 8 MB / conn 20 MB，600 ms RTT 下 20 MB÷0.6s ≈ 266 Mbps，**不是瓶颈**；官方文档也明说「不懂就别改」 |
| 升 A1.Flex | 服务器 CPU 空闲、出口 31.7 Mbps → **不是服务器的问题** |
| 换区域 | Always Free 只能建家乡区（Ashburn），换不了日本/新加坡 |
| 上 Brutal CC | BBR 已到天花板 80%，收益小；且实测**配了 `bandwidth: 25 mbps` 会触发 auth 404**（未解，见下） |

> #### ❓ 未解异常：客户端设 `bandwidth` 会 auth 404（2026-09-20）
>
> 用官方 hysteria 客户端（v2.12.x）+ `bandwidth: {up: 25 mbps, down: 25 mbps}`
> → `FATAL failed to initialize client {"error": "authentication error, HTTP status code: 404"}`。
> - 密码逐字节比对**一致**（`od -c` 验过）
> - YAML 解析**正常**（YAML 坏掉时报的是 `failed to read client config`，不是 auth 错误）
> - 纯数字 `25` 是错的（`invalid format: bandwidth.up`），必须写 `25 mbps`
> - 去掉 `bandwidth` 段 → 立刻正常连接
>
> 三条都验过，原因不明。**在确认无残留 hysteria 进程的干净环境下同样复现**（2026-09-20 22:51 复验），
> 所以不是残留进程污染。**因为 BBR 已经够用，不再追。** 若将来要用 Brutal，先解决这个。

### 9.7 ✅ PC 链路已切换（2026-09-20 22:40 完成并实测通过）

**改法（方案 2：不换内核，把 hy2 挂成 mihomo 的上游）**

```
language_server.exe → version.dll → mihomo :7897（全部规则分流）
    → socks5 127.0.0.1:7899 → hy2/hysteria.exe → QUIC/UDP8443 → OCI 203.0.113.10
```

| 改动 | 内容 |
|---|---|
| `hy2/`（新） | `hysteria.exe`（官方客户端 v2.12.x）+ `client.yaml`（生产配置，SOCKS5 :7899 / HTTP :7898） |
| `mihomo/config-proxy.yaml` | 新增 `ag-oci-hy2`（`type: socks5` → 127.0.0.1:7899）；`AG-TUNNEL` 由 `select` 改为 **`fallback`**（hy2 优先，ss 兜底），`interval: 60` |
| `start-ag-proxy.bat` | 3 步 → **4 步**，新增 `[1/4]` 先起 hysteria 并等 :7899 就绪 |
| `stop-ag-proxy.bat` | 3 步 → **4 步**，新增 `[3/4]` 杀 hysteria |
| `ag-proxy-check.ps1` | 新增 **`[B2]`** 检查 :7899 —— 因为 fallback 会**静默**降级到慢链路，不报错 |

**实测验证（全部通过）**

| 项目 | 结果 |
|---|---|
| 上游 hy2 SOCKS5 :7899 直测 | ✅ 出口 `203.0.113.10` / Ashburn / US |
| 经 mihomo :7897 出口 | ✅ 同一出口 |
| **DNS 透传** `www.google.com` | ✅ **200** —— 证明域名是原样交给服务端解析的，没被本地污染 |
| `cloudcode-pa.googleapis.com` | 404 = 连通（对 API 根路径 GET 本就 404） |
| 链路开销 | **无**：hy2 直连 1.6/2.46/2.53 MB/s vs 经 mihomo 2.75/2.23/2.53 MB/s |
| **兜底行为** | ✅ 杀掉 hysteria 后 90 s：速度从 **1,335,615 B/s** 掉到 **13,970 B/s**，mihomo 日志 `AG-TUNNEL[ag-oci-hy2]` → `AG-TUNNEL[ag-oci]`。**自动切换、不断网、只是慢** |

> ⚠️ **回退**：把 `AG-TUNNEL` 的 `proxies` 顺序改回只留 `ag-oci`，或直接把 `type: fallback` 改回 `select`。

### 9.8 🔴 工具坑：Git Bash 里 `taskkill` 必须用单斜杠

```bash
taskkill /F /IM hysteria.exe     # ✅ 对
taskkill //F //IM hysteria.exe   # ❌ "错误: 无效参数/选项 - '//F'"
```
`//F` **不会被 MSYS 转换成 `/F`**，taskkill 直接报错。而如果像常见写法那样
`>/dev/null 2>&1` 把输出吞掉，**你根本看不到它失败了 —— 旧进程还活着，
下一次测量就被污染了。** 2026-09-20 我就因此得出过错误结论（以为 Brutal 能连上）。

**判据**：杀完必须用 `tasklist` / `netstat` 确认端口真的释放了，别信命令「没报错」。
（另外 `kill -9 $!` 对原生 Windows 进程无效，MSYS 映射不到 PID。）

### 9.6 复现命令（工具在 `_tools/`）

```bash
# BBR 对照
_tools/hysteria.exe client -c D:/Windsurf_Workspace/ag-egress/_tools/hy2-bbr.yaml
# 另一个终端
curl.exe -x http://127.0.0.1:7898 -o NUL -w "%{http_code} %{size_download} %{speed_download}\n" \
  "https://speed.cloudflare.com/__down?bytes=10000000"
```
一键 A/B 脚本：`bash _tools/hy2-ab-test.sh`（⚠️ 里面用的 URL 已被 Cloudflare 限速，需换掉）
