# system-proxy-autoclean.ps1
# ASCII-only on purpose (PowerShell 5.1 + UTF-8 no-BOM = GBK decode trap).
#
# WHY THIS EXISTS
# ---------------
# ProxyEnable lives in the registry, so it SURVIVES A REBOOT. The failure mode,
# seen 2026-09-28:
#   run start-ag-proxy.bat  -> ProxyEnable=1, ProxyServer=127.0.0.1:7897
#   reboot WITHOUT running stop-ag-proxy.bat
#   -> the machine comes back with the system proxy still pointing at
#      127.0.0.1:7897 while nothing listens there
#   -> every WinINet app (Edge, Chrome, Electron, Microsoft Store, Windows
#      Update) hangs on a dead port and the machine looks OFFLINE.
# Antigravity itself is unaffected -- its hook talks to mihomo directly.
#
# HOW IT IS UNDONE
# ----------------
# system-proxy.ps1 enable writes a SELF-DELETING RunOnce entry pointing here.
# Windows deletes a RunOnce value BEFORE executing it, so:
#   * the cleanup runs exactly once, at the next logon, then disappears
#   * no permanent autostart item is left behind
# This script restores the proxy state that was in effect BEFORE the proxy was
# turned on (saved to mihomo\.proxy-prev.json), or simply disables the proxy if
# nothing was saved.
#
# It is safe to run by hand at any time -- e.g. from fix-network.bat.

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$save = Join-Path $root 'mihomo\.proxy-prev.json'
$log = Join-Path $root 'proxy-autoclean.log'

function Write-Log([string]$m) {
  $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function Notify-WinINet {
  Add-Type -Namespace W -Name I -MemberDefinition @'
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
'@
  [W.I]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null  # SETTINGS_CHANGED
  [W.I]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null  # REFRESH
}

$before = (Get-ItemProperty -Path $key).ProxyEnable
Write-Log ('run: ProxyEnable was {0}' -f $before)

$done = $false

if (Test-Path $save) {
  try {
    $s = Get-Content -Raw -Path $save | ConvertFrom-Json
    Set-ItemProperty -Path $key -Name ProxyEnable -Value ([int]$s.ProxyEnable) -Type DWord
    if ($null -ne $s.ProxyServer) { Set-ItemProperty -Path $key -Name ProxyServer -Value ([string]$s.ProxyServer) -Type String }
    if ($null -ne $s.ProxyOverride) { Set-ItemProperty -Path $key -Name ProxyOverride -Value ([string]$s.ProxyOverride) -Type String }
    Write-Log ('restored saved state: ProxyEnable={0} ProxyServer={1}' -f $s.ProxyEnable, $s.ProxyServer)
    $done = $true
  } catch {
    Write-Log ('saved state unreadable ({0}) -> falling back to disable' -f $_.Exception.Message)
  }
  Remove-Item -Path $save -Force -ErrorAction SilentlyContinue
}

if (-not $done) {
  Set-ItemProperty -Path $key -Name ProxyEnable -Value 0 -Type DWord
  Write-Log 'no saved state -> ProxyEnable set to 0 (proxy off)'
}

Notify-WinINet
$after = (Get-ItemProperty -Path $key).ProxyEnable
Write-Log ('done: ProxyEnable is now {0}' -f $after)
