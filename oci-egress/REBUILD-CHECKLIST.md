# 可重建清单（Rebuild Runbook）

> **目的**：万一 `ag-egress` 实例被 Oracle 收回 / 误删 / 磁盘损坏 / 账号出问题，
> 照着这一页 + 一个脚本，**半小时内**把整条链路原样恢复。
> 建立于 2026-09-11，配套冷备份：`<cold-backup-dir>\`。

---

## 0. 这是什么、为什么比"保活"更优先

"可重建"不是一个技术方案，是**把重建所需的全部信息从"散在脑子和对话里"固化成一页纸 + 一个脚本**。

| | 保活脚本 | 可重建清单 |
|---|---|---|
| 在赌什么 | 赌"不会被收" | **被收了也不怕** |
| 前提 | 假设 Oracle 的判定不会命中你 | 不依赖任何假设 |
| 失效场景 | 账号级条款、误删、磁盘损坏、风控 | 只失效于"你连备份都丢了" |

两者不是二选一：**先有可重建（零成本、零风险），再谈保活。**

---

## 1. 现状快照（重建时照这个填）

| 项 | 现状值 | 说明 |
|---|---|---|
| 实例名 | `ag-egress` | |
| Home region | **US East (Ashburn) / `us-ashburn-1`** | ⚠️ 注册后**永久不可改**；重建必须在同一 home region |
| Availability Domain | **`AD-1`** | `E2.1.Micro` 只在一个 AD 提供，选别的会报 shape 不可用 |
| Shape | **`VM.Standard.E2.1.Micro`** | x86 / 1/8 OCPU（burstable）/ 1 GB / 出网 50 Mbps |
| Image | **Canonical Ubuntu 24.04 LTS**（不带 Minimal、不带 aarch64） | |
| VCN / 子网 | `ag-vcn` / `public subnet-ag-vcn` | 用 **Start VCN Wizard** 建 |
| Public IPv4 | `Yes`（临时 IP，现为 `203.0.113.10`） | 重建后地址会变 → 只需改客户端一行 |
| 服务端口 | **TCP 443**（ss2022） | 云 Security List + 实例内 iptables **两层都要开** |
| SSH 用户 | `ubuntu` | 私钥 `C:\Users\<you>\.ssh\id_ed25519`（已进冷备份） |
| ss2022 密钥/UUID | 见工作区 `mihomo/config-proxy.yaml` + 本目录 `sing-box-server-config.json` | **含密钥，勿外传** |

**建议补齐**（从控制台抄下来写进本表，重建时能省时间；没有也能重建）：

- [ ] 实例 OCID：`ocid1.instance.oc1.iad.…`
- [ ] VCN OCID / Security List OCID：
- [ ] 账号注册邮箱（**重要**：Oracle 的回收警告邮件发到这里）
- [ ] 该邮箱是否每天会看 / 是否已设转发规则

---

## 2. 重建步骤

### A. 控制台侧（约 10 分钟）

1. **VCN**：Networking → VCN → **`Start VCN Wizard`**（❌ 不是 `Create VCN`，后者只建空 VCN、实例上不了网）
2. **建实例**：Compute → Instances → Create
   - Availability domain = **AD-1**（屏幕会提示 E2.1.Micro 只在此 AD）
   - Image = **Canonical Ubuntu 24.04**
   - Shape = `VM.Standard.E2.1.Micro`
   - Public IPv4 = `Yes`；Use NSG = `No`
   - **不要**勾自定义 boot volume size；**不要**勾 `Encrypt with a key that you manage`（会卡在选 Vault 密钥）
   - SSH keys = **Paste public keys** → 粘贴 `id_ed25519.pub` 全文（❌ 不要选 Generate，私钥只有一次下载机会）
3. **Security List** 加一条入站：`Source 0.0.0.0/0` / `TCP` / `Destination Port 443`（填完**必须点提交**，判据是规则出现在列表里）
4. **记下新的公网 IP**

> 逐屏细节与坑见 `../OCI出口搭建指南-Antigravity.md` §2 / §3，Review 页验收清单也在那里。

### B. 服务端（约 5 分钟，一条命令）

在 Windows 本地（PowerShell）：

```powershell
scp -i "$env:USERPROFILE\.ssh\id_ed25519" "<PROJECT_ROOT>\oci-egress\rebuild-server.sh" ubuntu@<新IP>:~/
ssh -i "$env:USERPROFILE\.ssh\id_ed25519" ubuntu@<新IP>
```

在服务器上（提示符必须是 `ubuntu@ag-egress:~$`）：

```bash
sudo bash rebuild-server.sh '<ss2022 密钥>'    # 密钥见 mihomo/config-proxy.yaml 的 password 字段
```

脚本自动完成：装 sing-box → 写 `/etc/sing-box/config.json` → `systemctl enable --now` →
放行 443 并**持久化** → 自验（监听状态 + 出口国家）。

### C. 客户端侧（约 3 分钟）

1. 改 `mihomo/config-proxy.yaml` → `ag-oci` 节点的 `server` 改成新 IP（**只改这一行**）
2. `stop-ag-proxy.bat` → `start-ag-proxy.bat`（**顺序不能反**：DLL 在进程启动时加载）
3. 跑 `ag-proxy-check.ps1` → 看 **`[E]` 出口国家 = `US`**
4. 打开 Antigravity 发一条真实消息 —— **这是唯一真判据**
5. 把新 IP 写回 `README.md`、`.workbuddy/memory/MEMORY.md`、本文件第 1 节

### D. 收尾

- 如果哪天给服务挂过域名/DNS，更新 A 记录（`egress.example.com` 目前无关键作用）
- **考虑轮换 ss2022 密钥**（旧密钥在冷备份/文档里存过多份副本时）

---

## 3. 时间预算与卡点

| 阶段 | 预计 | 常见卡点 | 判据 |
|---|---|---|---|
| 控制台建 VCN + 实例 | 10 min | 点错 `Create VCN`；Change image 弹窗没点 `Select image` | Review 页显示 Ubuntu 24.04 + AD-1 |
| 服务端一键脚本 | 5 min | 443 从外面不通 | 内层 `iptables -L` 有 443；外层 Security List 有规则 |
| 客户端改一行 + 自检 | 3 min | 忘了重启代理 / 先启了 Antigravity | `[E]` 出口国家 = US |
| 真调验收 | 2 min | 400 地区不支持 → 查出口归属 | Antigravity 正常出结果 |

**三态诊断**（判断包卡在哪层，别猜）：
`TIMEOUT` = 云端 Security List ／ `no route to host` = 实例 iptables ／ `Connection refused` = 两层都通、服务没起。

---

## 4. 备份与密钥的存放规则

- 工作区里的 `mihomo/config-proxy.yaml`、本目录的 `sing-box-server-config.json` **都含密钥**
  → **绝对不要推到公开仓库**（GitHub public / gist / 论坛）。
- **冷备份必须离开这台机器**：复制一份到 U 盘 / 另一块盘 + 云盘（**不要只放在 OCI 自己身上**，它就是要防的对象）。
- 备份目录里的 `ssh\id_ed25519` 是**私钥**：建议用 7z 加密压缩（`7z a -p backup.7z <dir>`）后存放，或直接进密码管理器。
- 密钥轮换判据：**只要它被复制到过不受控的地方（聊天记录、截图、公开仓库），就该换。**
  换法：`sudo sing-box generate rand --base64 32` 生成新 KEY → 同时改服务端 config 与客户端 mihomo 节点 → 重启两侧。

---

## 5. 相关文档

| 文档 | 内容 |
|---|---|
| `../OCI出口搭建指南-Antigravity.md` | **完整操作手册**（§2 VCN / §3 建实例逐屏 / §4 两层防火墙 / §5 服务端 / §6 客户端 / §9 坑清单 / §10 回收与 PAYG / §11 Reality 升级） |
| `../README.md` | 10 秒状态 + 血泪坑清单 + 文件地图 |
| ``~/.workbuddy/skills/vps-egress-antigravity/SKILL.md`` | 跨项目可复用的技能版（含诊断工具箱） |
| `rebuild-server.sh` | 本目录，服务端一键重建脚本 |
