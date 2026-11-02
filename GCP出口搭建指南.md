# 用 Google Cloud Platform 搭建 Antigravity 出口（替代 Cloudflare Worker）

> 2026-09-10 · 为什么需要这个
>
> Cloudflare Worker 方案已失效，且**在 CF 这一侧无解**：
> ```
> 出口 IP  104.28.240.135  → ipinfo / ip-api 双库均判 Shanghai, CN (AS13335 Cloudflare)
> CF-RAY   ...-LAX         → Worker 实际跑在洛杉矶，但出口段被 GeoIP 判为中国
> ```
> 开了 Smart Placement 8 小时后出口段纹丝不动。CF 出口 IP 池不可控，
> 一旦某段被目标服务拉黑，只能换出口。

**GCP 为什么能解决**：出口 IP 是 Google 自家的美国地址段，GeoIP 必然判 US，
不存在"被误判成中国"的问题；而且是**你独享的 IP**，不像 CF 共享池会被其他人的流量连坐封禁。

> ### 速查
> - **只想照着做** → 读 §1 → §6（GCP 实操全流程）
> - **🚨 卡在绑卡 / 结算账号** → **直接跳 §14**（大陆卡过不了，有 3 条替代路线）
> - **在纠结选哪家** → 跳 **§11 全网方案盘点**（含"免费 + 稳定"的最终结论）
> - **担心机房 IP 被验证码 / 流媒体拦** → 跳 **§12**
> - **想知道 CF 出口判 CN 还有没有救** → 跳 **§13**（★ 有一个"换岗"解法）
> - **想顺带给别人用** → §10
> - **担心哪天开始收费** → §9

---

## 一、成本（几乎免费）

| 项目 | 免费层 | 说明 |
|---|---|---|
| e2-micro 实例 | **永久免费** 1 台/月 | 仅限 `us-central1` / `us-east1` / `us-west1` |
| 30GB 标准磁盘 | 免费 | |
| 静态外部 IP | 免费 | **前提是已附加到运行中的 VM**（闲置的静态 IP 会收费） |
| 出站流量 | 1 GB/月 | 北美 → 除中国/澳大利亚外的地区。**到中国的出站不在免费额度内** |

实际花费估算：Antigravity 以文本为主，重度使用一月约 1–3 GB 回程流量，
按 GCP 到中国约 $0.12–0.23/GB 算，**每月通常不到 1 美元**。

> 需要绑定信用卡（Visa / MasterCard）才能开通，但走免费层基本不扣费。
> 建议设一个 **预算提醒**（ billing → Budgets & alerts，填 $3 ），防止意外。

### ⭐ 你已经在付的钱里就带了 $10/月（Google AI Pro 权益）

**Google AI Pro 订阅自带 Google Developer Program Premium 权益，其中包含每月 $10 的
Google Cloud credits。** 官方说明（blog.google，2026）：

> "This includes **$10 per month in Google Cloud credits** for Google AI Pro subscribers
> and $100 per month for Google AI Ultra subscribers."

也就是说：e2-micro 本身走免费层不花钱，这 $10 额度再去覆盖出站流量 →
**实际自付为零**，而且额度根本用不完。

**激活步骤**（不激活不会自动到账）：

1. 打开 <https://developers.google.com/program> 或 <https://me.developers.google.com/benefits>
2. 用**持有 AI Pro 订阅的同一个 Google 账号**登录
3. 在 Perks & Benefits → Cloud & AI Compute 找到 **Google Cloud Monthly Credits** → 激活
4. 若给的是 promo code，去 GCP Console → Billing → **Credits** → Redeem 兑换
5. 在 Billing 概览确认出现 +$10.00 余额

**注意事项**：

- 该权益**不能与家庭组成员共享**，必须是订阅者本人的账号
- AI Pro 订阅需要绑定到你的 **Google Developer Profile** 才算数
- 仍必须有 GCP Billing Account 才能生效 —— **还是要绑一张卡**（形式要求），
  但费用会被额度抵扣
- 即便有额度，**预算提醒照样设**（$3），防止额度没生效时悄悄扣费

> 另外顺带一提，这个权益包里还有 **Gemini Code Assist 更高配额**和
> **30 个 Firebase Studio 工作区**，都是随订阅白送的，不用白不用。

---

## 二、创建 VM（控制台）

1. 打开 <https://console.cloud.google.com/> → 新建项目（或选现有的）
2. 启用 **Compute Engine API**
3. Compute Engine → 虚拟机实例 → **创建实例**
   - 名称：`ag-egress`
   - 区域：选 **`us-central1`**（爱荷华，免费层区域；也可靠近 Google API）
   - 机型：**e2-micro**（共享核心，1GB 内存 —— 做流量转发完全够）
   - 启动磁盘：Debian GNU/Linux 12（bookworm），30GB 标准
   - 防火墙：先**不要**勾 "允许 HTTP/HTTPS"（用不到）
4. **预留静态外部 IP**（否则重启后 IP 会变，本地配置就得跟着改）
   - VPC 网络 → IP 地址 → 保留外部静态地址
   - 名称 `ag-egress-ip`，区域选 us-central1，层级"标准"
   - 回到 VM → 编辑 → 网络接口 → 外部 IPv4 地址选刚才保留的那个
5. **开放代理端口**（GCP 默认只放行 22）
   - VPC 网络 → 防火墙 → 创建防火墙规则
   - 名称 `allow-ag-egress`，目标：**网络标记** `ag-egress`
   - 来源 IP 范围：`0.0.0.0/0`
   - 协议端口：**tcp:8388, udp:8388**
   - 回到 VM → 编辑 → 网络标记加上 `ag-egress`

---

## 三、服务端：一键脚本（SSH 登录 VM 后执行）

用控制台的 "SSH → 在浏览器窗口中打开"，粘贴下面整段：

```bash
# 1) 安装 sing-box
curl -fsSL https://sing-box.app/install.sh | sh

# 2) 生成密钥（记下来，客户端要用）
KEY=$(openssl rand -base64 32)
echo "YOUR_KEY=$KEY"

# 3) 写配置
sudo mkdir -p /etc/sing-box
sudo tee /etc/sing-box/config.json > /dev/null <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": 8388,
      "method": "2022-blake3-aes-256-gcm",
      "password": "$KEY"
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF

# 4) 启动并设置开机自启
sudo systemctl enable --now sing-box
sudo systemctl status sing-box --no-pager
```

看到 `active (running)` 就成功了。**把 `YOUR_KEY=...` 那行的密钥复制出来。**

协议选 ss2022 的理由：配置只要几行、不需要证书、mihomo 原生支持。
GCP 是你独享的 IP，不像 CF 共享池那样被重点关照，不需要 VLESS+Reality 那种重伪装。

---

## 四、客户端：改 mihomo 配置

编辑 `mihomo\config-proxy.yaml`，做两处改动。

**① 在 `proxies:` 下新增一个节点**（把 IP 和密钥换成你自己的）：

```yaml
  - name: "ag-gcp-us"
    type: ss
    server: 34.123.45.67        # ← GCP 静态外部 IP
    port: 8388
    cipher: 2022-blake3-aes-256-gcm
    password: "你的base64密钥"
    udp: false
```

**② 把 AG-TUNNEL 组指向它**（CF 那个留着当备用）：

```yaml
  - name: "AG-TUNNEL"
    type: select
    proxies:
      - "ag-gcp-us"     # ← 放到第一位，默认走它
      - "ag-cf-us"
```

然后重启 mihomo：双击 `stop-ag-proxy.bat`，再双击 `start-ag-proxy.bat`。

---

## 五、验证（这一步不能省）

```bash
# 出口归属 —— 必须是 US
curl.exe --noproxy '*' -x socks5h://127.0.0.1:7897 "http://ip-api.com/json/?fields=status,countryCode,city,query"

# 链路通断（401 只证明"连得上"，不等于地区放行，别当绿灯）
curl.exe --noproxy '*' -x socks5h://127.0.0.1:7897 -o NUL -w "%{http_code}\n" -X POST \
  -H "content-type: application/json" -d "@mihomo/probe-body.json" \
  https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent
```

**真正的判据只有一个**：完全退出 Antigravity 重开，发一条 prompt 看还报不报
`location not supported`。前两项只是前置检查。

---

## 六、坑

| 坑 | 现象 | 处理 |
|---|---|---|
| 忘开防火墙 | mihomo 日志 `dial tcp ...: i/o timeout` | 检查防火墙规则的**网络标记**是否加到 VM 上（最常漏的一步） |
| 没用静态 IP | 重启 VM 后连不上 | 用保留的静态地址；闲置未附加的静态 IP 反而会收费，不用就删 |
| 选错区域 | 产生费用 | 必须是 us-central1 / us-east1 / us-west1 才进免费层 |
| 出站流量 | 账单超预期 | 设预算提醒；不用时**停止**实例（停止后不收计算费，静态 IP 仍按闲置计费） |
| 端口被扫 | 日志大量失败握手 | 换端口；或改用 `VLESS + Reality` 提高伪装（配置更重，按需再加） |

**回滚**：把 `AG-TUNNEL` 组的第一项改回 `ag-cf-us` 即可切回 CF 链路。

---

## 七、可选：不用时省钱

Antigravity 只在需要时开着：

- 停止实例：控制台 → 选中 → 停止（不收计算费）
- 或设自动开关：Compute Engine → 虚拟机实例 → 设置"实例计划"（Instance Schedule）

---

## 八、备选：Oracle Cloud Always Free（规格碾压 GCP）

先把一个常见误解说清楚：**"GCP 配置太低"对"做代理"这个用途不成立。**
代理转发是 IO 密集型，不是 CPU 密集型 —— sing-box 常驻内存不到 50MB，
e2-micro 那 1GB 绰绰有余。GCP 真正的短板是**出站流量只有 1GB/月**
（且到中国的出站不在免费额度内），不是 CPU/内存。

**但 OCI 仍然更宽裕**（2026 年 9 月查证 Oracle 官方文档）：

| 资源 | Oracle OCI Always Free | Google GCP 免费层 |
|---|---|---|
| CPU / 内存 | **2 OCPU + 12GB RAM**（ARM Ampere A1） | e2-micro：约 0.25 vCPU 共享 + 1GB |
| 出站流量 | **10 TB / 月**（不区分目的地） | 1 GB / 月（到中国不计入） |
| 块存储 | **200 GB** | 30 GB |
| 数据库 | 2 个自治数据库（各 20GB） | 无 |
| 负载均衡 | 1 个 10 Mbps | 无 |
| 出口 IP 归属 | 美国区域 → 判 US | Google 自家 IP → 判 US |

> ⚠️ **配额已缩水，注意**：Oracle 在 **2026 年初把 ARM 配额从 4 OCPU / 24GB
> 下调到 2 OCPU / 12GB**（官方文档现为 1,500 OCPU 小时 + 9,000 GB 小时/月）。
> 网上大量"4 核 24G 白嫖"的教程和文章都是**过时**的，别再照抄。
> 已有 4 核实例的老用户通常不会被回收，但删掉重建就只能拿 2 核。
>
> **对做代理这毫无影响** —— sing-box 常驻内存不到 50MB，2 OCPU / 12GB 是巨大冗余。

### 但最大的门槛是注册，不是技术

OCI 的注册风控是出了名的——有人一次过，有人换三张卡、四个邮箱、五种网络环境还是被拒。
有评测直言"The free tier might simply not be available to you"。**如果你已经有账号，
这一步就跳过了，直接上 OCI 是更好的选择。**

### 与 GCP 步骤的差异点

建实例的思路一样，差别在这几处：

1. **区域选择**：美国区域里 **Ashburn (us-ashburn-1) 一致性最好**，
   Phoenix / San Jose 时好时坏。选对区域能省掉很多"开不出机器"的折腾。
2. **Arm 实例常缺货**：热门区域报 `Out of host capacity`，唯一的办法是**反复刷创建页**
   直到抢到。Frankfurt / Singapore 通常几分钟就能开出来（但出口判 EU/SG，
   不影响"不是中国"这个关键属性，同样可用）。
3. **防火墙叫"安全列表 / NSG"**：OCI 里入站规则的入口是 VCN → Security Lists
   （或 Network Security Groups），不是 GCP 那种独立防火墙规则页。
   记得放行 `tcp/udp 8388`，**这一步和 GCP 一样最容易漏**。
4. **公网 IP 不用预留**（2026-09-11 修订）：OCI 的临时公网 IP 与实例生命周期绑定，
   **`reboot` / `Stop/Start` 都不会变**，只有"终止重建实例"或手动 unassign 才换地址
   （官方文档三处一致，详见 OCI 指南 §10）。→ **不需要** Reserved Public IP，
   此处早期建议"预留"是没实测的推测，已作废。
5. **服务端配置完全一样** —— 第三节那份 sing-box + ss2022 的脚本可以照抄，
   架构无关。

### ⚠️ OCI 最大的坑：闲置回收（官方阈值已确认）

这是"OCI 完全免费"的**代价**——机器可能被 Oracle 收走。

**官方判定标准**（Oracle docs，Always Free Resources）：
一个实例在**任意 7 天窗口内**同时满足以下三条，即被认定为闲置，**可能被回收**：

| 指标 | 阈值 |
|---|---|
| CPU 利用率（95th percentile） | **低于 20%** |
| 网络利用率 | **低于 20%** |
| 内存利用率（仅 ARM A1 规格） | **低于 20%** |

**回收流程**：提前 7 天发**邮件警告** → 停止实例（**不是删除**）→ 区域有容量时可重新启动。
另外：**实例连续 7 天处于"已停止"状态，会被自动销毁**。

**这对代理意味着什么**：一个只做流量转发的代理，CPU 和内存利用率长期接近 0 ——
**恰好完整符合闲置特征**。2026 年已有用户报告低流量服务被真实关停，
甚至有账号在几乎没有解释的情况下被整个终止。

### 解法：升级到 Pay As You Go（PAYG）—— 最推荐

Oracle 官方明确：**PAYG 账号的实例豁免闲置回收**，而 **Always Free 额度在 PAYG 下依然免费**。

> "Upgrade to Pay As You Go (PAYG) — best option. You still get all Always Free
> resources at no cost, but instances are exempt from reclamation."

也就是说：**升级 PAYG = 零费用 + 机器不会被收走**。这是绕开整个闲置回收问题的正解。
超出免费额度的部分才会计费，所以照样要设预算提醒。

**其他缓解手段**（不升级 PAYG 时）：

- 挂一个每 5 分钟做点真实小事（小计算 + 对外 HTTPS ping）的 cron，让利用率和网络流量不为零
- 让实例上至少跑一个常驻服务
- **把服务器当"可丢弃"的**：配置用 Terraform / 脚本固化下来，
  机器被收了重建只要一小时，而不是一场灾难
- 备份到平台外（对象存储 / rclone / 定期 dump）
- ❌ **不要用 lookbusy / stress-ng 这类纯刷负载工具** —— 可能违反 Oracle 服务条款，
  反而招致封号

### 还有一类风险：账号被风控

OCI 的账号风控比 GCP 敏感得多，常见触发点：

- **同一张信用卡注册多个账号、或同一 IP 下管理多个账号** → 可能被判定滥用而**批量封禁**
- 异常登录（异地 IP 频繁登录、SSH 爆破痕迹）
- 通过验证的账号**偶尔会被再次要求身份验证**，通不过就可能被限制

### 选型建议

| 情况 | 建议 |
|---|---|
| 已有 OCI 账号 | **用 OCI + 升级 PAYG**（零费用且豁免回收），还能顺便跑别的 |
| 没有 OCI 账号 | **先用 GCP**（注册容易 + 有 AI Pro 的 $10/月额度），OCI 并行申请当备胎 |
| 只在 VM 上跑代理 | 两者出口都判 US，**关键是实测** Google 是否接受，配置高低不影响成败 |
| **追求"绝对零费用且永不被打扰"** | **两者都不满足**。GCP 要付几毛钱买确定性；OCI 要升级 PAYG 换豁免。天下没有既免费又无条件稳定的机器 |

---

## 九、GCP 额度的生命周期：三个额度分别什么时候失效（必读）

最容易被搞混的一点：**GCP 上有三个互相独立的额度**，它们的失效条件完全不同。

| 额度 | 来自哪 | 有效期 | 与本方案的关系 |
|---|---|---|---|
| **Always Free 免费层** | GCP 自身，任何启用了结算的账号都有 | **永久**，按月重置 | ⭐ **e2-micro + 30GB 盘 + 静态 IP 就靠它**。与 AI Pro 订阅无关 |
| **$300 新用户试用** | 免费试用计划 | **90 天**，或花完 $300，**先到者为准** | 本方案基本用不到（见下） |
| **$10/月 Cloud credits** | Google AI Pro 订阅权益 | 跟着订阅走，**订阅停就没了** | 用来抵那点出站流量费 |

### 所以：AI Pro 订阅结束了会收费吗？

**答案分两层：**

- **VM 本身不会收费** —— e2-micro + 30GB 盘在 Always Free 里，
  它跟 AI Pro 订阅**毫无关系**，订阅停了照样免费。这一条是定心丸。
- **只有流量费要自付** —— Always Free 的 1GB/月出站**不包含"到中国"的流量**，
  这部分本来就是你那 $10 额度在抵。订阅结束后转为自付，
  按 $0.12–0.23/GB，实际每月就是**几毛钱人民币**的量级。

### $300 能用多久？——在本方案里几乎用不掉

关键规则：**试用期内，Always Free 范围内的用量不扣你的 $300。**

> "During your Free Trial period, when you use resources covered by the Free Tier,
> the Free Tier usage is not charged against your Free Trial credits."

所以我们这套方案（e2-micro + 20GB 盘 + 代理）在 Always Free 范围内，
**$300 一分都动不了**。唯一可能消耗它的是超出免费额度的部分，也就是那点流量费——
几十美分的量级。

**结论：$300 的真正限制是"90 天"这个期限，不是金额。** 90 天一到，
**没用完的余额直接作废**，且试用期不能暂停、不能延长。

### ⚠️ 90 天到了会发生什么（这是最容易踩的坑）

如果 90 天期满（或 $300 花完）而你没有升级到付费结算账号：

1. 免费试用结算账号**自动关闭**，项目结算被停用
2. **所有资源被停止**，Compute Engine 上的数据被**标记为删除**（可能丢失）
3. 进入 **30 天宽限期** —— 在这 30 天内升级为付费账号，**可以恢复已停止的资源和数据**
4. 宽限期过了还没升级 → **资源被永久删除**

**好消息**：Google **不会自动扣费**（"You have to opt in"），不存在醒来发现被扣钱的情况。

### 建议做法

| 动作 | 为什么 |
|---|---|
| **尽早主动升级为付费结算账号** | 不是"开始花钱"，只是启用账单。升级后：① 资源不会在 90 天后被删 ② Always Free 永久有效、额度内仍$0 ③ 解锁 GPU / Marketplace / 配额提升等试用期受限功能 ④ 剩余 credits 仍可用到 90 天期满 |
| **设预算提醒**（$1–3） | 防意外，尤其升级之后 |
| **$300 想用得值，就在 90 天内用掉** | 本方案用不到它。可以拿它去试 Cloud SQL、Dataflow、BigQuery、大规格 VM 这些**没有 Always Free** 的服务。注意：**试用期内不能加 GPU**，要加 GPU 必须先升级 |
| **别把它当生产环境** | 官方明说 Free Trial 不建议跑生产应用；真要靠它长期跑出口，升级付费账号是前提 |

> **账号一致性提醒**：$10/月 credits 必须用**持有 AI Pro 订阅的那个账号**去
> Google Developer Program 激活。如果你这次的 $300 是拿另一个新账号领的，
> 两个权益会落在两个账号上 —— 建议统一到同一个账号，别两边分开。

---

## 十、能不能当 2–3 人的常用代理？（能，但瓶颈不在技术）

### 技术上：改两行就行

架构不用动 —— GCP VM 上跑的还是那个 sing-box 出口，变的只是本地 mihomo：

```
浏览器 / 手机 / 朋友设备
     ↓ (SOCKS5 或 HTTP)
本地 mihomo:7897   ← 这里改 allow-lan: true 开放给局域网
     ↓ VLESS/SS 加密
GCP VM (sing-box) → 美国出口
```

**① 开放局域网访问**（`mihomo\config-proxy.yaml`）：

```yaml
allow-lan: true
bind-address: "*"        # 监听所有网卡；只想给局域网就写 192.168.x.x
```

同网段的设备把代理指向 `<你电脑的内网IP>:7897` 即可。

**② 规则要改成通用分流** —— 现在的规则是**专为 Antigravity 调的**
（googleapis/AI 服务走隧道，GEOSITE cn 直连，其余走隧道）。
当通用代理用，建议改成"国外走隧道、国内直连"的常规分流：

```yaml
rules:
  - DOMAIN-SUFFIX,egress.example.com,DIRECT-OUT
  - GEOSITE,cn,DIRECT-OUT
  - GEOSITE,geolocation-!cn,AG-TUNNEL
  - MATCH,DIRECT-OUT          # 兜底改直连，避免境外小站也绕一圈
```

> **更好的做法**：让朋友各自用客户端**直连 GCP VM**（把 VM 当普通 ss2022 节点），
> 不经你的电脑。这样你的机器不用长开，也不成为单点。代价是凭据要分发出去。

### ⚠️ 真瓶颈是流量，不是性能

**GCP 免费层每月只有 1GB 出站，而且到中国的流量不计入免费额度** ——
这条对"常用代理"是致命的。给你一个真实的量级感：

| 用法 | 月流量 | GCP 出站费用（约 $0.12–0.23/GB） |
|---|---|---|
| 只调 AI / 查资料 / 纯文本 | 1–3 GB | 几毛钱，$10 额度轻松覆盖 |
| 含图片的日常网页浏览 | 20–40 GB | $2.4–9，**开始吃掉额度** |
| 每天 1 小时 720p 视频 | 20–30 GB | 同上 |
| 下大文件 / 4K 视频 | 100 GB+ | **$12–23，直接超额度** |

**所以结论很明确**：

- **只为 Antigravity** → GCP 完全够。流量小，$10 额度绰绰有余，
  **你的判断是对的，确实没必要折腾 OCI**。
- **要当 2–3 人的"常用代理"** → **瓶颈立刻变成流量**，
  而流量恰好是 OCI 唯一碾压 GCP 的地方（10TB/月、不区分目的地、全免）。

**换句话说**：一旦需求从"给 Antigravity 开个专用出口"变成"几个人日常挂着用"，
**OCI 的价值就回来了** —— 不是因为配置，而是因为那 1GB vs 10TB 的差距。

### 性能与 IP 信誉（次要但要知道）

| 维度 | 现实 |
|---|---|
| 带宽 | e2-micro 共享核心，2–3 人日常浏览足够；不适合长期跑满带宽 |
| 稳定性 | 单台 VM、免费层**无 SLA**，重启需手动 |
| **IP 信誉** | ⚠️ 这是机房 IP。**Google 搜索可能频繁弹验证码**，Netflix / 部分流媒体 / 部分银行会直接拦截 —— 这是用云 IP 做通用代理的通病，不是配置问题 |

### 🚫 合规红线（三条，别碰）

1. **禁止转售或变相提供公共代理服务** —— 违反 Google Cloud / Oracle 服务条款，
   封号是标准处理。家人朋友小范围自用属于灰色地带，但**账号是你的，责任也是你的**。
2. **禁止 BT / PT 下载、爬虫滥用、加密挖矿** —— 这类行为几乎必然触发 abuse 投诉，
   账号直接封停，且申诉基本无效。
3. **IP 是固定的、独享的** —— 用的人一多、强度一大，这个 IP 被目标服务标记，
   你所有依赖它的服务（包括 Antigravity）会一起受影响。

**一句话**：2–3 人、轻中度、自用 —— 可以。想拿它当"公共小机场" —— 别，账号比省下的钱值钱。

---

## 十一、除了 GCP / OCI，还有没有更好的"免费 + 稳定"方案？

> 2026-09-11 全网盘点

### 结论先行

**没有第三个"永久免费 + 有真实 TCP 出口"的选项了。**

全世界免费层里，只有 **GCP e2-micro** 和 **OCI A1** 这两家提供"常驻 VM + 公网出口 IP"。
其余全部落在另外三类：一次性试用额度、HTTP-only 的 Serverless（跑不了代理）、或会被限时回收。

所以问题不该是"有没有更好的免费方案"，而应该是 **"要不要用每月 7 块钱，把免费层的规则成本买掉"**。

### A 类：真·永久免费常驻 VM（全集就 2 家）

| 方案 | 规格 | 出站流量 | 卡在哪 |
|---|---|---|---|
| **GCP e2-micro** | 0.25–2 vCPU 突发 / 1 GB | 1 GB/月（远中国） | 流量小 —— 但只跑 Antigravity API 完全够 |
| **OCI A1** | 2 OCPU / 12 GB | **10 TB/月** | 需绑卡 + 防闲置回收 + 账号风控 |

**GCP 胜在确定性和零维护，OCI 胜在流量。** 二者的取舍见 §8 / §9。

### B 类：能拿到 IP，但**不能常驻**（看起来很美，实际用不了）

| 方案 | 为什么不行 |
|---|---|
| **GitHub Codespaces**（免费 120 core-hrs/月） | 出口是 Azure 美国 IP，但**30 分钟无操作自动停**（上限只能调到 240 分钟），且 120 core-hrs = 2 核跑 60 小时，物理上做不到 7×24。→ 只能当**临时应急出口**，不能当主力 |
| **AWS Free Tier**（$100 + 最多再 $100） | 2025-07-15 改版后**只有 6 个月**，到期 AWS **自动关闭账号**。且是"额度制"不是"时长制"，用完即止 —— 不是永久 |
| Azure 免费账号（$200 / 30 天） | 30 天 |
| GCP $300 试用 | 90 天（见 §9） |
| Vultr $250–300 / Linode $100 / DO $200 | 一次性额度，花完即止 |
| **Fly.io / Koyeb / Render / Vercel / Netlify / Deno Deploy** | 已取消免费层，或**只给 HTTP 端口、不支持裸 TCP / WS-CONNECT** → VLESS-over-WS 根本跑不起来 |

> ⚠️ 这一栏是最容易被"看起来免费"骗到的地方。判断标准只有一条：
> **它给不给你一个能长期监听的服务端口子。** 给不了，再大的额度也没用。

### C 类：学生身份路线（如果能拿到 `.edu` / `.ac.uk` 邮箱）

| 项目 | 内容 | 关键限制 |
|---|---|---|
| **Microsoft Azure for Students** | **$100/年 + 25 项免费服务**，**无需信用卡**，在读期间可**每年续期** | B1s VM 只有前 12 个月免费；之后 $100/年大约够跑 1 台 B1s 5–6 个月 → **是"能续"，不是"永久"** |

**它的真正价值不在省钱，而在"多一个 ISP 完全不同的出口段"** ——
Azure 的 IP 段和 GCP、Cloudflare 毫无重叠，被同时误判的概率极低。
所以它最适合当**第二出口做冗余**（见下文）。

> 📌 **关于 GitHub Student Developer Pack 的时效性提醒**
> 网上大量老攻略仍在写"学生包送 DigitalOcean $200"—— **这是过期信息**。
> 2026 年的资料显示 DigitalOcean（以及 Cloudflare、GitLab、Vercel）**可能已不在合作名单内**，
> 当前能领的云类权益主要是 **Microsoft Azure**，外加 Copilot Pro、Namecheap/Name.com 域名、
> JetBrains 全家桶、MongoDB $50 等。
> **以 <https://education.github.com/pack> 实时页面为准**，别按老攻略规划预算。

### D 类：不免费，但极便宜 —— 这才是"更优解"的真正候选

| 方案 | 价格 | 月流量 | 特点 |
|---|---|---|---|
| **RackNerd 促销** | **$11–12/年 ≈ ¥7/月** | 2 TB | **续费同价**（不涨价）；洛杉矶/西雅图/阿姆斯特丹；无 API、无快照 |
| **Hetzner CX22** | €3.79/月 ≈ ¥30 | **20 TB** | 2核4G、10 Gbps 口；欧洲 IP；仅信用卡/PayPal |
| Vultr | $2.5–5/月 | 0.5–1 TB | 30+ 机房，**小时计费，随时换 IP** |
| BuyVM | $2/月 | 1 Gbps 口 | 老牌低价，含 IPv6 /48 |

**为什么这可能是最优解** —— 用"时间成本"算一遍：

| 免费标的隐性成本 | 付费 $12/年买到什么 |
|---|---|
| $300 额度 90 天到期要处理（§9） | 不用管额度 |
| OCI 闲置回收要防（§8） | 不用管回收 |
| 账号风控 / 同卡多号封禁风险 | 单一账号，无风控 |
| 出口 IP 被标记后**无法更换** | **换机房 = 换 IP**，被封 5 分钟解决 |
| 1 GB/月 流量要精打细算 | 2 TB/月，随便用 |

→ **每月一杯水的零头，买掉全部规则成本。** 如果"稳定"排在"免费"前面，直接走这条路。

### ⭐ 但真正解决"稳定性"的，不是选哪家，而是"别只有一个出口"

单出口方案的宿命就是：**出口 IP 一旦被标记或误判，整套服务当场归零**
—— 这正是 Cloudflare Worker 现在的结局（见文首）。

正确做法是让 mihomo 挂一个 fallback 组，多出口自动切换：

```yaml
proxy-groups:
  - name: AG-TUNNEL
    type: fallback              # 也可用 url-test（选延迟最低）
    proxies:
      - ag-gcp-us               # 主力
      - ag-oci-us               # 备 1
      - ag-azure-us             # 备 2（学生包路线）
      - ag-cf-worker            # 兜底：现在不通，留着不碍事
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    lazy: false
```

**规则那条不用改**（仍是 `googleapis.com → AG-TUNNEL`）。

这样做的收益：任何一路挂了/被误判，**300 秒内自动切走**，Antigravity 不会断。
你要维护的从此只是"手上至少有两个可用出口"，而不是"找到那个永远不会坏的出口"
—— 后者不存在。

### 最终选型建议

| 你的诉求 | 建议 |
|---|---|
| 只要 Antigravity 能用、零折腾 | **GCP e2-micro** 单出口，¥0–1/月 |
| 想顺带给 2–3 人用、要大流量 | **OCI A1**（升级 PAYG 免回收）+ GCP 做备用 |
| 要绝对可控、不想被免费层的规则牵着走 | **RackNerd $12/年**（约 ¥7/月），一劳永逸 |
| 手上有 `.edu` 学生邮箱 | 顺手领 **Azure for Students $100/年**，当第二出口 |
| **最稳（推荐组合）** | **GCP 主 + OCI/学生包 备 → mihomo fallback 自动切** |

> **一句话收尾**：免费方案的排列组合到 GCP + OCI 就到底了，再往下找只是在
> 试用额度和 HTTP-only Serverless 里绕圈。"更稳定"的下一个台阶不是另一个免费方案，
> 而是 **¥7/月的独享 IP** 或者 **两个出口互为备份** —— 后者免费，而且效果更好。

---

## 十二、机房 IP 的"通病"，GCP 和 OCI 一样吗？

> 2026-09-11

### 结论：大方向一样，但有 3 处实质差异

先明确一件事 —— **GCP 和 OCI 的出口都是机房 IP，性质完全相同**，
都不是住宅 IP，在 ipinfo / IPQS 这类库里都会被标成 `hosting` / `datacenter`。
所以"Google 弹验证码、流媒体拦、银行拦"这三个症状，**两家都会犯**。

但差异是真实存在的：

| 维度 | GCP | OCI |
|---|---|---|
| 出口 ASN | AS396982（Google Cloud） | AS31898（Oracle） |
| **Google 自家服务** | **略好**：出口就在 Google 网络里，到 Google API 的路径最短 | 无此优势 |
| Google 搜索验证码 | 仍会弹 —— 判据是"云 IP"这个事实，不看 ASN 亲疏 | 一样会弹，频率可能略高 |
| 流媒体（Netflix 等） | 一样：只能看全球库/自制剧，地区独占库不可用 | 一样 |
| 银行 / 金融风控 | 一样：**从美国机房 IP 登中国银行 = 高风险异地登录** | 一样 |
| **换 IP 的余地** | e2-micro 只在 3 个美国区，换了还是 Google 段 | **区域多**（Phoenix / Frankfurt / Singapore…），更容易换到"不那么脏"的段 |

> ⚠️ 别指望"GCP 是 Google 家的所以搜索不弹验证码"—— 会弹。这只是"略好"，不是"免疫"。

### 但更重要的判断是：**这个通病对你的主用途根本不适用**

"机房 IP 通病"只在**把代理当通用出口**（浏览网页、看视频、登网银）时才咬人。
而 Antigravity 走的是 Google 的 API 端点（`cloudcode-pa.googleapis.com`）——
**它不做验证码，只做地区检查。**

所以：

| 用途 | 会不会碰到这个通病 |
|---|---|
| 只给 Antigravity 供出口 | **不会**。API 端点只认地区，不认 IP 类型 |
| GitHub / Reddit / 查资料 | 基本不会（内容站，不卡 IP 类型） |
| Google 搜索 | 会（弹验证码，但可用） |
| 流媒体 / 网银 | **会，而且 GCP / OCI 都躲不掉** |

**真要躲只有一条路：住宅 IP 代理** —— 按 GB 计费（$3–15/GB）、稳定性差、来源鱼龙混杂。
为看个 Netflix 值得吗？不值得。

**正解是分流，不是换 IP：**

```yaml
rules:
  - GEOSITE,cn,DIRECT              # 国内站点直连（本来就不该走代理）
  - DOMAIN-SUFFIX,googleapis.com,AG-TUNNEL   # Antigravity —— 必须走
  - GEOSITE,google,AG-TUNNEL       # Google 系走代理，接受验证码
  - GEOSITE,category-bank,DIRECT   # 银行类直连 —— 别拿美国 IP 登
  - MATCH,DIRECT                   # 其余全直连，别没事找事
```

---

## 十三、Cloudflare Worker 出口被判中国，还有更好的解决办法吗？

> 2026-09-11

### 第一层：这个"出口判 CN"本身 —— **无解，可以停止投入了**

已经排除的路，不要回头：

| 试过的方向 | 结果 |
|---|---|
| 开 Smart Placement | ❌ 8 小时后出口段纹丝不动 |
| 换承载网络（WARP → SpeedCat） | ❌ 承载与出口是两回事（见 §上文"WARP 是承载不是出口"） |
| 换账号 / 换 workers.dev 子域 / 换自定义域 | ❌ 出口是**全局共享池**，与账号无关 |
| 付费计划（$5/mo） | ❌ 出口池相同 |

根因是 CF 官方博客自己写的：**"Anycast on ingress, unicast on egress"** ——
入站走 anycast 共享段（可控），出站走单独的 unicast 段（**全局池，用户不可控**）。
你拿不到"固定"的出口，也就无法把出口"修好"。

### 第二层：思路反转 —— 让判 CN 的那个出口，去干一件不在乎地区的事 ★

这是我认为**最有价值的解法**，也是之前一直没想到的角度：

> **GeoIP 只在"目标服务要检查"的时候才是问题。**

Cloudflare Worker 的出口判 CN —— 但 **GCP VM 不检查地区**。
所以，把判 CN 的那一跳，从"面对 Google"改成"面对 GCP VM"，问题当场消失。

```
                     ┌─ 入口层（CF）：IP 池巨大、封了自动换、国内可达性好
本机 → CF Worker ────┤
       【判 CN 出口】 └─ 出口层（GCP VM）：判 US、独享 IP
              ↓
         GCP VM 不管你是哪国 IP → 照收
              ↓
         GCP VM → Google（判 US ✅）
```

**改动极小**：Worker 代码**一行都不用动**。
现有代码是 `connect({ hostname: info.addr, port: info.port })`（无白名单），
mihomo 让它连 GCP VM 的 ss2022 端口就行 —— 用 mihomo 的 **代理链（`dialer-proxy`）** 表达：

```yaml
proxies:
  - name: ag-cf-entry            # 【沿用现有的】CF Worker 入口
    type: vless
    server: egress.example.com
    port: 443
    uuid: "41ed7fe3-8926-4376-95fa-f5a1c888315f"
    network: ws
    tls: true
    ws-opts:
      path: "/omrHG4N6pmPVXzpA"
      headers: { Host: egress.example.com }
    servername: egress.example.com

  - name: ag-gcp-us              # 【新增】真正的出口
    type: ss
    server: <GCP_VM_静态IP>
    port: 8388
    cipher: 2022-blake3-aes-256-gcm
    password: <你的密码>
    dialer-proxy: ag-cf-entry    # ★ 关键：连 GCP 的那一跳，先穿过 CF
```

数据流：`本机 →[VLESS/WS]→ CF Worker →[裸TCP]→ GCP VM →[ss2022 解密]→ Google`

> `dialer-proxy` 是 mihomo 的**通用字段**，值可以填代理节点或策略组的 `name`，
> 对所有出站类型都有效。它并非 CF 专用，任何"入口 + 出口"两跳组合都能这么拼。

**什么时候值得这么做**：国内直连 GCP VM 的 IP 不稳定 / 被 QoS / 被墙时。
**什么时候没必要**：直连 GCP VM 就通 —— 那就少一跳，别自找麻烦。

### 第三层：还有一个没验证过的实验（5 分钟，能一劳永逸地封口）

CF 的 `fetch()`（HTTP 出站）和 `connect()`（裸 TCP 出站）**是不是同一个出口池，没人验证过**。
我们一直测的都是 `connect()` 的出口（104.28.240.x）。

理论上两者可能不同 —— 因为 CF 的出站架构里，HTTP 路径和 socket 路径未必复用同一组 unicast 段。

**已写好探针**：`cf-egress-probe/`（同目录下的新文件夹）

```bash
cd cf-egress-probe
npx wrangler deploy
curl -s https://egress-probe.<你的子域>.workers.dev | jq
```

它会**在同一个请求里**分别用两条路径回显自己的出口 IP，并直接给出结论：

| 结果 | 含义 | 下一步 |
|---|---|---|
| 两者同 /16 | CF 侧彻底无解 | 走**第二层**方案，这条路封口 |
| 两者不同 | 值得深究 | 逐个 IP 送 ipinfo + ip-api 验归属 |

**但要提前说清楚**：即便 `fetch()` 出口真的判 US，**对你当前需求也仍然没用** ——
Antigravity 走的是 CONNECT + 端到端 TLS，`fetch()` 做不了透明转发。
这个实验的价值只在于"把问题关掉"，不在于"解决问题"。

### 优先级建议（从省事到麻烦）

| 顺序 | 做什么 | 成本 | 说明 |
|---|---|---|---|
| 1 | **mihomo 直连 GCP VM** | 0 | 通了就到此为止，别加戏 |
| 2 | 直连不稳 → 加 **CF 做入口层**（`dialer-proxy` 代理链） | 低 | 本文第二层方案 |
| 3 | 想彻底关掉 CF 出口这个问题 | 5 分钟 | 跑一次探针，留在结论里 |
| 4 | ~~修 CF 的出口~~ | — | **别做，无解** |

> **一句话**：CF 的出口修不好，但可以**换掉它的岗位** —— 让它从"出口"转岗当"入口"。
> 判 CN 的 IP 去连一台不查户口的机器，那个"CN"就再也无关紧要了。

---

## 十四、卡在 GCP 结算账号 / 绑卡失败怎么办

> 2026-09-11 · 实测大陆双币信用卡 + 借记卡全被拒

### 先定性：这不是你的卡的问题

GCP 绑卡失败是**系统性地区限制**，不是技术细节没调对。三条硬事实：

1. **GCP Cloud Billing 只认信用卡**（Visa / MasterCard / AmEx / Discover）——
   借记卡（debit）、预付卡（prepaid）一律不收。所以"双币**借记卡**"必然失败，无解。
2. **国内卡高频被风控拦截**，即使卡面有 Visa/MC 标志。据 Google Cloud 支持侧统计，
   新用户首次绑卡失败率约 **27%**，主因是**发卡行拦截境外小额预授权**。
3. **中国大陆不在 GCP 官方支持地区列表内** —— 意味着你是在"系统设计之外的边缘场景"里挣扎，
   成功率天生就低。

> **重要**：失败 3–5 次后 Google 会给账号打风控标记，**越试越死**。
> 停下来，别在同一账号上反复试。

### 路线一（推荐）：不在 GCP 上解决 —— 直接用支持支付宝的海外 VPS

> ✅ **2026-09-11 更新**：Mark 的 **OCI 账号已注册成功**（中国卡通过了 Oracle 验证）。
> 已经改用 OCI 作为主力出口，完整实操见同目录 **`OCI出口搭建指南-Antigravity.md`**。

**先想清楚一件事**：这套方案要的本质只是 **"一台判 US 的常驻 VM + 独享出口 IP"**。
GCP 免费层只是达成它的其中一种手段，**不是目的**。

换 VPS 之后，**服务端步骤（§3）一字不改**，只是把 IP 换掉：

| 服务商 | 付款方式 | 价格 | 备注 |
|---|---|---|---|
| **Vultr** | **支付宝** | $2.5–5/月 | 30+ 机房、**小时计费、随时换 IP** ← 最灵活 |
| **RackNerd** | 支付宝 / 微信 | **$11–12/年 ≈ ¥7/月** | 续费同价，洛杉矶节点 ← 最便宜 |
| 搬瓦工 BandwagonHost | 支付宝 | $49.99/年起 | 老牌，CN2 线路 |
| CloudCone / DMIT / HostDare | 支付宝 | $2–5/月 | 备选 |

**❌ 明确不支持支付宝的**：GCP · AWS · Azure · DigitalOcean（都要国际信用卡）。

**Vultr 支付宝充值唯一会卡的地方**（报错 `Please make sure you fill out all Address fields`）：
账单信息必须**五项全填**，且**全用拼音**：

```
姓名  Zhang San
地址  Chaoyang Qu          ← 只写到"区"，不要写"北京市朝阳区"
城市  Beijing
国家  China
邮编  100020               ← 必须 6 位数字
```
填完这五项再点 `Pay with Alipay` 就不会报错。新用户首次充值可能有 24 小时账户验证期。

**换成 VPS 后配置怎么改**：只改 mihomo 里节点的 `server`（§4 的 `ag-gcp-us` → 换成 VPS IP），
其余（sing-box 服务端脚本、分流规则、验证方法）全部照旧。

**这条路其实比 GCP 免费层更好**：流量大（1–2 TB/月 vs 1 GB）、IP 可随时更换、无 90 天额度倒计时、
无闲置回收。代价只有 ¥7/月起。

### 路线二：先花 10 分钟免费验证整条链路值不值得做

**Google Cloud Shell 不需要结算账号**即可使用，出口就是 Google 的美国 IP。

| 项 | 值 |
|---|---|
| 费用 | 免费（无按小时费用） |
| 额度 | **50 小时 / 周** |
| 闲置超时 | **40 分钟**（非交互会话） |
| 单次会话上限 | **12 小时**，到点自动终止 |
| 持久存储 | 5 GB `$HOME`（其余目录会话结束即丢） |
| 默认规格 | g1-small（0.5 vCPU / 1.7 GB），可开 Boost Mode 升到 1 vCPU / 3.75 GB |
| 年龄要求 | 需年满 18 |

**它不能当常驻出口**（12 小时必断、IP 每次会话会变），但**完全可以用来验证"这套链路到底行不行"**：

1. 打开 <https://console.cloud.google.com/> → 右上角打开 Cloud Shell
2. 照 §3 的脚本装 sing-box（`$HOME` 下的文件会持久保留，下次会话不用重装）
3. 本机 mihomo 加节点，连上去
4. **关键两步验证**：
   ```bash
   curl -x http://127.0.0.1:7897 https://ipinfo.io/json    # ① 出口必须判 US
   # ② 让 Antigravity 真调一次 —— 这才是唯一有效的验收
   ```
5. 结论出来后再决定：值 → 走路线一买 ¥7/月的 VPS；不值 → 整件事到此为止，省钱省时间

> **这个顺序的意义**：先用零成本把"方案对不对"验掉，再花钱买"能长期跑"。
> 反过来（先买机器再验证）容易白花钱。

### 路线三：硬啃 GCP 绑卡（如果你就想要免费的 Always Free）

成功率提升清单，按重要性排序：

| # | 要做的事 | 说明 |
|---|---|---|
| 1 | **必须换成信用卡** | 借记卡直接放弃，GCP 不收 |
| 2 | **打电话给银行开通"境外线上无卡支付"（CNP）** | ⚠️ **最高频的失败原因**。很多卡默认关闭。<br>只说"开通境外交易"可能只开线下刷卡，**必须明确说"境外线上无卡支付 / 网络支付"** |
| 3 | **账单地址全英文拼音**，与银行预留一致 | 不能写"上海市浦东新区"，写 `Chaoyang Qu, Beijing, 100020` |
| 4 | **持卡人姓名用拼音**，与卡面一致 | `ZHANG SAN`，且与 Google 账号注册名一致 |
| 5 | **卡内留 ≥ $5 可用额度** | Google 会做 $1–2 预授权验证（数日内释放） |
| 6 | **网络环境：先试国内直连** | 卡国 = IP 国，一致性更好；挂美国 VPN + 中国卡反而更可疑 |
| 7 | **失败后等 24 小时再试** | 连续失败触发风控，越试越死 |

**推荐的卡**：招商银行全币种国际信用卡（Visa Signature）、中国银行长城环球通、
工商银行 / 交通银行的**双币信用卡**（不是借记卡）。

> ### 🚫 三条别碰的红线
>
> | 做法 | 为什么不能碰 |
> |---|---|
> | **虚拟信用卡（VCC）** | Google **官方明确声明不支持预付卡和虚拟信用卡**。2026 年风控升级后，号商的卡头已被批量拉黑 → **账号可能被直接停用且不可申诉**。网上推 VCC 的内容多数是引流 |
> | **代付 / "五折代充"** | 常涉及被盗信用卡或非法资金池，一旦被追查，**实例立即被封、数据找不回** |
> | **在同一账号上反复试** | 失败几次后账号被打上风控标记，后续即使换好卡也会被拒 |

### 如果是学生：还有一条完全不需要信用卡的路

**Azure for Students** —— **无需信用卡**，邮箱验证即可：
- $100 额度 / 12 个月，在读期间可**每年续期**
- 含 25+ 项免费服务，其中 **B1s VM 前 12 个月免费**
- 需要 `.edu` / `.ac.uk`（或学信网在读证明）
- 出口是 Azure 美国段，与 GCP / CF 完全不重叠

→ 对"读大学 + 需要一个美国出口"这个组合，**这是唯一"零卡、零费用、能长期跑"的正规路径**。

### 决策表

| 你的优先级 | 走哪条 | 成本 | 耗时 |
|---|---|---|---|
| **先看清楚这事值不值得做** | **路线二**（Cloud Shell 验证） | ¥0 | 10 分钟 |
| **要能用、要稳定、不想折腾卡** | **路线一**（Vultr / RackNerd 支付宝） | ¥7–35/月 | 30 分钟 |
| **有 `.edu` 学生身份** | **Azure for Students** | ¥0（可续期） | 1–3 天审核 |
| **一定要免费的 GCP Always Free** | 路线三（先打电话开通 CNP，再试一次） | ¥0 | 不确定，可能失败 |

> **一句话**：GCP 只是"一台美国机器"，卡不通就不通，**方案本身没有任何损失**。
> 换台支付宝能买的机器，§3 之后的步骤一个字都不用改。
