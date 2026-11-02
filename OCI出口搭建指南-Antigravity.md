# Oracle Cloud (OCI) 搭建 Antigravity 出口 —— 完整指南

> 2026-09-11 · 适用前提：**OCI 账号已注册成功**（中国卡已通过 Oracle 验证）
>
> **首要目标：让 Google Antigravity 恢复可用。** 其他用途（2–3 人代理、跑服务）都是附带。
>
> 为什么转到 OCI：GCP 对中国卡是系统性拒绝（见 `GCP出口搭建指南.md` §14），
> 而 Oracle 接受了你的卡。OCI Always Free **永久免费**，且出站 **10 TB/月**
> —— 比 GCP 的 1 GB/月宽裕一万倍。

---

## 速查

| 你要做的事 | 看哪节 |
|---|---|
| 先花 5 分钟确认不被坑死 | **§0 三个前置确认** |
| 决定开什么机器（★ 别一上来就抢 ARM） | **§1 选实例类型** |
| 创建网络 + 实例 | §2 / §3 |
| **端口打不开？90% 的人都卡在这** | **§4 开放端口（两处）** |
| 装服务端 | §5 |
| 改客户端 | §6 |
| **怎么算真的成功了** | **§7 验证（三步）** |
| Antigravity 侧还要做什么 | §8 |
| 出问题了对照排查 | §9 坑清单 |
| 机器会被回收吗 | §10 |
| 被封了怎么办 | §11 抗封锁升级 |

---

## §0 三个前置确认（5 分钟，别跳过）

### 0.1 先看 Home Region 是哪个 ★ 最重要

**OCI 的 Home Region 在注册时确定，之后永久不可更改**，
而且 **Always Free 资源只能在家乡区创建**。

查看：控制台右上角 → 区域选择器，或者 `Administration → Tenancy Details`。

**判断标准**：

| 情况 | 结论 |
|---|---|
| 中国区（cn-beijing / cn-shanghai） | ⚠️ 普通国际注册拿不到中国区，基本不会遇到 |
| **美国区**（Ashburn / Phoenix / Chicago / San Jose） | ✅ 最稳 |
| **日韩新**（Tokyo / Osaka / Seoul / Singapore） | ✅ 完全可以，而且**从上海过去延迟更低** |
| 欧洲 / 加拿大 / 澳洲 | ✅ 可以 |
| 其他 | ✅ 只要不是中国，先按 §7 验证出口归属 |

> **本指南后文写"美国出口"只是为了好读 —— 实际要求是"非中国出口 + 在 Google 支持的地区"。**
> 这一步必须实测，不能假设。

> ✅ **已确认（2026-09-11）**：本账号 Home Region = **US East (Ashburn)**
> —— 美国区，最理想的情况，不会遇到地区问题。

### 0.2 确认账号可用

注册成功后你会同时拿到：
- **Always Free** 资源（永久，无到期日）
- **$300 试用额度**（**30 天**，与 GCP 的 90 天不同）

> ⚠️ **不要拿 $300 去开付费机型** —— 30 天一到额度清零，
> 你依赖的机器会直接停机。**全程只用 Always Free 资源**（控制台里带
> `Always Free-eligible` 标签的）。

### 0.3 确认升级 PAYG 的时机（建议：跑通之后再升）

升级到 **Pay As You Go** 有两个真实收益：

1. ✅ **豁免闲置回收** —— 官方明确：PAYG 账号的实例不会被判闲置回收
2. ✅ **更容易开出实例** —— 官方原话：升级后可访问"more types of Compute resources"，
   是 `Out of host capacity` 的官方解法之一

而且**升级不会让 Always Free 资源开始收费** —— 官方原文：
> "Oracle doesn't charge for Always Free resources after you upgrade,
> and will only charge you for resource usage above the Always Free limits."

**建议顺序是：先把实例跑通 → 确认全部在免费额度内 → 再升级 PAYG。**
理由：升级前账号是纯免费账户，**不可能产生任何费用**，可以放开手试错。

> ✅ **状态已更新（2026-09-12）：本账号已完成 PAYG 升级。**
>
> 这意味着**「不可能产生费用」这层保护已经消失了** —— 从升级那一刻起，
> 任何超出 Always Free 额度的用量都会真扣钱。所以下面这三件事**现在就该做**：
>
> 1. **立刻去 `Billing & Cost Management → Cost Analysis` 看当前花费**
>    —— 确认是 **0**。升级前如果误建过什么（第二台实例、备份策略、超出 200 GB 的块存储），
>    以前不会计费，现在会。
> 2. **确认升级真的生效**：`Billing & Cost Management → Subscriptions`
>    里 **Plan Type = Pay As You Go**（只提交申请不算，要看到这一行）。
> 3. **把预算告警建起来** —— 见 §10，这是现在唯一能第一时间知道出事的手段。
>
> ⚠️ 升级时 Oracle 会对卡做一笔**临时预授权冻结**（authorization，非实际扣款），
> 由银行在 3–5 天内自动解除。**它不会出现在 OCI 账单和预算里**，
> 别把银行短信当成超支。

---

## §1 选实例类型：★★ 别一上来就抢 ARM

这是整篇指南最重要的决策，能帮你省掉几小时。

### 两种 Always Free 机型

| | **VM.Standard.E2.1.Micro**（AMD） | **VM.Standard.A1.Flex**（ARM） |
|---|---|---|
| 数量 | **2 台** | 每月 1,500 OCPU 时 + 9,000 GB 时 |
| 规格 | **1/8 OCPU（可突发）+ 1 GB 内存** | 折算 **2 OCPU + 12 GB 内存** |
| 带宽 | 公网 **50 Mbps**（内网 480 Mbps） ⚠️ **未核实** | 随 OCPU 数缩放 |
| 开机难度 | **几乎随时可开** | ⚠️ 常报 `Out of host capacity` |
| 可用 AD | **只在一个可用域**（多 AD 区域） | 任意 AD（**韩国春川除外**） |
| 影响闲置判定 | CPU + 网络 | CPU + 网络 + **内存**（多一条） |

### 为什么代理应该选 E2.1.Micro

**1. 代理是 IO 密集型，不是 CPU / 内存密集型。**
sing-box 常驻内存 **< 50 MB**，转发时 CPU 占用接近 0。
1/8 OCPU + 1 GB 对"给 Antigravity 供出口"这件事是**巨大冗余**。

**2. A1 的最大拦路虎是容量，不是配置。**
`Out of host capacity for shape VM.Standard.A1.Flex` 是 OCI 免费层最著名的坑 ——
不是你不够格，是**免费 ARM 机器被抢光了**。抢它可能要试几天。

**3. 50 Mbps 够不够？**

> ⚠️ **「50 Mbps」没有官方出处**（2026-09-20 复核）：Oracle 官方 Always Free 页面
> 只写了 E2.1.Micro 的 AMD 处理器 / 最多 2 台 / 只能在一个 AD / 只能建在家乡区，
> **没写 OCPU 数、内存、带宽**。第三方文章有写 "0.48 Gbps"，口径不一致。
> **别拿 50 Mbps 当硬指标。**

Antigravity 是文本 API 流量，实测月均 1–3 GB。50 Mbps ≈ 6 MB/s，
够同时跑几十路对话。**只有当你打算拿它看 4K 视频时才不够。**

**4. A1 多一条闲置判定维度（内存 <20%），对纯代理更不利。**

### 结论

> **第一步：直接开 E2.1.Micro，把 Antigravity 跑通。**
> 想要 A1 的大配置（跑别的服务），之后再单独去抢，不影响 Antigravity 使用。

---

## §2 创建网络（VCN）—— 一次就好

### ⚠️ 先认准按钮：要用 **Start VCN Wizard**，不是 **Create VCN**

VCN 列表页上有**两个**按钮，长得像但不是一回事：

| 按钮 | 会做什么 | 用哪个 |
|---|---|---|
| **Start VCN Wizard** | 向导，**一次建好**：VCN + 公网/私网子网 + **Internet Gateway** + 路由表 + NAT 网关 + 服务网关 | ✅ **用这个** |
| Create VCN | 只建一个**空 VCN** —— 没有网关、没有子网、没有路由 | ❌ 别用 |

**用错按钮的后果**：实例建出来**上不了网**（拿到公网 IP 也连不通），
还得手工补 IGW + 路由表 + 子网 + 安全列表，麻烦十倍。

> 如果已经用普通表单建了一个空 VCN：**直接删掉重建**（还没放东西，删了不心疼）。

### 步骤

1. 控制台 → **Networking → Virtual Cloud Networks**
2. 点 **Start VCN Wizard**（**不是** Create VCN）
3. 选 **Create VCN with Internet Connectivity** → **Start VCN Wizard**
4. 填：

| 项 | 值 |
|---|---|
| VCN Name | `ag-vcn` |
| Compartment | `wujunjr (root)` |
| VCN CIDR Block | `10.0.0.0/16` |
| Public Subnet CIDR | `10.0.0.0/24` |
| Private Subnet CIDR | `10.0.1.0/24` |
| DNS Hostnames | ✅ 勾上 |
| IPv6 | 不勾 |

5. **Next** → 这一步会列出一张它准备创建的资源清单（VCN / 子网 ×2 / IGW / NAT / Service Gateway / 路由表 / 安全列表）
6. **Create** → 等约 1 分钟变成绿色 `Available`

### 怎么确认建对了

进 VCN 详情页，左侧 **Resources** 里应该能看到：

- **Subnets** → 有 `public subnet-ag-vcn` 和 `private subnet-ag-vcn` 两条
- **Internet Gateways** → 有 1 条（`igw-ag-vcn`）
- **Route Tables** → `Default Route Table for ag-vcn` 里有一条 `0.0.0.0/0 → igw-ag-vcn`

**少任何一项 = 建错了，删掉重来。**

---

## §3 创建实例 —— 逐屏对照（照着自己屏幕上的字段点）

控制台 → **Compute → Instances → Create instance**

表单一共 **4 步**（底部有进度：`1 Basic information → 2 Security → 3 Networking → 4 Storage → Review`）。

### 第 1 步：Basic information

| 屏幕上的字段 | 填什么 | 说明 |
|---|---|---|
| **Name** | `ag-egress`（或保持默认） | 名字随意，能认出来就行 |
| **Create in compartment** | `wujunjr (root)` 保持默认 | 你是根用户，不用改 |
| **Availability domain** | ⚠️ **看下面的警告文字，选它指定的那个** | **见下方红框说明** |
| **Capacity type** | 保持 **On-demand capacity** | 其余三种都别选（预占/专用主机/集群，会收费） |
| **Fault domain** | 保持默认 | 不用动 |
| **Image** | **Oracle Linux 9**（默认）或点 *Change image* 换 Ubuntu | 见下方说明 |
| **Shape** | **`VM.Standard.E2.1.Micro`** + 绿色 `Always Free-eligible` | ✅ **屏幕上显示这个就对了，别改** |

#### ⚠️ Availability domain：必须看那行警告文字

屏幕上的 Placement 区域会有一行提示，格式是：

> "You can create instances using the **VM.Standard.E2.1.Micro** shape in the
> **BYTI:US-ASHBURN-AD-1** availability domain."

**这句话就是告诉你：你选的这个机型只在 AD 1 可用。**
所以 **Availability domain 必须选 `AD 1`**，
选 AD 2 / AD 3 会报 "shape not available"。

> 这是 OCI 官方的设计：**E2.1.Micro 只在一个可用域提供**（官方文档原文：
> "Instances using the VM.Standard.E2.1.Micro shape can only be created in one
> availability domain."）。所以这行警告**不是错误，是导航**。

#### Image：在列表里选 **`Canonical Ubuntu 24.04`**（就这一行）

弹窗里的列表长这样（Publisher 全是 `Oracle`，Price 全是 `Free`）：

| 列表里的名字 | 选？ | 原因 |
|---|---|---|
| **`Canonical Ubuntu 24.04`** | ✅ **选这个** | LTS、资料最多、工具生态最全 |
| `Canonical Ubuntu 24.04 Minimal` | ❌ | **精简镜像砍掉了 man pages 和一批常用工具** —— 你要用 `man` 学命令，Minimal 上会找不到 |
| `Canonical Ubuntu 24.04 Minimal aarch64` | ❌ | **aarch64 = ARM 架构**，和你选的 `E2.1.Micro`（AMD/x86_64）不匹配 |
| `Canonical Ubuntu 26.04` / `26.04 Minimal` | ⚠️ 可但不建议 | 26.04 是最新 LTS，但**太新**，`sing-box` 这类第三方安装脚本可能还没适配 |
| `Canonical Ubuntu 22.04` | ⚠️ 可但偏旧 | 也是 LTS，能跑；但 24.04 学到的东西更不过时 |
| `Canonical Ubuntu 20.04` | ❌ | 太旧，快 EOL 了 |

**一句话**：**带 `Minimal` 的不要、带 `aarch64` 的不要、20.04 不要。在 22.04 / 24.04 之间选 24.04。**

##### 为什么不用最新的 26.04？——「n-1 LTS 原则」

先说清楚：**26.04 能用，这不是"它有 bug"。** 反对理由只有一条，但是分量很重：

> **新版本发布后，生态适配需要时间。而你今天要依赖生态。**

具体三层：

| 层 | 24.04（发布约 2 年） | 26.04（发布约 5 个月） |
|---|---|---|
| **第三方一键脚本** | 已充分适配 | ⚠️ **不确定** —— `sing-box` 的安装脚本要按系统版本号选包，新版本号可能还没进它的识别表 |
| **教程 / Stack Overflow / 博客** | 海量，且多数已更新到 24.04 | 绝大多数还停留在 22.04 / 24.04 → **你搜到的答案和你的系统对不上** |
| **你这次的目标** | 让 Antigravity 跑通 | ← 不是"评测最新系统" |

**最关键的是第二层**：你选 Ubuntu 的动机是**学 Linux**。
而学 Linux 的效率，很大程度取决于"遇到问题时能不能搜到对得上的答案"。
用 26.04 会在你想学习的时候，先花时间在"这个报错跟教程不一样"上。

> **这是一条通用原则**：**生产/长跑环境，选"上一个 LTS"（n-1）风险最低。**
> 最新版留给"不依赖任何第三方脚本、且愿意自己 debug"的场景。

##### 想要最新的怎么办？——**你有额度，可以两台都要**

OCI Always Free 给的是 **2 台 E2.1.Micro**（外加 A1 配额）。所以：

| 机器 | 用途 |
|---|---|
| 实例 1：**Ubuntu 24.04** | 干正事 —— 跑 Antigravity 出口 |
| 实例 2：**Ubuntu 26.04** | 当学习沙盒 —— 随便折腾，搞坏了删掉重开 |

**先跑通 24.04，等 Antigravity 稳了，再开第二台玩 26.04。** 这样两边都不耽误。

##### 如果你现在就想用 26.04

可以，**但把 §5 的兜底方案准备好**：`sing-box.app/install.sh` 那一步如果失败，
就用手动方式（§5 里注释掉的那几行 `curl ... tar.gz`）。功能完全一样，只是多两条命令。

> ⚠️ **实例创建后无法更换操作系统**。所以一旦选了 26.04 又想换回 24.04，
> 只能**删掉实例重建**（VCN 和 SSH 密钥可以复用，不损失什么）。

> 列表里那一列 **Security**（Shielded instance / Confidential computing）只是说明这些镜像
> **支持**哪些安全特性，**不影响你的选择**，也不用在这里配。

> ⚠️ **点 Change image 打开的是一个弹窗，选完必须点弹窗底部的
> 「Select image」按钮才会写回表单。** 漏了这一步，弹窗关了、表单上还写着
> Oracle Linux，看起来像"选择没生效"。**这是最容易卡住的地方。**
>
> 完整顺序：
> 1. 点 **Change image** 打开弹窗
> 2. 停在 **Oracle images** 标签页（Ubuntu 属于平台镜像，不在这里就切别的标签看看）
> 3. 在列表里找到 **`Canonical Ubuntu 24.04`**（位置靠下，需要滚动）
> 4. **点中它那一行的单选圆点** → 右侧/下方会列出具体版本号（如 `Canonical-Ubuntu-24.04-2026.xx.xx-0`），再选中那个
> 5. 如有服务条款勾选框，勾上
> 6. **点弹窗底部的 `Select image`** ← ★ 最容易漏
> 7. 弹窗关闭后，**表单上 "Image" 那行应该变成 `Canonical Ubuntu 24.04`**
>
> **还是不变？** 按 `Ctrl+Shift+R` 硬刷新控制台，或者干脆取消当前实例创建、
> 从 `Compute → Instances → Create instance` 重新开一张表单。
>
> ⚠️ **实例创建后无法更换操作系统**（要么删了重建）。所以这一步必须现在选对。

| | **Ubuntu 24.04 LTS**（推荐） | Oracle Linux 9（OCI 默认） |
|---|---|---|
| 默认登录用户 | `ubuntu` | `opc` |
| 包管理 | `apt` | `dnf` |
| 防火墙工具 | **iptables**（`/etc/iptables/rules.v4`） | **firewalld** |
| 开端口 | 4 条命令（含持久化） | 2 条命令 |
| 学 Linux 的价值 | ⭐⭐⭐⭐⭐ 教程/社区/文档量最大 | ⭐⭐ 偏企业红帽系 |

**为什么推荐 Ubuntu**（即使多两条命令）：
1. **生态最大** —— 遇到问题搜得到，回答多
2. **和你 Windows 上的 WSL2 是同一套命令** —— 云端练完能在本地复现
3. **技能可迁移** —— Docker 镜像、GitHub Actions、绝大多数云原生文档默认 Ubuntu
4. 想学 Linux 的话，`apt` / `systemd` / `nftables` 这套是现代运维的主流

> **代价只有一个**：防火墙要额外做一步"持久化"（见 §4.2）。不影响任何功能。

### 第 2 步：Security

**这一屏全部保持默认，直接点 Next。**

这里的 "Shielded instance / Confidential computing / BM Confidential computing"
是**实例硬件级安全特性**，跟我们要开的端口**毫无关系**。
（真正管端口的是后面 §4 的 Security List，在别的页面上。）

### 第 3 步：Networking（Required）★ 这一步最关键

| 字段 | 填什么 |
|---|---|
| **Primary VNIC** | 选 *Select existing virtual cloud network* |
| **Virtual cloud network** | 选 §2 建的 `ag-vcn` |
| **Subnet** | 选 `public subnet-ag-vcn`（**必须带 public**） |
| **Private IPv4 address** | 留空（自动分配） |
| **Public IPv4 address** | ✅ **必须勾 Assign a public IPv4 address** ← 不勾就没有公网 IP |
| **Add SSH keys** | 见下方 |

**SSH keys（三选一）**：
- ✅ **推荐**：*Paste public keys* —— 把你 Windows 上 `id_rsa.pub` / `id_ed25519.pub` 的内容整段贴进去
- *Upload public key files (.pub)* —— 选本地文件
- ⚠️ *Generate a key pair for me* —— **私钥只能下载一次**，页面会弹出下载；**没下载就再也拿不到**，只能重建实例

> 不知道自己有没有 SSH 公钥？PowerShell 里跑：
> ```powershell
> Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
> ```
> 输出那行（`ssh-ed25519 AAAA...`）就是要粘的内容。没有的话先跑 `ssh-keygen -t ed25519 -C "oci"`（中间问密码直接回车跳过）。

> ✅ **Mark 本机现状（已核实）**：Windows 上**已有可用密钥对**，不用重新生成。
> - 公钥文件：`C:\Users\<you>\.ssh\id_ed25519.pub`
> - 私钥文件：`C:\Users\<you>\.ssh\id_ed25519`（**不要外传、不要贴进任何网页**）
> - 公钥内容（直接整行复制，粘到 *Paste public keys* 框里）：
>   ```
>   ssh-ed25519 <YOUR_PUBLIC_KEY> wujunjr@hotmail.com
>   ```
> - 所以这一屏**选 *Paste public keys***，把上面那行贴进去即可。
>   **千万不要**选 *Generate a key pair for me*（会另生成一对，私钥只给一次，和你本机这份对不上）。

### 第 4 步：Storage（Required）

这一屏**只有一处需要判断，其余全部保持默认**。按屏幕上真实字段名对照：

| 屏幕上的选项 | 怎么处理 | 为什么 |
|---|---|---|
| **Specify a custom boot volume size and performance setting** | ❌ **不勾** | 勾了才需要填 size / 性能档；不勾即默认 **46.6 GB + Balanced** —— 正好是免费额度内、也是最小可用值 |
| **Use in-transit encryption** | ⚪ 可勾可不勾 | 免费，对代理无性能影响 |
| **Encrypt this volume with a key that you manage** | ❌ **不勾** | 勾了必须去选 **Vault + 密钥**，免费账号通常没配 Vault → **会卡在这一屏出不去**。默认 Oracle 托管密钥完全够用 |
| **Block volumes → Attach block volume** | ❌ **不点** | 底下显示 *No items to display* 是**正常状态**（还没挂任何块存储）。代理只需要启动盘 |
| `Backup policy` / `Enable backup policy`（若出现） | ❌ **不勾** | 免费额度外的收费项。部分控制台版本这一屏没有该项 |

#### ⚠️ 别被「46.6 GB」这个数字搞混

屏幕显示 **46.6 GB**，本文档多处写 **47 GB** —— **是同一件事，只是单位不同**：

> **50 GB（十进制） = 46.6 GiB（二进制）**
> OCI 的最小启动盘是 **50 GB**，控制台按 **GiB** 显示 → 显示成 46.6。

→ 所以**不要**因为"怎么不是 47"而去手动勾选自定义、填一个数字。**保持不勾，就是它。**

### Review 页验收清单 ★ 点 Create 之前的最后一道关

`Review` 页会把你填的四步全部折叠成摘要。**按下表逐行对一遍再点 Create**，
每一行都对上才说明前面四屏没填漏：

| Review 页分组 | 该看到什么 | 若不对说明什么 |
|---|---|---|
| **Basic information → Name** | `ag-egress` | — |
| **Availability domain** | **`AD-1`** | 选错 AD → 创建时才会报 shape 不可用 |
| **Capacity type** | `on-demand` | 动了 Capacity reservation |
| **Image → Operating system** | **`Canonical Ubuntu 24.04`** ← ★ | 还是 Oracle Linux → **弹窗没点 `Select image`，回去重选** |
| **Image → Image build** | 形如 `2026.08.25-0`（近一两个月） | 太旧说明选到老版本条目 |
| **Shape** | `VM.Standard.E2.1.Micro` + "1 core OCPU, 1 GB memory" | 选成 A1.Flex（ARM）了 |
| **Networking → Virtual cloud network** | `ag-vcn` | 选错 VCN |
| **Networking → Subnet** | **`public subnet-ag-vcn`**（必须带 public） | 选成 private → 没有公网出口 |
| **Networking → Public IPv4 address** | **`Yes`** | `No` → 没有公网 IP，**无法从本机 SSH** |
| **Networking → Use network security groups** | `No` | `Yes` 会让访问由 NSG 控制 → §4.1 的 Security List 改法就不适用了 |
| **Networking → SSH keys** | 你的公钥，形如 `ssh-ed25519 AAAA...`（见下方陷阱） | 见下方 |
| **Storage → Specify a custom boot volume size** | **`-`**（空） | 出现数字 → 被勾了自定义，回头取消 |
| **Storage → Master encryption key** | **`-`**（空） | 有值 → 勾了 Vault 自管密钥那项 |
| **Storage → Block volume** | **`No items to display`** | 有内容 → 误挂了块存储 |

> **不用管的项**（全是默认值，与本任务无关）：
> `Fault domain`、`Live migration`、`Restart after infrastructure maintenance: Enabled`、
> `Authorization header: Enabled`、`DNS record: Yes`、
> 各项 Oracle Cloud Agent 插件（`Compute Instance Monitoring: Enabled` 等）、
> `Secure Boot / Measured Boot / TPM: Disabled`、`Cloud Guard Workload Protection`。
> **尤其别去手动开 Secure Boot** —— OCI 的 E2.1.Micro（上一代 AMD 机型）本来就不支持它。

> ⚠️ **SSH keys 那一行有个坑：容易被粘两遍。**
> Review 页是**截断显示**，形如
> `ssh-ed25519 AAAA...wujunjr@hotmail.com` + 紧接着又出现 `ssh-ed25519 ...`
> → 说明**框里可能有两份密钥粘在一起**。
> **判断方法**：点 `Networking` 右边的 **Edit** 回到那一屏，直接看输入框：
> - 只有**一行**（或两行各是一个完整公钥）→ ✅ 正常，回 Review 点 Create
> - 两段**首尾相接没有换行** → 会拼成一条无效行，**SSH 登不进去**。全选删掉、
>   重新粘**一次**即可（此时还没创建，改完不用重建）
>
> 这一栏的其它情形：多一个**重复但分行**的公钥是**无害**的（`authorized_keys`
> 允许重复行）。真正的风险只有"粘成一行"。

### 最后：Create

Review 页对齐之后，**直接点页面底部的 `Create`**。
（部分控制台版本底部有个 `Review` 折叠区，展开扫一眼确认三项即可：
Image = Canonical Ubuntu 24.04、Shape = VM.Standard.E2.1.Micro、Availability domain = AD-1。）

点 **Create**，等 1–2 分钟，状态变绿 **Running** 即成功。
在实例详情页记下 **Public IP address**。

### SSH 登录

**Windows PowerShell 里直接跑**（Ubuntu 用 `ubuntu`，Oracle Linux 用 `opc`）：

```powershell
ssh -i "$env:USERPROFILE\.ssh\id_ed25519" ubuntu@<公网IP>
```

首次连接会问 `Are you sure you want to continue connecting?` → 输 `yes` 回车。
看到 `ubuntu@ag-egress:~$` 就是进来了。

> 报 `permissions too open` / `UNPROTECTED PRIVATE KEY FILE`：私钥文件权限太松。
> PowerShell 里：
> ```powershell
> icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$($env:USERNAME):R"
> ```
> 更省事的办法：把私钥复制到 WSL 里用（`~/.ssh/id_ed25519` + `chmod 600`），Linux 侧不会报这个。

> 没有本地 SSH 环境？OCI 控制台顶部有 **Developer Tools → Cloud Shell**
> （浏览器内终端，可上传私钥文件）。够用。

> **容量报错怎么办**（`Out of host capacity`）：
> ① 换可用域 → ② 等几小时 → ③ 升级 PAYG 后再试。
> E2.1.Micro 极少遇到；如果它也报，基本是该 AD 真的满了。

---

## §4 开放端口 —— 两处缺一不可 ★★ 90% 的人卡在这一步

**记住这句话**：OCI 要开一个端口，需要**同时**打通两层防火墙。
只改控制台是**一定不通**的。

```
外部客户端 →【① 云端 Security List（控制台里改）】→ 公网 IP
          →【② 实例内防火墙（SSH 里改）】→ 你的服务 ← ★ 这层最容易被忘
```

### 4.1 第一层：Security List（控制台）

1. **Compute → Instances** → 点 `ag-egress`
2. 在 **Instance Information** 里找到 **Subnet** 链接 → 点进去
3. 下方 **Security Lists** → 点默认的那条（通常叫 `Default Security List for <你的VCN名>`）
4. **Add Ingress Rules**，填：

| 字段 | 值 |
|---|---|
| Stateless | ❌ **不要勾**（保持有状态） |
| Source Type | CIDR |
| Source CIDR | `0.0.0.0/0` |
| IP Protocol | **TCP** |
| Source Port Range | 留空 |
| Destination Port Range | **`443`** |
| Description | `antigravity egress` |

5. **再点一次 `Add Ingress Rules` 保存** ← ★ 表单底部那个按钮才是提交

#### 找不到 Subnet 链接时的备用路径

`Networking → Virtual Cloud Networks → ag-vcn → Subnets → public subnet-ag-vcn`

#### ★ 两个必须复核的点

**① 填完必须点提交按钮。** 和 §3「Change image」弹窗一样的坑 —— **填完不点提交就离开页面，规则不会保存**。
> **判据**：保存后你应该能在 **Ingress Rules 列表里看到这一行**。**看到才算成功。**

**② 确认规则真的进了列表**，核对三格：
`Source = 0.0.0.0/0` / `IP Protocol = TCP`（**不是 All**）/ `Destination Port Range = 443`。

> ⚠️ **`IP Protocol` 留成 `All` 也能通，但没有必要** —— 只放行 TCP 443 更干净。
>
> ⚠️ **VCN Wizard 建的 VCN 只有一条默认 Security List**，不会选错。如果你看到多条，
> 说明之前手工建过空 VCN；用 `Default Security List for ag-vcn` 这条（名字里带你的 VCN 名）。
>
> **加完立即生效**，不需要重启实例、也没有"应用"步骤。

### 4.2 第二层：实例内的防火墙 —— 按你选的系统走 ★ 这才是真正的坑

#### 为什么必须改

OCI 官方镜像预置了**本机防火墙规则**，默认**只放行 SSH(22)，其余全部拒绝**。
后果：即使你在控制台把端口开好了，**连接仍然被本机防火墙拒掉**。
**这是 OCI 独有的行为，AWS / GCP 的 Ubuntu 镜像都没有这个。**

#### 情况 A：Ubuntu（本指南默认）—— 你先看现状，再放行

**第 ① 步：先看一眼现在有什么规则**（顺便学了 `iptables -L`）

```bash
sudo iptables -L INPUT -n --line-numbers
```

你会看到**类似下面这样**（这是 2026-09-11 在 Ashburn 区 Ubuntu 24.04 实例上的实测原文）：

```
Chain INPUT (policy ACCEPT)
num  target     prot opt source               destination
1    ACCEPT     0    --  0.0.0.0/0            0.0.0.0/0            state RELATED,ESTABLISHED
2    ACCEPT     1    --  0.0.0.0/0            0.0.0.0/0
3    ACCEPT     0    --  0.0.0.0/0            0.0.0.0/0
4    ACCEPT     6    --  0.0.0.0/0            0.0.0.0/0            state NEW tcp dpt:22
5    REJECT     0    --  0.0.0.0/0            0.0.0.0/0            reject-with icmp-host-prohibited
                                                                    ↑ 这一条 = 其余全拒
```

> **`prot` 列为什么是数字而不是 `tcp` / `icmp`？**
> 因为 `-n` 参数让输出**全部数字化**（不反查名字）。对照：
> **`0` = all（所有协议）、`1` = icmp、`6` = tcp、`17` = udp**。
> 所以第 4 行的 `6 ... state NEW tcp dpt:22` 就是"**只放行 SSH**"。
> 看到 `0` 别以为是"端口 0"—— 那是协议编号。

这五条是 OCI 官方镜像的**安全基线**：已建立连接放行 → ICMP 放行 → 回环放行 → **只放行 SSH** → 其余全拒。
**你要做的就是在第 5 条之前插一条放行 443 的规则。**

**第 ② 步：把 443 插到第 1 位**（保证排在 REJECT 之前）

```bash
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
```

> `-I` 是 **insert（插到指定位置）**，`-A` 是 **append（加到末尾）**。
> 这里**必须用 `-I ... 1`** —— 用 `-A` 会加到 REJECT **后面**，永远不生效。
> 这是 iptables「**规则按顺序匹配、命中即停**」的直接后果，也是理解 iptables 的第一个关键点。

**第 ③ 步：复核**

```bash
sudo iptables -L INPUT -n --line-numbers | head -n 8
# 确认 443 那行在 REJECT 之上（编号更小）
```

**第 ④ 步：持久化**（★ 不做这步，重启后规则全丢）

> ✅ **OCI 的 Ubuntu 镜像已预装 `iptables-persistent` 并设为开机自启**（2026-09-11 实测：
> `systemctl is-enabled netfilter-persistent` → **`enabled`**）。
> **所以下面的 `apt-get install` 通常可以跳过**，直接 `netfilter-persistent save` 即可。
> 先跑 `systemctl is-enabled netfilter-persistent` 确认一下，返回 `enabled` 就直接 save。

```bash
# 先确认持久化机制在不在（enabled 就跳过下面的 apt install）
systemctl is-enabled netfilter-persistent

# 装持久化工具（仅在上一条不是 enabled 时才需要）
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent

# 保存当前规则到 /etc/iptables/rules.v4
sudo netfilter-persistent save

# 确认开机自启
sudo systemctl is-enabled netfilter-persistent

# 复核文件里真的有 443（返回 ≥1 即为成功）
sudo grep -c 443 /etc/iptables/rules.v4
```

**如果第 ④ 步装包出问题**，用这个兜底（效果一样）：

```bash
sudo mkdir -p /etc/iptables
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
sudo systemctl enable netfilter-persistent
sudo grep 443 /etc/iptables/rules.v4
```

> **为什么是 `sudo sh -c 'iptables-save > ...'` 而不是 `sudo iptables-save > ...`？**
> 因为 `>` 重定向是**由当前 shell 执行的**，权限来自你（普通用户），
> 所以会报 "Permission denied"。用 `sh -c '...'` 把整条命令（含重定向）交给 root 的 shell 执行才行。
> **这是 Linux 里最容易踩的一个权限认知坑**，跟 §5 里为什么用 `tee` 是同一个道理。

#### 情况 B：Oracle Linux 9（OCI 默认镜像）

Oracle Linux 用 `firewalld`，两条命令：

```bash
sudo firewall-cmd --zone=public --permanent --add-port=443/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports          # 应看到 443/tcp
```

`--permanent` 表示写入永久配置（否则重启失效），`--reload` 让配置生效。

#### 保险做法（不确定自己选了什么系统时）

两条都跑一遍，**互不冲突、无副作用**：

```bash
# firewalld 路径（没有 firewalld 会报 command not found，无害）
sudo firewall-cmd --zone=public --permanent --add-port=443/tcp && sudo firewall-cmd --reload

# iptables 路径
sudo iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
```

### 4.3 本机侧预检：一条命令分辨三层状态 ★ 最实用的诊断工具

**关键认知：包被哪一层拦下，客户端看到的现象是不同的。** 所以一次连接测试
就能反推"防火墙改到哪一步了"，不用反复回去翻控制台。

| 本机测试结果 | 说明卡在哪一层 | 该怎么办 |
|---|---|---|
| **TIMEOUT**（无任何响应，等到超时） | **① 云端 Security List** —— OCI fabric 在**静默丢包**，包根本没到实例 | §4.1 没生效（漏加规则 / 加到别的 Security List / 加错 VCN） |
| **`no route to host`**（Host is unreachable） | **② 实例内 iptables** —— 包的 REJECT 回了 ICMP host-prohibited | §4.2 没生效（用了 `-A` 加到 REJECT 之后 / 插错位置） |
| **`Connection refused`** | ✅ **两层都通了** —— 只是 443 上还没有服务在监听 | **这是服务端起来之前的正确状态**，可以进 §5 |
| **连上并返回数据** | ✅✅ 服务已就绪 | 进 §7 验证 |

**原理**：`REJECT --reject-with icmp-host-prohibited` 会回一个 ICMP 差错包，
Windows/Linux 客户端把它翻译成 **`no route to host`**；
而被云端 ACL 静默 DROP 时**什么都不会回**，只能等到超时。
**这两个现象长得完全不像，但含义天差地别 —— 前者是配置问题，后者常被误判成"网络故障"。**

#### 怎么测（Windows 上）

```powershell
# 简单版：能看到 TCP 测试结果，但不区分超时与拒绝
Test-NetConnection <OCI公网IP> -Port 443

# 精确版：能区分 TIMEOUT / no route to host / refused 三种状态
$c=New-Object System.Net.Sockets.TcpClient
$sw=[System.Diagnostics.Stopwatch]::StartNew()
try { $r=$c.BeginConnect('<OCI公网IP>',443,$null,$null)
  if($r.AsyncWaitHandle.WaitOne(6000)){ $c.EndConnect($r); "OK $($sw.ElapsedMilliseconds) ms" }
  else { "TIMEOUT → 云端 Security List 没放行" } }
catch { $e=$_.Exception; if($e.InnerException){$e=$e.InnerException}
  "$($e.GetType().Name): $($e.Message)" }
finally { $c.Close() }
```

> **先测基线再改防火墙**，价值很大：改动前测一次、每改一层再测一次，
> 就能看见状态从 `TIMEOUT` → `no route to host` → `Connection refused` 逐步推进。
> 一次改完再测，出问题就分不清是哪一层。
>
> **建议加一个对照组**：同时测 `1.1.1.1:443` 或 `223.5.5.5:443`。
> 它们能连上，才说明"超时是 OCI 侧造成的"，而不是本机出网有问题。

#### 实测记录（2026-09-11，美国 Ashburn 区 E2.1.Micro）

| 时点 | 结果 | 解读 |
|---|---|---|
| 改防火墙**之前** | `AG OCI 实例 TIMEOUT (无响应)` | 云端 Security List 默认不放行 443 |
| 对照组 `1.1.1.1:443` | `CONNECT OK 156 ms` | 本机出网 443 正常 → 排除本地因素 |
| 对照组 `223.5.5.5:443` | `CONNECT OK 10 ms` | 同上 |
| **只改完实例内 iptables**、控制台还没改 | **仍然是 `TIMEOUT`** | ★ 见下方"外层屏蔽内层" |
| 两层都改完（**WARP 开着**） | **仍然 8/8 `TIMEOUT`** | ★ 见 §6「Cloudflare WARP 会吃掉这条链路」 |
| **断开 WARP** | ✅ **`Connection refused`** | **两层全通、服务未起 —— 目标状态达成** |
| 外部 6 国节点测 `:443` | 5 国 `Connection refused` | 反证服务端侧完全就绪 |

> **两个结论叠在一起才是完整的判据**：
> ① **外部多国节点返回 `Connection refused`** → 证明服务端（Security List + iptables）真的生效了；
> ② **本机断开 WARP 后返回 `Connection refused`** → 证明本机到该 IP 的路径也通了。
> 只做其中一项，都可能被"看起来一样"的 `TIMEOUT` 骗过去。

#### ★ 为什么"内层改对了也看不见效果"—— 必须是外层先通

**两层是上下游关系：云端 Security List 在实例之前。** 外层没放行时，
包**根本到不了实例**，实例内那条 `ACCEPT 443` 规则**永远没机会被匹配**。

```
客户端 →【① 云端 Security List】-✗ 在这里被丢掉
                              ↓（包到不了下面，② 改得再对也没用）
         【② 实例内 iptables】
```

**这解释了一个非常容易让人怀疑自己的现象**：
在服务器上把 iptables 改对了、复核也对、持久化也成功了，**从外面测还是不通** ——
于是开始怀疑是不是 iptables 写错了、是不是要重启、是不是机器坏了。

> **判据**：现象仍然是 **`TIMEOUT`** → 问题在**① 云端**，别再去动 iptables（它已经对了）。
> 只有现象变成 **`no route to host`** 才说明 ① 通了、该看 ②；
> 变成 **`Connection refused`** 才说明**两层都通**。
>
> **所以一定要先测基线、每改一层测一次。** 一次把两层都改完再测，
> 虽然也能通，但少了一次"确认哪层真的生效"的机会 —— 而这次机会在出问题时能省下大量排查时间。

---

## §5 服务端：装 sing-box（SSH 登录后整段粘贴）

> 登录：Oracle Linux 用 `ssh -i <私钥> opc@<公网IP>`；Ubuntu 用 `ubuntu@`。
> 下面所有命令都**不用 sudo su**，直接带 `sudo` 跑。

```bash
# 1) 安装 sing-box
curl -fsSL https://sing-box.app/install.sh | sudo sh
# 若这一步失败（Oracle Linux 偶发），用下面的手动方式：
#   sudo dnf install -y curl tar
#   curl -fsSL -o /tmp/sing-box.tar.gz \
#     https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz
#   tar -xzf /tmp/sing-box.tar.gz -C /tmp && sudo install -m755 /tmp/sing-box-*/sing-box /usr/local/bin/sing-box

# 验证装上了
sing-box version

# 2) 生成密钥 —— ★ 把输出抄下来，客户端要用
#    ★ 用 sing-box 自带的生成器，而不要用 openssl rand：
#      2022-blake3-aes-256-gcm 要求密钥【恰好 32 字节】的 base64（44 字符带 = 结尾），
#      sing-box 的生成器保证格式对，openssl 也能出但容易和别的长度搞混。
KEY=$(sudo sing-box generate rand --base64 32)
echo "===================="
echo "YOUR_KEY=$KEY"
echo "===================="

# 顺便生成一个 UUID（当前 ss2022 配置用不到，但升级 Reality/VLESS 时要用，先存着）
sudo sing-box generate uuid

# 3) 写配置（监听 443）
sudo mkdir -p /etc/sing-box
sudo tee /etc/sing-box/config.json > /dev/null <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": 443,
      "method": "2022-blake3-aes-256-gcm",
      "password": "$KEY"
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF

# 4) 启动 + 开机自启
sudo systemctl enable --now sing-box
sudo systemctl status sing-box --no-pager

# 5) 确认真的在监听
sudo ss -lntp | grep 443
```

**三个成功标志**：
- `systemctl status` 显示 `active (running)`
- `ss -lntp` 能看到 `*:443`
- 你自己机器上 `curl -v http://<IP>:443/` 从超时变成 `Connection refused`

> **为什么用 443**：① 在运营商/中间设备看来像**正常 HTTPS**，干扰最少；
> ② 两层防火墙本来就按 443 开好了，不用再改。
>
> **如果哪天 443 被针对性封了**：我们已确认这是**端口级封锁**（同 IP 的 22 通、443 不通），
> 所以解法是**换监听端口**（改 `listen_port` + Security List + iptables 三处），
> 而不是继续折腾防火墙。另见 §11 抗封锁升级。

> **为什么选 ss2022 而不是 VLESS+Reality**：
> 配置只要几行、不需要证书和域名、mihomo 原生支持，**先把链路跑通是第一优先级**。
> 抗封锁升级见 §11。

---

## §6 客户端：改 mihomo 配置

编辑 `mihomo\config-proxy.yaml`，做**三处**改动。
（Mark 的配置已于 2026-09-11 直接改好，仓库里那份就是成品，可作参考。）

### ① 在 `proxies:` 下新增节点

```yaml
  - name: "ag-oci"
    type: ss
    server: 123.45.67.89            # ← 换成你的 OCI 公网 IP（直接写 IP，不要域名）
    port: 443
    cipher: 2022-blake3-aes-256-gcm
    password: "§5 里抄下来的 KEY"
    udp: false
```

> ✅ **直接写 IP 而不是域名**：绕开 DNS 污染这一整类问题。
> ss2022 会把目标域名交给服务端解析，所以 mihomo 本地不需要为节点做任何域名解析。

### ② `AG-TUNNEL` 只放【确认可用】的节点 —— 别急着上 fallback

```yaml
proxy-groups:
  - name: "AG-TUNNEL"
    type: select
    proxies:
      - "ag-oci"                # ← 只放这一个
  - name: "DIRECT-OUT"
    type: select
    proxies:
      - "DIRECT"
```

> **为什么先不用 `fallback` 挂 `ag-cf-us` 兜底**：`ag-cf-us` 的出口**已被判 CN、本来就是坏的**。
> 把它放进 fallback 不会带来冗余，只会造成「**以为有备份、其实没有**」的错觉，
> 而且出问题时会自动切到一个同样不通的节点，把排查思路带偏。
>
> **正确做法**：**fallback 里每一个成员都必须是已验证可用的**。
> 等有了第二个能用的出口（比如再开一台 OCI、或买个便宜 VPS）再改成：
> ```yaml
>   - name: "AG-TUNNEL"
>     type: fallback
>     proxies: ["ag-oci", "<第二个可用节点>"]
>     url: "https://www.gstatic.com/generate_204"
>     interval: 300
>     lazy: false
> ```
> 这就是 GCP 指南 §11 说的「**别只有一个出口**」—— 但前提是冗余的那个真的能用。

### ③ ★ DNS 要改（因为 WARP 关了）

**这是 WARP 关闭后必须连带处理的一件事**，否则会被 DNS 污染咬到。

| | 旧架构（CF Worker） | 新架构（OCI ss2022） |
|---|---|---|
| 节点地址 | `egress.example.com` —— **域名** | `203.0.113.10` —— **IP** |
| 因此 mihomo | **必须本地解析载体域名**，被 223.5.5.5 污染成 Facebook 段 → 成环/400 | **不需要解析任何域名** |
| 境外域名谁解析 | 本地 mihomo 解析后再连 | **ss2022 把域名透传给 OCI 服务器**，由美国节点解析 |
| 本地 DNS 的用途 | **关键路径** | **只用于国内直连域名** → 国内 DNS 更准更快 |

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: normal
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
```

> **关键认知**：**tunnel 类出站（ss / vless / trojan）会把域名原样交给服务端解析。**
> 所以本机 DNS **不参与隧道内的解析** —— 旧版「必须靠 WARP 提供干净 DNS」的原因
> 是**载体域名要本地解析**，换成 IP 节点后这个约束自然消失。
>
> ⚠️ **兜底方案**：若将来发现境外域名仍被本地解析（症状：Antigravity 报 400 或连不上），
> 再给 mihomo 挂 DoH 并让它走隧道，或改用 `fake-ip`。

### ④ 重启 mihomo

双击 `stop-ag-proxy.bat` → 再双击 `start-ag-proxy.bat`。

> ⚠️ **WARP 必须关闭（或用 Split Tunnel 排除 OCI 的 IP）** ——
> 见下方「★ Cloudflare WARP 会吃掉这条链路」。**这一条做错，§6 之后怎么配都不会通。**

#### ★ Cloudflare WARP 会吃掉这条链路（2026-09-11 实测）

如果本机装了 **Cloudflare WARP**，它会**把所有境外流量吃进隧道** ——
连 `socket.connect()` 这种原始 socket 也一样。表现是：**到 OCI 实例的 443 完全不通**。

**实测 A/B 对照**：

| 目标 | WARP 开 | WARP 关 |
|---|---|---|
| `OCI_IP:443` | ❌ **8/8 TIMEOUT** | ✅ **`Connection refused`**（两层全通） |
| `OCI_IP:22` | OK（源 IP `172.16.0.2` = WARP 网卡） | OK **206 ms**（源 IP `192.168.1.4` = 物理网卡） |

**判据**：断开 WARP 后延迟反而更好（**206ms vs 450ms**）——
因为直连少了一跳。**这一层现在完全是多余的。**

> **为什么 WARP 是多余的**：WARP 原本的职责是"承载 mihomo 到 CF Worker 的流量"。
> 现在出口换成了 OCI VM，**CF Worker 那条路已废弃，所以 WARP 这一层不需要了**。
>
> **注意不是"WARP 封了 443"**：WARP 开着时 GitHub / 1.1.1.1 / 另一台 Oracle 的 443
> **都是通的**，只有这台 OCI 的 443 不通 —— 是"**WARP 的出口到这台 IP 的 443
> 这条特定路径**"不通。不管成因，结论一致：这条链路别让 WARP 碰。

**两种处理方式**：

| 做法 | 说明 |
|---|---|
| ✅ **直接关掉 WARP**（推荐） | 点托盘图标 → Disconnect。**少了整整一层，延迟还更低** |
| 需要 WARP 做别的事 → 加排除 | WARP 设置 → Advanced → **Split Tunnels** → **Exclude** 里加上 OCI 的公网 IP（如 `203.0.113.10`） |

**怎么判断自己的流量有没有被隧道接管**：看连接用的本地源 IP：

```python
import socket
s = socket.socket(); s.settimeout(8); s.connect(('<OCI_IP>', 22))
print('源IP =', s.getsockname()[0])   # 192.168.x.x = 直连；172.16.0.2 = WARP 隧道
s.close()
```

> 2026-09-11 实测：**WARP 的驱动会锁住出站路由** ——
> 试图把 socket 绑定到物理网卡地址强制绕过 WARP，会被系统拒绝：
> `WSAEACCES (10013) 以一种访问权限不允许的方式做了一个访问套接字的尝试`。
> **所以只能真的断开 WARP（或用 Split Tunnel），无法在应用层绕过。**

---

## §7 验证 —— 三步，一步都不能省

### 第 1 步：链路通了吗

```bash
curl -x http://127.0.0.1:7897 -o /dev/null -w "%{http_code}\n" \
  https://cloudcode-pa.googleapis.com/
```
期望 **401**。

> ⚠️ **401 只说明"连得上"，不等于"地区放行"。** 详见第 3 步。

### 第 2 步：出口归属对不对 ★

```bash
curl -x http://127.0.0.1:7897 https://ipinfo.io/json
```

**要求**：`country` **不是 `CN`**，并且地区在 Google 支持范围内。

**双库交叉验证**（别只信一个库）：
```bash
# 拿到 IP 后
curl -s "https://ipinfo.io/<出口IP>/json"
curl -s "http://ip-api.com/json/<出口IP>?fields=country,city,isp,org,as"
```

> 两库都判非中国 → 基本可以放心。
> 若一个判 CN、一个不判 → 以**更严格**的那个为准（Google 用的是类似的商业库）。

### 第 3 步：Antigravity 真调一次 ★★★ 唯一有效的验收

> ✅ **2026-09-11 21:11 已完成：Antigravity 正常工作。整条方案至此闭环。**

打开 Antigravity，**随便发起一次对话**（Gemini 3.8 Flash 之类）。

| 结果 | 含义 |
|---|---|
| 正常出结果 | ✅ **成功，到此结束** |
| `User location is not supported` | ❌ 出口仍被判中国 / 不在支持地区 → 回第 2 步查归属 |
| 401 / 认证错误 | 链路通但 token 有问题，重登 Antigravity |
| 超时 / 连接失败 | 链路没通 → 回 §4 查端口 |

> **为什么必须真调**：无 token 的请求一律 401，**地区检查只在带 token 的请求上发生**。
> 所有 curl 测试都只能排除故障，**只有 Antigravity 自己跑通才算数。**

### ★ 2026-09-11 实测结果（本方案跑通的完整证据链）

| 检查 | 实测值 |
|---|---|
| `VPS:443` 从本机 | CONNECT OK **197 ms**（3/3） |
| 走 mihomo 隧道 → `ipinfo.io/json` | `203.0.113.10` / **Ashburn, Virginia / `US`** / AS31898 Oracle |
| 直连（对照） | `198.51.100.20` / Shanghai / **`CN`** |
| Cloud Code 端点（走隧道，无 token） | **HTTP 401**（只证明链路通） |
| `gstatic.com/generate_204` | HTTP 204，0.84 s |
| **★ Antigravity 带凭据真实调用** | ✅ **21:11 正常工作 —— 唯一真判据通过** |
| 21:11 同一时刻复测链路 | 出口仍 `203.0.113.10` / `US`；`generate_204` **204 / 0.66 s** |

→ **核心判据达成**：出口从"CF Worker 共享池（判 CN）"变成"OCI 独享 IP（判 US）"，
且 **Google 侧带凭据调用正常** —— 整条链路（DLL → mihomo → ss2022 → OCI → Google）闭环。

**日常使用的三条纪律**：
1. **先起代理，再启 Antigravity** —— DLL 在进程启动时加载，顺序反了不生效；
2. **Cloudflare WARP 保持关闭** —— 开着会吃掉"到该 IP:443"这条链路；
3. **Antigravity 升级后完全重启** —— 升级会清空 `resources\bin`，`start-ag-proxy.bat` 会自动补 DLL。

→ **核心判据达成**：出口从"CF Worker 共享池（判 CN）"变成"OCI 独享 IP（判 US）"。

### ⚠️ 自检脚本输出的正确读法

`start-ag-proxy.bat` 会调 `ag-proxy-check.ps1`，输出分为 `[A]`–`[F]` 六段。**别只看最后的 `RESULT=PASS`**：

| 段 | 含义 |
|---|---|
| `[A]` WARP 状态 | ★ **要求 `Disconnected`**（旧脚本查的是 Windows 服务 `CloudflareWARP`，那个服务在 WARP 断开时**照样是 Running** → 会误报成 "running (good)"，已改为查 `warp-cli status`） |
| `[B]` mihomo 端口 | `listening` |
| `[C]` DLL hook | `deployed` |
| `[D]` Cloud Code | **`401` 只代表链路通，不是地区放行** |
| **`[E]` 隧道出口归属** | ★★ **这才是真正有意义的前置判据** —— 必须 `country` ≠ `CN` |
| `[F]` 直连出口 | 对照组，应显示你本地的国内 IP |

**旧版本脚本里有两个会误导人的 bug**（均已修）：
1. `if ($trace -match 'ip=...') { $Matches[1] }` 报 `无法对 Null 数组进行索引` ——
   因为 curl 的多行输出被 PowerShell 当成**字符串数组**，对数组用 `-match` **只会过滤元素、不填充 `$Matches`**。
   修法：先 `-join` 成单个字符串再 `-match`。
2. 读 `cloudflare.com/cdn-cgi/trace` 的 `loc=` 当作出口国家 ——
   **`loc=` 是 Cloudflare 机房的所在国，不是客户端的国家**，这个解读本身就是错的。
   已改用 `ipinfo.io/json` 的 `country` 字段。

---

## §8 Antigravity 侧：DLL hook 别忘

**之前踩过的坑：Antigravity 升级会清空 `resources\bin`，把 hook 静默抹掉。**

```powershell
$BIN = "$env:LOCALAPPDATA\Programs\Antigravity\resources\bin"
Get-ChildItem "$BIN\version.dll","$BIN\config.json" | Select-Object Name,Length,LastWriteTime
```

两个文件都在 → 跳过。缺了 → 从工作区 `ag-proxy-dll\` 复制过去
（`start-ag-proxy.bat` 现在已经会自动做这一步）。

> ⚠️ **DLL 只在进程启动时加载。**
> 改完必须**完全退出 Antigravity（含托盘图标）再重开**，否则改动无效。

**日志位置**（排查时看这个）：
```
%LOCALAPPDATA%\Programs\Antigravity\resources\bin\logs\proxy-YYYYMMDD.log
```
注意在 `logs\` **子目录**里，不在 bin 根目录。

---

## §9 坑清单（对照排查）

| 现象 | 真正原因 | 解法 |
|---|---|---|
| 端口从外面连不上，显示 `no route to host` | **实例内防火墙**（OEL: firewalld / Ubuntu: iptables 兜底 REJECT） | §4.2 |
| **两层都改对了，443 还是 `TIMEOUT`** | ★ **本机装了 Cloudflare WARP / 其他 TUN 隧道，把流量吃掉了** | 断开 WARP 或用 Split Tunnel 排除该 IP（§6） |
| 换了隧道/代理后访问某个 IP:端口 就通不了 | 隧道出口到那个目标的路径问题（**不是目标被封**） | 用 §4.3 的三态诊断 + `getsockname()` 看源 IP |
| 改完防火墙好了一阵，重启又不行 | **没持久化** | §4.2（Ubuntu 那两条持久化命令） |
| 控制台 Security List 改了还是不通 | 两层是**与**关系不是**或**关系 | §4.1 + §4.2 都做 |
| 建实例时提示 shape 在该 AD 不可用 | **E2.1.Micro 只在一个 AD 提供** | 按屏幕上那行警告选 AD（通常是 AD 1） |
| `Out of host capacity` | 免费机型被抢光，不是你没资格 | 换 AD / 等 / 升级 PAYG |
| `firewall-cmd: command not found` | 你用的是 Ubuntu，没有 firewalld | 改走 §4.2 情况 B（iptables） |
| 实例突然变成 Stopped | **闲置回收** | 升级 PAYG（§10） |
| SSH 私钥丢了 | Oracle 只在生成时给一次 | 只能重建实例 |
| 401 通过但 Antigravity 还是 400 | 出口判 CN，或不在 Google 支持地区 | 查 §7 第 2 步 |
| 换了 IP 后客户端连不上 | **你重建过实例**（`reboot` / `Stop/Start` 都**不会**换 IP，见 §10） | 更新 mihomo 里的 `server` |
| `systemctl status sing-box` 报端口占用 | 443 被别的服务占了 | `sudo ss -lntp` 查，或换端口 |
| 修改 `config.json` 后不生效 | 没重启服务 | `sudo systemctl restart sing-box` |
| `sudo` 报"**已在此计算机上禁用 Sudo**"，或 `systemctl` 报"**不是 cmdlet**" | ★ **你在 Windows 本地的 PowerShell 里敲命令，不是在服务器上** | 先 `ssh ...` 登进去，看到 `ubuntu@ag-egress:~$` 提示符再敲（见下方说明） |
| 命令敲完"没有报错也没有输出"，像成功了 | 同上 —— 在错误的 shell 里，命令的副作用完全没发生 | 同上 |

### ★ 本地 shell vs 远程 shell：比报错更危险的"静默什么都没做"

这个坑值得单独说，因为**它不报错**：

| 提示符 | 你在哪 | `sudo` / `systemctl` / `apt` / `iptables` 能用吗 |
|---|---|---|
| `PS C:\WINDOWS\System32>` | Windows 本地 | ❌ 全都不是 Windows 命令 |
| `ubuntu@ag-egress:~$` | OCI 服务器（普通用户） | ✅ （带 `sudo`） |
| `ubuntu@ag-egress:~#` | OCI 服务器（root） | ✅ （不用 `sudo`） |

**判别信号**（任一出现就说明你在 Windows）：
- 提示符以 `PS C:\` 开头
- `已在此计算机上禁用 Sudo。若要启用它，请转到"设置"应用中的 Developer Settings page`
  —— 这是 **Windows 11 自带的 `sudo` 命令**（默认关闭），**和 Linux 的 `sudo` 毫无关系**
- `无法将"systemctl"项识别为 cmdlet、函数、脚本文件或可运行程序的名称`

> **为什么这个坑比报错更危险**：在 Windows 上敲 `sudo iptables ...`，Windows 的 `sudo` 被禁用后
> 直接返回一行提示就结束 —— 如果你没细看，很容易以为"执行了"。而服务器上**什么都没变**。
> 后面再出问题，排查方向就会完全跑偏。
>
> **习惯**：每次要敲 Linux 命令前，先扫一眼提示符。SSH 窗口断开/被关掉后重开 PowerShell，
> **必须重新 `ssh` 登录**。

---

## §10 闲置回收与成本

### 会不会被回收

**官方判定标准** —— 在任意 **7 天窗口**内**同时满足**：

| 条件 | 阈值 | 适用 |
|---|---|---|
| CPU 利用率（95 百分位） | < 20% | 所有机型 |
| 网络利用率 | < 20% | 所有机型 |
| 内存利用率 | < 20% | **仅 A1（ARM）** |

流程：**提前 7 天邮件警告 → 停止实例（不是删除）→ 有容量可重启**。
另外：**实例连续停止 7 天会被自动销毁。**

> **纯代理天然符合"闲置"特征** —— CPU 和网络利用率长期接近 0。
> E2.1.Micro 虽然不是被"点名"的机型，但 CPU + 网络两条它同样满足。

### 解法：升级 PAYG（推荐，操作只要几分钟）

**官方步骤**（源：`docs.cloud.oracle.com/iaas/Content/FreeTier/freetier.htm`）：

> "click the **Upgrade link in the banner at the top of the Console** web page. If you don't see an
> Upgrade link on the page you're viewing, click the Oracle Cloud logo at the top of the Console
> and then look for the **Upgrade link in the sidebar on the right side** of the Console home page."

落地路径：控制台**顶部横幅的 `Upgrade`**（找不到就点左上 Oracle Cloud logo → 首页右侧栏）
→ 核对套餐 → 补/确认付款信息 → 接受条款 → 确认升级 → 等确认邮件（**可能要 1–2 天**）
→ 验收：`Billing & Cost Management → Subscriptions` 里 **Plan Type = Pay As You Go**。

| | 升级前（Always Free） | 升级后（PAYG） |
|---|---|---|
| Always Free 额度 | 免费 | **一样免费**，只对**超出部分**计费 |
| 已有实例 / 数据 | — | **全部保留、不用重建**（官方："You will continue to have access to all of your cloud resources"） |
| 容量限制 | 受限，A1 常 `Out of host capacity` | 官方 FAQ：**"PAYG accounts are subject to different capacity limits"** → 抢机器容易得多 |
| 技术支持 | 无 | 可开工单 |
| 计费风险 | **零**（纯免费账户物理上产生不了费用） | ⚠️ **超出额度会真扣钱** → 必须设预算提醒 |

**关于"豁免闲置回收"的证据等级**：官方那一节的原话是 "Idle **Always Free** compute
instances…"，**没有逐字写明 PAYG 豁免**（社区与支持侧口径普遍认为不受该政策影响）。
→ 本指南标注为 **高置信、非官方逐字**。真要不被打扰，最稳的是"升级 PAYG **+** 让机器有真实负载"。

**升级时可能出现的"扣款"是什么**：官方 FAQ 原文——Oracle 可能做一次**临时
"authorization" 预授权冻结，由银行在 3–5 天内解除，不产生实际扣款**。

**另一条容易漏的账号级条款**（官方 Free Tier FAQ）：

> "Accounts left idle for 30 days or more may be deemed abandoned and become eligible for
> suspension or termination."

→ 这是**账号层面**（不只看实例），定期登录一次控制台即可规避。

**顺序建议**：先把实例跑通 → 确认都在免费额度内 → **再**升级 PAYG
（升级前是纯免费账户，不可能产生费用，可以放心试错）。

> ✅ **已于 2026-09-12 按此顺序完成升级。**
> 升级后 Always Free 资源照旧免费，只对超额部分计费。
> 但**「不可能产生费用」这层保护已失效** → 立刻做 §0.3 里那三件事。

### 成本

| 项 | 免费额度 | 超出的后果 |
|---|---|---|
| E2.1.Micro × 2 | 永久免费 | — |
| 块存储 | 200 GB | 超出按量计费 |
| **出站流量** | **10 TB/月** | 极少可能超出 |
| 公网 IP | 每实例 1 个（临时 IP） | 官方价目表**没有"公网 IP"这一项**；网传"保留 IP 收费"未获官方证实（见下） |
| $300 试用额度 | **30 天** | 到期归零，别用来开付费机型 |

**建议**：升级 PAYG 后，在 `Billing & Cost Management → Budgets` 设预算提醒。
**这不是为了省钱，是为了在异常时第一时间收到邮件。**

#### 预算怎么设（本 tenancy 计价货币 = **SGD**，不是 USD）

| 字段 | 填什么 | 为什么 |
|---|---|---|
| Budget Type | **Monthly**（别选 Custom non-recurring） | non-recurring 最长一年、过期就没了 |
| Target Compartment | **`wujunjr (root)`** | 覆盖全 tenancy，含将来的子 compartment；**别建多个重叠预算**，会收重复邮件 |
| Budget Amount | **1 SGD** | 见下方「为什么是 1 而不是 5」 |
| Day of month | **1** | 跟自然月对齐（注意它按 **UTC** 算，不是北京时间） |

**在 Budget 的 `Budget Alert Rules` 页签下建三条规则**（一个预算可以挂多条）：

| # | Threshold Metric | Threshold Type | 阈值 | 实际金额 | 大概什么时候响 |
|---|---|---|---|---|---|
| ① | **Actual Spend** | Percentage of Budget | **10%** | 0.10 SGD | ★ **最早 —— 第 1~2 天** |
| ② | **Forecast Spend** | Percentage of Budget | **100%** | 1 SGD/月 | 第 3 天（官方硬门槛：至少 3 天数据） |
| ③ | **Actual Spend** | Percentage of Budget | **100%** | 1 SGD | 第 5~6 天，兜底确认 |

> 以上时点按「误开一个 0.2 SGD/天的付费资源」估算。

**三条各自负责什么**：
- **① 是"只要账单上出现一毛钱就报"** —— 这是 earliest possible，
  不等钱攒到 1 SGD。对一个预期花费为 0 的 tenancy，这是最有价值的一条。
- **② 抓"慢漏"** —— 当前花得少、但按速度月化后会超的。
  官方算法是线性外推 `(已花费 ÷ 已过天数) × 当月总天数`。
  ⚠️ 它**最早也要第 3 天**才能响（官方要求至少 3 天消费数据），这是硬门槛，跟预算金额无关。
- **③ 是确认信号** —— 前两条可能误报，这条响就说明钱真没了。

**为什么是 1 SGD 而不是 5 SGD**（本账号取舍）：

预算越小，越能抓到"小额长跑"型泄漏。举例：误开一个 **1.5 SGD/月** 的资源 ——

| 预算 | 会不会报 |
|---|---|
| **1 SGD** | ✅ 会（Forecast 月化 1.5 > 1） |
| 5 SGD | ❌ 全程静默，月底才发现 |

代价是：Forecast 相对 Actual 的提前量从 22 天压缩到约 2 天
（1 SGD：Forecast 第 3 天 / Actual 第 5 天；5 SGD：Forecast 第 3 天 / Actual 第 25 天）。
**但 Forecast 的触发时点在两种预算下都是第 3 天** —— 变的只有 Actual。

> ⚠️ 另一个代价：1 SGD 意味着将来**故意**开小额付费资源（抢 A1、开第二台）时，
> 每月都会收告警邮件。到时再决定忽略、或给那个 compartment 单独建预算 —— 不是现在的问题。

#### 三个必须知道的现实限制

1. **预算是软限制，不会停机器。** 官方原文 "soft limits" —— 它**只发邮件**。
   真要自动止损得走 `Events → Oracle Functions`（取消/停掉资源）。
   对这个量级（几 SGD）来说，收邮件手动删就够了，不值得上 Functions。
2. **有延迟**：Actual 类告警**每 24 小时**评估一次；
   Forecast 虽是**每小时**评估，但**需要至少 3 天消费数据**才会触发
   （所以月初头两天别奇怪为什么没响）。
3. **Email 收件人必须确认订阅**，这是「设了却收不到邮件」的头号原因。
   建完去 `Developer Services → Notifications → Subscriptions` 看状态，
   是 `Pending confirmation` 就去邮箱点确认链接（**两个邮箱都要点**）。

> ⚠️ 预算只告诉你「超了」，**不告诉你是谁花的**。
> 真出事了去 `Billing & Cost Management → Cost Analysis` 按服务维度看，才能定位到具体资源。

### 公网 IP 会不会变？要不要"保留"

**结论：不需要申请 Reserved Public IP。**

官方文档（`/iaas/Content/Network/Tasks/managingpublicIPs.htm`）、VCN FAQ、裸金属停机文档
三处口径一致：

| 官方原文 | 含义 |
|---|---|
| "When you stop an instance, its ephemeral public IPs **remain assigned** to the instance." | **Stop 不释放 IP** |
| "...if you unassign the public IPv4 address explicitly or **terminate** the corresponding resource, the public IPv4 address gets released back into the OCI pool." | 只有**手动 unassign** 或**删除实例/VNIC**时才释放 |
| 裸金属停机超 48h 换物理机："There are no changes to the block volumes, boot volumes, and instance metadata, **including the ephemeral and public IP addresses**." | 连换物理机都不换 IP |

→ **`reboot` 不变；`Stop/Start` 也不变；只有"终止并重建实例"或手动 unassign 才会换。**
→ 所以本文档早期那句"临时 IP 会变、建议预留 Reserved IP"**作废**（那是没实测的保守假设）。

⚠️ **别为了验证去 Stop 实例**：stop 之后不一定立刻启得回来（A1 尤其容易
`Out of host capacity`），且**连续停止 7 天会被自动销毁**。文档已经三处一致，不值当拿生产链路冒险。

**万一将来 IP 真变了**（= 你重建了实例）：改 `mihomo/config-proxy.yaml` 里的 `server` 一行，
再跑 `ag-proxy-check.ps1` 确认 `[E]` 出口判 US，就完事了。

**关于"保留 IP 收费"**：Oracle 2017 年 Reserved Public IP 发布公告原话是
"There is no charge to use this feature"；现行价目表里也**没有"公网 IP"条目**。
网上流传的"$0.01/小时 ≈ $7.3/月"出自第三方文章（易与 AWS 2024 年起对公网 IPv4
收 $0.005/小时混淆）——**未获官方证实，别据此做决定**；真要用，在控制台创建页看它有没有价格提示。

### 附：「保活脚本」这类 GitHub 项目 —— 能用，但它是创可贴，不是解法

社区确实有几个专门做这件事的开源项目（不必自己写）：

| 项目 | 形态 | 说明 |
|---|---|---|
| **`senomorf/loadshaper`**（要看就看这个） | Docker / Helm | 现代做法：跟踪 **7 天滚动 P95**（与 Oracle 度量一致）、`nice 19` 最低优先级、**真实负载上来时自动让路**；x86-64 与 ARM64 都支持；⚠️ 需要**持久卷**存 P95 数据、**每台机只能跑一个实例** |
| `Codycody31/Prevent-OCI-Deletion-for-being-idle` | Bash + cron | 2023 年产物：CPU "waster" + 管理器，低于阈值就 fork worker，每分钟检查 |
| `Monster-ZeroX/Oracle-Cloud-Always-Free-CPU-and-RAM-Maintainer` | Python + systemd | 目标：CPU 维持 10–15%、内存 10% |

**原理只有一个**：主动制造负载，让**至少一个**指标顶到 20% 以上。

> ★ 关键认知：三个条件是 **AND** 关系 —— **只要有一项不满足，就不算闲置**，所以**只需保一项**。

**对你这台 `E2.1.Micro`，有一个有利事实**：

> 官方原文："Memory utilization is less than 20% (**applies to A1 shapes only**)"

→ **内存维度对你不适用**，你只需要搞定 **CPU(95p)** 或 **网络** 其中一项。
- **CPU 侧最划算**：E2.1.Micro 是 burstable（基线 1/8 OCPU），一个小 busy loop 就够。
  ⚠️ 不确定项：**"20%" 的基数按基线还是按突发上限算**，文档没写清 → 标为未证实。
- **网络侧不推荐**：E2.1.Micro 出网 50 Mbps → **20% ≈ 10 Mbps 持续外部流量**，
  而且**私有段流量不算数**。纯刷流量既费额度又容易被 ISP 侧看出异常。

**为什么我仍建议先升 PAYG，而不是先上保活脚本**：

| | 保活脚本 | 升 PAYG |
|---|---|---|
| 工作量 | 装容器/脚本 + 持久卷 + 长期盯着 | 点一次，之后不用管 |
| 效果 | 靠"指标没过线"，**不保证**（P95 是滑动窗口） | 结构性消除 |
| 代价 | 长期占用 CPU + 需要维护 | 0 元（额度内）；风险只在"意外超额"→ 用预算提醒兜住 |
| 治得了账号级 30 天闲置条款吗 | ❌ | ❌（定期登录一次控制台即可） |

**★ 比"保活"更该马上做的两件事**：

1. **确认你会看到那封警告邮件。** 回收流程是
   `提前 7 天邮件警告 → 停止实例（不是删除）→ 连续停止 7 天 → 销毁`
   → 你其实有**约 14 天的反应窗口**，前提是邮件真被看到。OCI 通知发到**账号注册邮箱**，
   先确认那个邮箱你每天会看（或加一条转发规则）。
2. **把"整机可重建"做出来**：`sing-box` 服务端配置 + `iptables` 规则 + 依赖包
   → 本地已有留档（`oci-egress/`），再加一份"从零重建"清单，被收了当晚就能恢复。
   （E2.1.Micro 几乎随时可开，比 A1 好抢得多。）

**结论**：保活脚本可当"暂不升级时的保险"，但**优先级排在 PAYG 之后**；
而"确认邮件可见 + 可重建"这两件事，无论升不升级都该做。

---

## §11 抗封锁升级：改用 VLESS + Reality（备用方案）

### 什么时候需要

- ss2022 用一段时间后开始**被限速 / 连接频繁中断 / 完全连不上**
- 说明这个 IP + 协议被识别了

### 先做最便宜的尝试

1. **换公网 IP**：把实例的公网 IP **unassign 再重新分配**（会拿到新地址），或直接终止重建实例
   （⚠️ `stop/start` **不会**换 IP —— 官方文档确认 IP 与实例生命周期绑定至 unassign/终止，见 §10）
2. **换端口**：443 → 8443 之类的
3. 都无效 → 上 Reality

### Reality 为什么值得上

- **不需要域名、不需要证书**（它"借用"一个真实大站的 TLS 握手特征）
- 从中间人视角看，你的流量就是"在访问 `www.microsoft.com`"
- 目前抗主动探测能力最强的方案之一

### 服务端改法（思路，非完整脚本）

把 §5 的 `inbounds` 从 shadowsocks 换成 `vless` + `tls.reality`：
- 用 `sing-box generate reality-keypair` 生成公私钥
- `handshake.server` 选一个**国外大站**（如 `www.microsoft.com:443`）
- `short_id` 随便生成一个十六进制串

客户端对应：`type: vless` + `tls: true` + `reality-opts`（填 public-key 和 short-id）。

> **这一节刻意不给完整配置** —— 因为它是"备用方案"，
> 需要的时候说一声，我照你当时的实际参数写一份能直接粘的。

---

## §12 最终架构（跑通后长这样）

```
  language_server.exe (Go)
      │  version.dll（MinHook 钩 Winsock）
      ▼
  mihomo 127.0.0.1:7897
      │  ss2022（443）
      ▼
  Oracle Cloud VM（E2.1.Micro，出口非中国）
      │
      ▼
  cloudcode-pa.googleapis.com ✓

  备用：CF Worker（现判 CN，留作 fallback 兜底）
```

**和之前方案的唯一区别**：出口从"CF 共享池（判 CN）"换成了
"OCI 独享 IP（非中国）"。前面的接入方式完全没变。

---

## 附录：做这件事会顺便学到的 Linux 技能点

既然选了 Ubuntu 是为了学 Linux —— 下面这张表是**这次任务里真实会用到的**，
跟着走一遍，比单独看教程印象深。

| 命令 / 概念 | 在这里干什么 | 值得想明白的点 |
|---|---|---|
| `ssh -i <私钥> ubuntu@<IP>` | 登录服务器 | 公钥/私钥非对称认证；**为什么私钥必须 `chmod 600`** |
| **看提示符**（`PS C:\...>` vs `ubuntu@ag-egress:~$`） | 判断自己在本地还是远程 | ★ **命令在错误的 shell 里跑，往往不报错、只是什么都没做** —— 比报错更难发现 |
| `ssh-keygen -t ed25519` | 生成密钥对 | 为什么现在推荐 ed25519 而不是 RSA |
| `apt-get update` / `apt-get install` | 装软件 | **`update` 只刷新索引，不升级任何软件** —— 最容易搞混的一对 |
| `sudo sh -c '... > file'` | 写受保护文件 | **`>` 由当前 shell 执行，权限来自你**，所以 `sudo cmd > file` 会 Permission denied |
| `sudo tee file > /dev/null` | 写 config.json | 同时写文件 + 输出到屏幕；`sudo` 场景下写文件的标准解法 |
| `systemctl enable --now X` | 启动并设开机自启 | **`enable`（开机自启）和 `start`（现在启动）是两件独立的事** |
| `systemctl status` / `journalctl -u sing-box -f` | 看服务和日志 | 学会**用日志定位问题**，而不是靠猜 |
| `ss -lntp` | 确认端口在监听 | `l`=listen `n`=数字端口 `t`=tcp `p`=显示进程 |
| `iptables -L INPUT -n --line-numbers` | 看防火墙规则 | ★ **规则按顺序匹配、命中即停** |
| `iptables -I` vs `-A` | 控制插入位置 | 顺序错了，规则**等于不存在** —— 理解 iptables 的第一课 |
| `netfilter-persistent save` | 规则持久化 | 很多"运行时生效"的改动，**重启就没了** |
| `grep` / `head -n 8` | 复核改动 | **改完必须验证，别假设成功** |
| `curl -v` / `-x` / `-o /dev/null -w "%{http_code}"` | 测端口 / 测代理 / 只看状态码 | `-x` 走代理，`-w` 只打印想知道的东西 |
| `openssl rand -base64 32` | 生成密钥 | 32 字节 → base64 后 44 字符 |

**建议的节奏**：每跑一条没见过的命令，先 `man <命令>` 或 `<命令> --help` 扫一眼再回车。
一次任务下来，上面这 14 条够你摸到 Linux 运维的骨架了。

---

## 附：最短路径清单（打勾用）

- [ ] §0.1 确认 Home Region 不是中国 → **已确认：US East (Ashburn)** ✅
- [x] §0.3 升级 PAYG —— **2026-09-12 已完成**（跑通之后升的，顺序正确）
- [ ] §2 VCN Wizard 建网络
- [ ] §3 建实例：
  - [ ] **用屏幕警告指定的那个 AD**（本账号 = **AD 1**）★
  - [ ] Shape = **`VM.Standard.E2.1.Micro`**（AMD，不是 ARM）+ 绿色 `Always Free-eligible`
  - [ ] Image = **Canonical Ubuntu 24.04 LTS**（点 Change image 换）
  - [ ] ✅ 勾 **Assign a public IPv4 address**
  - [ ] SSH 公钥贴进去（**别用 Generate，私钥只给一次**）
  - [ ] Boot volume 保持默认，**不勾 backup policy**
- [ ] SSH 登录：`ssh -i <私钥> ubuntu@<公网IP>`（Ubuntu 用户是 `ubuntu`，不是 `opc`）
- [ ] §4.1 Security List 加 TCP 443 入站
- [ ] §4.2 **实例内防火墙放行 443**：`iptables -I INPUT 1` → 复核 → **持久化** ★
- [ ] §4.3 本机测端口：必须是 `refused` 不是 `no route to host`
- [ ] §5 装 sing-box，抄下 `YOUR_KEY`
- [ ] §6 mihomo 加 `ag-oci` 节点 + 重排 AG-TUNNEL + 重启
- [ ] §7-1 curl 得 401
- [ ] §7-2 ipinfo 出口非 CN
- [ ] §7-3 **Antigravity 真调一次通过** ★★★
- [ ] §8 确认 DLL hook 在 + 完全重启 Antigravity
- [ ] §10 设 **1 SGD** 预算 + 三条告警（**Actual 10%** / **Forecast 100%** / **Actual 100%**）+ 确认邮件订阅 ★ 已升 PAYG，这条现在是**必做**不是可选
- [ ] §10 升级后复查：`Cost Analysis` 当前花费 = **0**；`Subscriptions` 的 Plan Type = **Pay As You Go**
