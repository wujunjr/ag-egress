@echo off
REM ============================================================
REM  Antigravity egress proxy - stop
REM  - Disables Windows system proxy (so browsers don't dangle on a dead port).
REM  - Kills mihomo.
REM  - Kills the hysteria2 upstream (added 2026-09-20).
REM  - Does NOT touch WARP. WARP must stay Disconnected whenever the OCI
REM    egress is in use (WARP Connected -> to VPS:443 8/8 TIMEOUT, measured
REM    2026-09-11); the start bat's self-check [A] also requires Disconnected.
REM    If you run WARP for normal browsing on the same machine, just keep it
REM    Disconnected and connect it again after OCI work.
REM  ASCII-only on purpose.
REM ============================================================
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------
REM  LOCATE THE PROJECT ROOT -- same block as start-ag-proxy.bat.
REM  If this bat was copied out of the project (Desktop launcher habit),
REM  %~dp0 points at the copy and %ROOT%\system-proxy.ps1 would not exist.
REM  Set AG_EGRESS_ROOT to pin it explicitly.
REM ---------------------------------------------------------------
REM  Flat if/goto chain on purpose -- see the note in start-ag-proxy.bat.
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
pause
endlocal
exit /b 1

:root_found
set "ROOT=%AGROOT%"
echo       using: %ROOT%

:root_ok

REM  Same self-identification as start-ag-proxy.bat -- see the note there.
echo   [i] script : %~f0
echo       root   : %ROOT%

set "PORT=7897"
set "SOCKPORT=7899"

echo.
echo   Antigravity egress proxy - stop
echo   ======================================================
echo.
echo   [1/4] clearing Windows system proxy ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\system-proxy.ps1" disable

REM  Disarm the auto-expiry that start-ag-proxy.bat armed. We are already clean,
REM  and a stale RunOnce would fire at the next logon and stomp whatever proxy
REM  the user set in the meantime.
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v AG-EGRESS-proxy-autoclean /f >nul 2>&1
echo         auto-expiry disarmed
echo.

echo   [2/4] stopping mihomo ...
taskkill /F /IM "Clash.Meta-windows-amd64-compatible.exe" >nul 2>&1
taskkill /F /IM "mihomo.exe" >nul 2>&1
timeout /t 2 /nobreak >nul

netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING" >nul
if %errorlevel% equ 0 (
    echo         force releasing port %PORT% ...
    for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":%PORT% " ^| findstr /i "LISTENING"') do (
        taskkill /F /PID %%p >nul 2>&1
    )
) else (
    echo         stopped
)

echo.
echo   [3/4] stopping hysteria2 upstream ...
taskkill /F /IM "hysteria.exe" >nul 2>&1
timeout /t 2 /nobreak >nul

netstat -ano | findstr ":%SOCKPORT% " | findstr /i "LISTENING" >nul
if %errorlevel% equ 0 (
    echo         force releasing port %SOCKPORT% ...
    for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":%SOCKPORT% " ^| findstr /i "LISTENING"') do (
        taskkill /F /PID %%p >nul 2>&1
    )
) else (
    echo         stopped
)

echo.
echo   [4/4] WARP
sc query CloudflareWARP 2>nul | findstr /i "RUNNING" >nul
if %errorlevel% equ 0 (
    echo         WARP service running.
    echo         OCI egress requires WARP Disconnected. Re-check with: warp-cli status
    echo         (the start bat self-check [A] fails if WARP is Connected.)
) else (
    echo         WARP service stopped. Fine for OCI egress.
)

echo.
echo   ======================================================
echo     mihomo + hysteria stopped. Windows system proxy cleared.
echo     Browsers fall back to direct (or WARP, if you start it).
echo     Run start-ag-proxy.bat before using Antigravity again.
echo   ======================================================
echo.
pause
endlocal
exit /b 0
