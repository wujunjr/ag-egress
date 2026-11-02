# Third-party notices

This repository redistributes the following third-party components **unmodified**
so that a fresh clone runs without downloading anything. Each remains under its
own license. Nothing here changes the terms of those licenses.

---

## 1. mihomo（Clash.Meta）

| 项 | 内容 |
|---|---|
| 文件 | `mihomo/Clash.Meta-windows-amd64-compatible.exe` |
| 上游 | https://github.com/MetaCubeX/mihomo |
| 许可证 | **GPL-3.0** |
| 说明 | 本项目只调用它、不修改它。二进制原样分发，源码见上游仓库。 |

> GPL-3.0 要求分发二进制时同时提供对应源码（或书面要约）。上游源码地址即上方链接；
> 如需完整源码快照请提 issue。

## 2. Hysteria 2

| 项 | 内容 |
|---|---|
| 文件 | `hy2/hysteria.exe` |
| 上游 | https://github.com/apernet/hysteria |
| 许可证 | **MIT** |
| 说明 | 官方 Windows 客户端二进制，原样分发。 |

## 3. GeoIP / GeoSite 数据

| 文件 | 上游 | 说明 |
|---|---|---|
| `mihomo/Country.mmdb` | MaxMind GeoLite2 | ⚠️ GeoLite2 有独立许可，商用/再分发前请阅读 MaxMind 条款 |
| `mihomo/geoip.metadb` | MetaCubeX/meta-rules-dat | 规则数据库 |
| `mihomo/geosite.dat` | MetaCubeX/meta-rules-dat | 域名分类数据 |

这些文件只用于本项目的规则分流，不构成对其中数据集的任何主张。

## 4. MinHook

| 项 | 内容 |
|---|---|
| 用途 | `ag-proxy-dll/version.dll` 的进程内 hook 实现 |
| 上游 | https://github.com/TsudaKageyu/minhook |
| 许可证 | **BSD-2-Clause** |

`version.dll` 与 `dbghelp.dll` 是本项目作者编译的产物，**本仓库不含其源码**。
它们的作用仅限：让指定的目标进程（`language_server.exe`、`agy.exe` 等）的
Winsock 调用走 `127.0.0.1:7897` 的本地代理。目标进程列表见
`ag-proxy-dll/config.json` 的 `target_processes`。

## 5. 不在本仓库内的东西

- Antigravity 本体（Google 的产品，本项目只通过 DLL 注入影响它的网络行为）
- Windows 系统组件
