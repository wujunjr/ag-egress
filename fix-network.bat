@echo off
REM ============================================================
REM  ag-egress - network rescue  (double-click when the machine
REM  looks OFFLINE, typically right after a reboot)
REM
REM  Known self-inflicted cause:
REM    start-ag-proxy.bat sets the Windows system proxy to
REM    127.0.0.1:7897, and that setting LIVES IN THE REGISTRY --
REM    it survives a reboot. Reboot without running
REM    stop-ag-proxy.bat and the machine comes back with the proxy
REM    pointing at a port nothing listens on, so Edge / Chrome /
REM    Electron apps / Microsoft Store all hang and it looks like
REM    the internet is gone.
REM
REM  This bat clears that leftover proxy, then dumps WARP state,
REM  per-adapter DNS, the default route and reachability so the
REM  OTHER possible causes can be told apart.
REM
REM  ASCII-only on purpose. Must be CRLF.
REM  Flat if/goto on purpose -- no multi-line ( ) blocks.
REM ============================================================
setlocal
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

if exist "%ROOT%\net-rescue.ps1" goto :run

echo.
echo   [ERROR] net-rescue.ps1 is not next to this bat:
echo             %ROOT%\net-rescue.ps1
echo.
pause
endlocal
exit /b 1

:run
echo   [i] script : %~f0
echo       root   : %ROOT%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\net-rescue.ps1"
echo.
pause
endlocal
exit /b 0
