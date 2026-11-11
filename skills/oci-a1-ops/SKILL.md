---
name: oci-a1-ops
description: OCI A1.Flex 24h 执行端的日常运维与排障：三个 CN 版 coding agent 客户端每日自动签到、Immich 外部库与家庭相册门户、Cloudflare Tunnel 白名单、Tailscale、systemd user unit、配置冷备、设备码登录恢复。触发词：A1 执行端、签到失败、checkin timer、Qoder 权益中心、rewards iframe、TRAE 签到、WorkBuddy Claim Now、Immich 看不到照片、相册 pending、gallery 门户、手机操控 VPS、/json/list、CDP OOPIF、git push 走 7897。
agent_created: true
---

# OCI A1 执行端运维与签到排障

> 配套完整配置档案：[`docs/OCI-全部配置总览.md`](../../docs/OCI-全部配置总览.md)。
> 本文只放**操作时要用到的判据与命令**，不放背景叙述。

## 何时用

- 某个客户端今天没签到 / timer 报 failed
- 手机上派单没反应、客户端掉登录
- Immich 外部库看不到照片、分享页 pending、门户打不开
- A1 重启后要恢复服务、查卷池、重建 NSG
- 要把配置改动提交到公开仓库

## 🔴 开工前三条

1. **本技能里的地址全是占位符**。真实值在 `local/ENDPOINT.local.md`（本机，已 gitignore）。
   查不到就问用户，**不要从记忆里补真实 IP**。
2. **公开仓库零凭据**：真实 IP、域名、账号、密码、token、设备码链接一律不入库。
3. **签到类操作已由用户预授权**：巡检、改脚本、复跑验证直接做，不必逐步问确认。
   但**登录授权**那一下必须用户本人点设备码链接，AI 不代替确认。

---

## 1. 连接与状态速查

```bash
# 占位：真实 host 见 local/ENDPOINT.local.md
A1=ubuntu@198.51.100.30
KEY=~/.ssh/id_ed25519_a1

ssh -i "$KEY" -o BatchMode=yes "$A1" '
  date -Is
  systemctl --user list-timers --all --no-pager | grep checkin
  systemctl --user is-active workbuddy.service trae.service qoder-cn.service QoderWake.service
'
```

在 ssh 远端命令里用 `systemctl --user` 时，非交互会话可能缺环境，先 export：

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
```

**四个 timer（时区 Asia/Shanghai）**

| 时间 | timer | 作用 |
|---|---|---|
| 08:05 | `checkin-capture.timer` | **只读截图**，不是签到 |
| 08:10 | `checkin-claim.timer` | WorkBuddy |
| 08:15 | `checkin-trae.timer` | TRAE CN |
| 10:05 | `checkin-qoder-cn.timer` | Qoder CN 权益中心 100 credits（10:00 重置） |

**判断成败看这两个，不要只看 timer 的 NEXT**：

```bash
systemctl --user show <unit>.service -p ExecMainStatus --value
journalctl --user -u <unit>.service --since "2 hours ago" --no-pager -o cat | tail -40
```

> `ExecMainStatus=0` 且日志 `Finished` 才是成功；`SKIP` 要读清原因（已领 vs 漏点）。

---

## 2. 签到排障决策树

```
timer 没跑 / 报 failed
├─ 客户端 unit 是否 active？        → 不 active：先拉起客户端，再复跑签到
├─ 登录态是否 logged_in=true？      → false：走 §3 登录恢复
├─ 日志 SKIP 说 "already claimed"   → 核对是否真已领（服务端回执 / 卡片文案），别盲目重跑
├─ 日志 SKIP 说 "button not visible" → 多半是 UI 被弹窗遮挡（见 §2.2）
└─ Qoder CN "iframe/frame not found" → 见 §2.3，别回退旧版脚本
```

### 2.1 WorkBuddy（像素 guard）

- 白按钮框 `(65,693)-(163,721)`，白像素比 ≥0.55 才点 `(114,707)`
- 点后白像素比减半 → `DONE`
- 脚本会先把 WorkBuddy 窗口置前、最小化其它 Electron 窗口，
  否则 TRAE 的引导弹窗会盖住侧栏，毁掉 08:05 的截图
- **绝不盲点**：右侧 `Try Buddy Apps` 和 `Sign out` 就在附近

### 2.2 TRAE CN（模态弹窗是头号杀手）

判据：账号菜单里 `Check in` 黑按钮框 `(211,361)-(281,390)` 暗像素比 ≥0.40 → 点 `(245,377)`。

⚠️ 促销/引导模态框会盖住左下角账号区，导致点 `(101,766)` 完全无效，
日志表现为 `SKIP - no black Check in button (already claimed or UI changed)`。
**这个 SKIP 不等于已领**（实测补领后拿到 `checkin_credits/claim 200 OK`）。

修法（脚本 `scripts/a1_checkin_trae_v2.py`）：

1. `xdotool key Escape` 关模态
2. 暗像素比检测黑横幅 `(430,185)-(850,360)`，阈值 0.50，兜底点 X `(847,202)`
3. 打开账号菜单后仍未出现黑按钮 → 一次受控重试，然后放弃并 SKIP

**服务端回执最硬**：TRAE 日志出现 `/checkin_credits/claim 200 OK` 才算真领到，
像素变灰只是旁证。

### 2.3 Qoder CN（跨域 iframe，最容易走歪）

机制（已实证）：

- 侧栏提示串 `Rewards center, benefits available` 是
  `button[aria-label="Open user menu"]` 里的 sr-only span
- 点开用户菜单后，真正的入口是 `div[role=menuitem]`、innerText 恰为 `Rewards center`
- 点击它会让 CDP `/json/list` **新增一个 `type=iframe` 的独立 target**
  `https://gateway.qoder.com.cn/growth-page/activity-iframe`（OOPIF）

| 做法 | 结论 |
|---|---|
| `get_by_text("Rewards center", exact=True)` | ❌ 提示串更长，永远匹配不到 |
| Playwright 同一进程内重连 CDP | ❌ 新 OOPIF 不会出现在 `pg.frames` |
| 独立子进程重连 | ❌ 仍不稳定（只偶然成功过一次） |
| **原生 CDP WebSocket 直连该 target** | ✅ v7，稳定 |

**v7 三段式**（`scripts/a1_checkin_qoder_cn_v7.py`）：

1. Playwright **只点菜单**，不改任何业务状态
2. `/json/list` 确认 `growth-page` target 存在（判据独立于 Playwright）
3. 标准库手写 WebSocket 连该 target 的 `webSocketDebuggerUrl`，
   `Runtime.evaluate` 读 `document.body.innerText` →
   校验 `100 Credits` 且存在精确文本 `Claim` 且未禁用 → 点击 → 复读卡片

```bash
# 看 target 是否真的生成（这一步决定后续怎么修）
curl -s http://127.0.0.1:9227/json/list | grep -oE '"(type|url)": "[^"]*"' | head
```

🔴 **绝对不要对该 iframe target 调 `/json/close`**。实测会带崩 Qoder CN 主窗口，
systemd 重启后登录态丢失。想验证冷态就等客户端自然重启，别手动关 target。

🔴 **不要回退到 v3~v6**：它们依赖 Playwright 映射 OOPIF。每版在实例
`~/.local/bin/` 有 `.bak-*-20261111` 备份，仅供对照。

---

## 3. 客户端掉登录恢复

主界面显示 `Welcome... / Log in` 或 `~/.qoder-cn/.qoder-app-status.json`
里 `logged_in: false` 时：

1. 点 `Log in` → 出现 `Waiting for browser` + `Copy sign-in link`
2. 点 `Copy sign-in link`，读剪贴板：
   ```bash
   DISPLAY=:99 xclip -o -selection clipboard
   ```
   （或 CDP `navigator.clipboard.readText()`）
3. **立刻把短时效链接单独交给用户**，让他本机浏览器点一下 —— 不必在 VPS 侧闭环
4. 用户确认后复查 `logged_in: true` 和主界面邮箱

> 短时效链接一生成就单独交付，不要夹在长任务里。AI 不代替用户确认授权。

---

## 4. 常见故障对照

| 症状 | 先查 |
|---|---|
| Immich 外部库一张照片都没有 | 容器是否挂了 `/srv/staging/photo:/mnt/staging:ro`；Postgres `library.importPaths` 是否为 `{/mnt/staging}`；改完要重建容器 + 管理页 Scan |
| 直接拷进 `/srv/media/photos` 不显示 | **正常**。Immich 用 Postgres 记资产，必须走 REST 或 External Library |
| 分享页一直 pending / 404 | Cloudflare Tunnel ingress 少放行 API。逐个补：`api/albums`、`api/timeline`、`api/server/*`、`api/assets`、`api/download`、`/light_skeleton.png` |
| 门户报字符串格式化错 | 模板用了 `%s`，CSS 里的 `%` 会炸 → 改 `@@ERR@@` / `@@COUNT@@` / `@@CARDS@@` |
| `git push` 静默无效果 | commit 和 push 串一条了 → 分开执行；且必须走本机 7897 |
| 后台 SSH 任务标 failed | 看 `exit=0` 和远端日志，别看任务状态（known_hosts 更新会误报） |
| 本地全 TIMEOUT | 用 `viewdns.info/portscan/?host=<IP>` 拿外部视角；22/443 open = 实例健康，问题在中国侧 |

---

## 5. 变更与推送纪律

```bash
# ① 只 add 自己新建的文件，别把用户未提交的改动捎上
git add docs/... skills/... README.md

# ② commit 单独发
git commit -m "docs: ..."

# ③ push 单独发，且走本机 7897
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  git -c http.proxy=http://127.0.0.1:7897 \
      -c https.proxy=http://127.0.0.1:7897 push origin main
```

**推送前脱敏自检**（新增内容必须零命中）：

```bash
# 任何非 RFC 5737 示例段的 IPv4 都值得复查
git diff --cached | grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  | grep -vE '203\.0\.113\.|198\.51\.100\.|100\.64\.0\.|127\.0\.0\.1|0\.0\.0\.0|10\.0\.0\.'
```

真实域名、账号邮箱、口令的片段**不要写进仓库里的检查命令**（那本身就是一种泄露）；
把它们放在本机临时脚本里，扫完即删。

提交前先看 `git status --short`：**用户已有的未提交改动不碰**，
`_tools/cdp/` 之类调试产物不入库。

---

## 6. 红线清单

1. **不砍线**：「不启用」≠「删除」、「主要是 X」≠「只能做 X」。
   备用线（R2 / Funnel / Tunnel 其它走法）与国际版 `qoder.service` 都留档不删。
2. **复述 ≠ 复核**：每复述一次结论回原始出处核一遍；「必须/唯一」找不到原文就降级待核。
3. **因果纪律**：机制证据 + 排除混杂 + 可复现；`TIMEOUT` ≠ 被封，`401` ≠ 绿灯，
   `SKIP` ≠ 已领。
4. **不用 Agent 去签到**：一次 Agent 任务耗 199.99 积分 > 领到 100。
   签到只用官方 UI 模拟点击，不逆向 API。
5. **工具链**：`.bat`/`.ps1` 纯 ASCII；不从 Bash 调 `powershell.exe`；
   Bash 起的后台进程会话结束即消失；OCI SDK 用本机 Python 3.13。
6. **签到预授权 ≠ 越权**：改脚本、复跑随时做；但登录确认、公开发布范围、
   删除操作仍需用户明确点头。

---

## 7. A1 重启后恢复顺序

1. 冷备对象取回配置（本机解密，密钥 `local/a1-backup.key` 绝不上传）
2. 查卷池余量再建实例；NSG 只放 `22/TCP + 41641/UDP + egress all`
3. 恢复 `/srv/staging/photo` 只读挂载与 Postgres `importPaths`
4. 四个 systemd user unit + 四个 timer，确认 `loginctl enable-linger`
5. 三个客户端重新登录，核对 `logged_in: true`
6. **手机端实际派一单**验证 `Enable remote control` 仍为 Enabled
   （桌面 UI 查不到移动端绑定状态）
7. 恢复 Cloudflare Tunnel 白名单与 `/etc/family-gallery.env`
8. 手动跑三个签到 service，看 `ExecMainStatus` + 日志

---

## 附带脚本

| 文件 | 用途 |
|---|---|
| `scripts/a1_checkin_qoder_cn_v7.py` | Qoder CN 签到终版（原生 CDP WebSocket 直连 OOPIF） |
| `scripts/a1_checkin_trae_v2.py` | TRAE CN 签到（含模态弹窗处理与受控重试） |

脚本内的路径、端口、坐标基于 `Xvfb :99 @ 1280x800`；换分辨率要重新标定坐标。
部署位置：实例 `~/.local/bin/`，由同名 systemd user service 调用。
