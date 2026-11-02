ag-egress —— Antigravity 出口代理 · U 盘便携包
=================================================

这个文件夹可以整个拷到另一台 x64 Windows 电脑上直接用，不需要安装任何东西。
（唯一可选的外部依赖是 Antigravity 本身，见第 3 节。）


1. 怎么用
---------
把整个 ag-egress 文件夹拷到目标电脑（桌面、D 盘、U 盘上都行 —— 放哪都能跑，
脚本自己认路），然后双击：

    start-ag-proxy.bat

看到 [E] 那一段的出口国家是 US 就对了。
用完双击 stop-ag-proxy.bat 停掉。

⚠️ 不要只拷 start-ag-proxy.bat 一个文件 —— 它需要同目录下的
   mihomo\、hy2\、ag-proxy-dll\ 和几个 .ps1。整个文件夹一起拷。


2. 前提条件
-----------
- x64 Windows（包里是 amd64 的程序）
- 目标电脑能直接上外网（不需要能上 Google，但基础网络要通）
- **Cloudflare WARP 必须是 Disconnected 状态**。实测 WARP 连着的时候到 VPS 的
  TCP 会 8/8 超时。如果目标电脑装了 WARP，先把它断开。
- 端口 7897 / 7898 / 7899 不能被别的程序占着
- 杀软可能拦截（脚本要改系统代理 + 写注册表）。如果被杀软删文件，把整个文件夹
  加进白名单。


3. 目标电脑没装 Antigravity 也能用
----------------------------------
包里带了一个 version.dll 钩子，作用是让 Antigravity 的 language_server.exe 走代理。
- 装了 Antigravity → 脚本自动把钩子装进它的 resources\bin，[0/4] 显示 OK。
- 没装 → [0/4] 显示 [SKIP]，**这不是错误**。此时这个包就是一个普通的系统代理：
  浏览器等走 Windows 系统代理的程序都会走隧道，只是没有 Antigravity 可用。


4. 出问题怎么办
---------------
双击 fix-network.bat。它会：
- 检查并清掉「上次用完没停干净」的系统代理（这是最常见的「开机后网络不通」原因）
- 打印 WARP 状态、各网卡 DNS、默认路由、连通性

日志落在 net-rescue.log，出问题把它发出来。


5. 代理会自动过期（不用担心忘关）
---------------------------------
start-ag-proxy.bat 打开系统代理时，会同时挂一条**一次性的**清理任务：
下次登录时把系统代理复位，然后这条任务自己消失（Windows 的 RunOnce 机制）。
所以就算关机前忘了跑 stop-ag-proxy.bat，重启后网络也是好的。

清理脚本会被复制到 %LOCALAPPDATA%\ag-egress\proxy-autoclean.ps1 —— 之所以
不放在本文件夹里，是因为本文件夹可能在 U 盘上：U 盘一拔清理就跑不了了。
（下次登录时会闪一下命令行窗口，跑完即消失，不是常驻自启项。）


6. ⚠️ 安全提醒
--------------
mihomo\config-proxy.yaml 和 hy2\client.yaml 里**含服务端密码**。
这个 U 盘等于你隧道的一把钥匙：
- 别借人、别丢
- 真丢了，去 OCI 上换密码（参考项目里的 oci-egress\REBUILD-CHECKLIST.md）


7. 已知限制
-----------
- 只支持 x64 Windows
- 需要 PowerShell 5.1（Windows 10 / 11 自带）
- **不需要管理员权限**，脚本全程不提权
- 隧道另一端是美国 Ashburn 的 Oracle VPS，出口 IP 203.0.113.10
- 换电脑后第一次跑，如果目标机装了 Antigravity 但版本不同，钩子会自动重新部署


技术细节和完整文档见项目里的 README.md。
