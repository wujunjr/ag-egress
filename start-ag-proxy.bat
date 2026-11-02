@echo off
REM ============================================================
REM  Antigravity egress proxy - start
REM  Mode: plain local proxy (NO TUN) -> no admin needed
REM
REM  Chain (2026-09-20 onwards):
REM    language_server.exe (Go)
REM      -- version.dll (MinHook, hooks Winsock) -->
REM    mihomo 127.0.0.1:7897          (all rule-based routing)
REM      -- socks5 -> 127.0.0.1:7899 -->
REM    hysteria.exe (Hysteria2 client, dumb hop)
REM      -- Hysteria2 / QUIC / UDP 8443 -->
REM    Oracle Cloud VPS 203.0.113.10 (Ashburn, US) -> Google API
REM
REM  Why hy2 instead of the old ss2022/TCP443, measured 2026-09-20
REM  (same PC, same minute, same 10 MB file):
REM    ss2022/TCP443 : 60 s timeout, only 560 KB ->  9-16 KB/s
REM    hy2/UDP8443   : 10 MB complete           -> 1.65 MB/s   (~100-180x)
REM  TCP here is capped by RTT 600 ms x 64 KB window (~107 KB/s) and 1.8%
REM  loss pushes it far below that. QUIC's receive window is 20 MB.
REM  The ss node is KEPT as a fallback in the AG-TUNNEL group, so if
REM  hysteria fails to start the chain still works, just slowly.
REM
REM  WARP MUST STAY OFF. Measured 2026-09-11:
REM    WARP on  -> TCP to VPS:443 times out 8/8 (VPS:22 still works)
REM    WARP off -> refused, then works; latency 450ms -> 206ms
REM  WARP used to carry traffic to the Cloudflare Worker. That egress is
REM  abandoned (it is judged CN), so WARP is now redundant AND harmful.
REM
REM  This script is ASCII-only (non-ASCII bytes break .bat parsing).
REM
REM  PORTABLE (2026-09-29): the whole folder can be copied to a USB stick and
REM  run on another x64 Windows machine. Nothing outside the folder is required
REM  except Antigravity itself, and that is optional -- see [0/4].
REM  Build the stick with:  _tools\build-usb-package.ps1
REM ============================================================
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------
REM  LOCATE THE PROJECT ROOT  (do not remove)
REM
REM  This bat is meant to SIT IN the project root and derive every path
REM  from %~dp0. But copying it somewhere else is a natural habit (a Desktop
REM  launcher), and then %~dp0 points at the COPY -- every relative path
REM  breaks and you get a confusing "config not found: <Desktop>\mihomo\...".
REM  That happened on 2026-09-20. So: verify %~dp0, then fall back.
REM
REM  To pin it explicitly, set an environment variable AG_EGRESS_ROOT.
REM ---------------------------------------------------------------
REM  Flat if/goto chain on purpose. Nested ( ) blocks are where batch parsing
REM  silently goes wrong, and this file cannot be executed in the dev
REM  environment (cmd.exe is blocked), so it has to be reviewable by eye.
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

if exist "%ROOT%\mihomo\config-proxy.yaml" goto :root_ok
echo   [i] this bat is not in the project root: %ROOT%
echo       looking for the project ...
set "AGROOT="
if defined AG_EGRESS_ROOT if exist "%AG_EGRESS_ROOT%\mihomo\config-proxy.yaml" set "AGROOT=%AG_EGRESS_ROOT%"
if defined AGROOT goto :root_found
if exist "%USERPROFILE%\ag-egress\mihomo\config-proxy.yaml" set "AGROOT=%USERPROFILE%\ag-egress"
if defined AGROOT goto :root_found
if exist "%USERPROFILE%\ag-egress\mihomo\config-proxy.yaml" set "AGROOT=%USERPROFILE%\ag-egress"
if defined AGROOT goto :root_found
if exist "%~dp0..\mihomo\config-proxy.yaml" set "AGROOT=%~dp0.."
if defined AGROOT goto :root_found
echo   [ERROR] project root not found.
echo           Either run this bat from the project folder itself,
echo           or set AG_EGRESS_ROOT to it.
goto :fail

:root_found
set "ROOT=%AGROOT%"
echo       using: %ROOT%

:root_ok

REM  Identify WHICH copy of this script is running, and what root it resolved.
REM  Added 2026-09-21: a bare "Start failed" was un-diagnosable purely because
REM  there was no way to tell which of the several copies on disk had been
REM  launched. A stale copy outside the project fails the path checks and looks
REM  exactly like a broken install. %~f0 settles it in one line, every run.
echo   [i] script : %~f0
echo       root   : %ROOT%

REM  ---- PORTABLE PATHS (2026-09-29) -------------------------------------
REM  Everything below must work on a machine that has never seen this project.
REM  Two values used to be hardcoded to one user's disk, which made the whole
REM  folder un-copyable:
REM    * the mihomo core lived at D:\v2rayN_v5.39\... -- OUTSIDE the project
REM    * Antigravity's bin dir was C:\Users\john\...
REM  Now: the core is BUNDLED next to this script, and Antigravity is located
REM  via %LOCALAPPDATA% (it is a per-user install).
set "MIHO=%ROOT%\mihomo\Clash.Meta-windows-amd64-compatible.exe"
if not exist "%MIHO%" set "MIHO=D:\v2rayN_v5.39\v2rayN-Core\Clash.Meta-windows-amd64-compatible.exe"
set "CONF=%ROOT%\mihomo\config-proxy.yaml"
set "WD=%ROOT%\mihomo"
set "PORT=7897"
set "HYST=%ROOT%\hy2\hysteria.exe"
set "HYCONF=%ROOT%\hy2\client.yaml"
set "SOCKPORT=7899"
set "DLLSRC=%ROOT%\ag-proxy-dll"
set "LOG=%WD%\proxy-run.log"
set "HYLOG=%ROOT%\hy2\hysteria-run.log"

REM  Find Antigravity. An EMPTY DLLDIR means "not installed on this machine",
REM  which is not an error -- see [0/4] below.
REM  %ProgramFiles(x86)% is deliberately NOT probed: its parentheses break cmd
REM  parsing anywhere but a plain standalone statement.
set "DLLDIR="
if exist "%LOCALAPPDATA%\Programs\antigravity\resources\bin" set "DLLDIR=%LOCALAPPDATA%\Programs\antigravity\resources\bin"
if not defined DLLDIR if exist "%ProgramFiles%\antigravity\resources\bin" set "DLLDIR=%ProgramFiles%\antigravity\resources\bin"
if not defined DLLDIR if exist "C:\Users\john\AppData\Local\Programs\antigravity\resources\bin" set "DLLDIR=C:\Users\john\AppData\Local\Programs\antigravity\resources\bin"

echo.
echo   Antigravity egress proxy - start  [plain proxy, no TUN, no admin]
echo   ======================================================
echo.
echo     language_server.exe --version.dll--^> mihomo :7897
echo        --socks5 :7899--^> hysteria2 --QUIC/UDP8443--^>
echo        Oracle Cloud VPS (Ashburn US) --^> Google API
echo.
echo     WARP must stay OFF. It now breaks this link, not carries it.
echo.

REM  Flat if/goto, same style as the root locator above -- see the note there.
REM  These four used to be multi-line ( ) blocks. On 2026-09-21 that construct
REM  died here without printing its own error message, which cost a lot of
REM  guessing. Flat form cannot fail that way.
if exist "%MIHO%" goto :chk_conf
echo   [ERROR] mihomo core not found: %MIHO%
goto :fail
:chk_conf

if exist "%CONF%" goto :chk_hyst
echo   [ERROR] config not found: %CONF%
goto :fail
:chk_hyst

if exist "%HYST%" goto :chk_hyconf
echo   [ERROR] hysteria client not found: %HYST%
echo           (without it mihomo falls back to the slow ss node)
goto :fail
:chk_hyconf

if exist "%HYCONF%" goto :deps_ok
echo   [ERROR] hysteria config not found: %HYCONF%
goto :fail
:deps_ok

echo   [0/4] checking DLL hook ...
REM  Antigravity is a per-user install. If it is not on this machine there is
REM  nothing to hook, and that is NOT an error -- the package still works as a
REM  plain system proxy for browsers. Skip instead of printing a scary [ERROR].
if not defined DLLDIR goto :dll_skip

REM  An Antigravity update wipes resources\bin and silently removes the hook.
REM  Never just warn: redeploy from the local source copy every single run.
REM  Flat if/goto -- see the note at the top of this file.
if not exist "%DLLSRC%\version.dll" goto :dll_nosrc
if not exist "%DLLDIR%\version.dll" goto :dll_copy
if not exist "%DLLDIR%\config.json" goto :dll_copy
goto :dll_check

:dll_copy
echo         hook missing - Antigravity update wiped it - redeploying
copy /y "%DLLSRC%\version.dll" "%DLLDIR%\version.dll" >nul
copy /y "%DLLSRC%\config.json" "%DLLDIR%\config.json" >nul
echo         copied version.dll + config.json from ag-proxy-dll
goto :dll_check

:dll_check
if not exist "%DLLDIR%\version.dll" goto :dll_missing
if not exist "%DLLDIR%\config.json" goto :dll_nocfg
echo         version.dll + config.json deployed  OK
goto :dll_done

:dll_missing
echo         [ERROR] version.dll still missing - language_server will 400
goto :dll_done

:dll_nocfg
echo         [ERROR] config.json still missing - proxy bypassed
goto :dll_done

:dll_nosrc
echo         [ERROR] source not found: %DLLSRC%\version.dll
goto :dll_done

:dll_skip
echo         [SKIP] Antigravity not found on this machine - no DLL hook deployed.
echo                The Windows system proxy still works for browsers.

:dll_done
echo.

echo   [1/4] starting hysteria2 upstream ...
netstat -ano | findstr ":%SOCKPORT% " | findstr /i "LISTENING" >nul
if %errorlevel% equ 0 (
    echo         stale hysteria on %SOCKPORT% - replacing it
    taskkill /F /IM "hysteria.exe" >nul 2>&1
    timeout /t 2 /nobreak >nul
)
REM  Delete the log only AFTER the port is free -- same reasoning as mihomo's
REM  log below: a stale instance that survives the kill is the only evidence
REM  of what the OLD instance was doing.
if exist "%HYLOG%" del /q "%HYLOG%" >nul 2>&1
start "hysteria-ag-upstream" /min cmd /c ""%HYST%" client -c "%HYCONF%" >>"%HYLOG%" 2>&1"
for /l %%i in (1,1,20) do (
    timeout /t 1 /nobreak >nul
    netstat -ano | findstr ":%SOCKPORT% " | findstr /i "LISTENING" >nul
    if !errorlevel! equ 0 goto :hyok
)
echo         [WARN] SOCKS5 %SOCKPORT% never came up.
echo                The chain still works: mihomo falls back to ag-oci (ss, SLOW).
echo                Check %HYLOG%
goto :mihomo

:hyok
echo         SOCKS5 127.0.0.1:%SOCKPORT% listening
echo.

:mihomo
echo   [2/4] starting mihomo ...
netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING" >nul
if %errorlevel% equ 0 (
    echo         stale instance on %PORT% - replacing it
    echo         (a wedged mihomo keeps bad DNS state and never heals)
    for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":%PORT% " ^| findstr /i "LISTENING"') do (
        taskkill /F /PID %%p >nul 2>&1
    )
    timeout /t 3 /nobreak >nul
)

REM  Only delete the log AFTER the port is truly free. If a stale instance
REM  survives the kill, deleting first destroys the only evidence of what the
REM  OLD instance was doing -- and a new instance that then fails to bind
REM  leaves you with an empty log and a completely wrong diagnosis.
netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING" >nul
if %errorlevel% equ 0 (
    echo         [ERROR] port %PORT% still held after kill - remove it manually:
    netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING"
    echo         Log deliberately NOT deleted: %LOG%
    goto :fail
)

REM  Redirect stdout+stderr to proxy-run.log. Without this, a broken mihomo
REM  leaves zero evidence -- "start /min" alone swallows every error message.
if exist "%LOG%" del /q "%LOG%" >nul 2>&1
start "mihomo-ag-proxy" /min cmd /c ""%MIHO%" -f "%CONF%" -d "%WD%" >>"%LOG%" 2>&1"
for /l %%i in (1,1,30) do (
    timeout /t 1 /nobreak >nul
    netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING" >nul
    if !errorlevel! equ 0 goto :warmup
)
echo   [ERROR] port %PORT% never came up. Check %LOG%
goto :fail

:warmup
REM  mihomo starts listening BEFORE its DNS/upstream is actually usable.
REM  Self-checking right away gives a false "connect failed".
timeout /t 3 /nobreak >nul

:check
echo         listening on 127.0.0.1:%PORT%
echo.
echo   [3/4] self-check
echo         (401 = link up only, NOT a region verdict.
echo          the real pre-check is [E] egress country NOT CN.)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\ag-proxy-check.ps1" -Port %PORT%

echo.
REM  Arm the SELF-DELETING auto-expiry BEFORE enabling the proxy.
REM  ProxyEnable lives in the registry, so it SURVIVES A REBOOT. Reboot with it
REM  left on and the machine comes back pointing at 127.0.0.1:7897 while nothing
REM  listens there -- every WinINet app (Edge, Chrome, Electron, Store) hangs
REM  and the machine looks offline. That is exactly what happened 2026-09-28.
REM  Windows runs a RunOnce value once at the next logon and deletes it first,
REM  so this leaves NO permanent autostart item behind.
REM  The cleaner is DEPLOYED to a stable per-user path first, and the RunOnce
REM  entry points THERE -- not at this folder. Reason: this folder may live on a
REM  USB stick. If the entry pointed at the stick, arming the cleanup and then
REM  rebooting with the stick unplugged would leave the machine with a proxy
REM  aimed at nothing and no way to run the cleanup. %LOCALAPPDATA%\ag-egress\
REM  is always present, whatever happens to this folder.
REM  Guarded on spaces: a RunOnce value cannot carry quotes. Flat if/goto.
if not defined LOCALAPPDATA goto :no_arm
set "CLEANDIR=%LOCALAPPDATA%\ag-egress"
set "CLEANER=%CLEANDIR%\proxy-autoclean.ps1"
if not exist "%CLEANDIR%" mkdir "%CLEANDIR%" >nul 2>&1
copy /y "%ROOT%\system-proxy-autoclean.ps1" "%CLEANER%" >nul 2>&1
if not exist "%CLEANER%" goto :no_arm
if not "%CLEANER%"=="%CLEANER: =%" goto :no_arm
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v AG-EGRESS-proxy-autoclean /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File %CLEANER%" /f >nul 2>&1
if errorlevel 1 goto :no_arm
echo         auto-expiry armed: proxy is undone at the next logon
echo         (cleaner deployed to %CLEANER%)
goto :arm_done
:no_arm
echo         [WARN] auto-expiry NOT armed - the system proxy WILL survive a reboot
echo                (path has a space, or reg.exe failed). Run fix-network.bat
echo                after the next reboot if the network looks dead.
:arm_done

echo         enabling Windows system proxy -> 127.0.0.1:%PORT%  (so browsers route through it too)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\system-proxy.ps1" enable
if errorlevel 1 (
    echo         [WARN] system proxy not enabled. Browsers won't go through mihomo.
    echo         Antigravity still works (DLL hook talks to 127.0.0.1:7897 directly).
)

echo.
echo   [4/4] done
echo.
echo   ======================================================
echo     Look at [E] tunnel egress country first.
echo       not CN  -^> good, go on.
echo       CN      -^> stop, the egress is wrong.
echo
echo     [B2] tells you whether the FAST upstream (hy2) is up.
echo       hy2 up   -^> AG-TUNNEL uses it.
echo       hy2 down -^> AG-TUNNEL silently falls back to ag-oci (ss, SLOW).
echo
echo     Then launch Antigravity and send a prompt.
echo     That credentialed call is THE ONLY real verdict.
echo
echo     Stop: stop-ag-proxy.bat
echo     Logs: ag-proxy-check.log / mihomo\proxy-run.log / hy2\hysteria-run.log
echo   ======================================================
echo.
echo     Keep this window's mihomo running minimized.
echo     Closing this window does NOT stop mihomo or hysteria.
echo.
pause
endlocal
exit /b 0

:fail
echo.
echo     Start failed. Nothing was changed.
echo.
pause
endlocal
exit /b 1
