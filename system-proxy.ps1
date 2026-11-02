# system-proxy.ps1
# ASCII-only on purpose (PowerShell 5.1 + UTF-8 no-BOM = GBK decode trap).
#
# Set or clear the per-user Windows system proxy to point at the local mihomo
# (127.0.0.1:7897). Used by start-ag-proxy.bat / stop-ag-proxy.bat.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File system-proxy.ps1 enable
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File system-proxy.ps1 disable
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('enable','disable')]
  [string]$Action
)
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if ($Action -eq 'enable') {
  Set-ItemProperty -Path $key -Name ProxyEnable  -Value 1                  -Type DWord
  Set-ItemProperty -Path $key -Name ProxyServer  -Value '127.0.0.1:7897'   -Type String
  Set-ItemProperty -Path $key -Name ProxyOverride -Value 'localhost;127.*;<local>' -Type String
  Write-Host '[system-proxy] enabled -> 127.0.0.1:7897 (bypass: localhost, 127.*, <local>)'
} else {
  Set-ItemProperty -Path $key -Name ProxyEnable -Value 0 -Type DWord
  Write-Host '[system-proxy] disabled'
}
# Force WinINet-based apps (Chrome, Edge, WinHTTP, IE) to re-read settings now,
# otherwise they keep the old proxy until next process restart.
Add-Type -Namespace W -Name I -MemberDefinition @'
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
'@
[W.I]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null   # INTERNET_OPTION_SETTINGS_CHANGED
[W.I]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null   # INTERNET_OPTION_REFRESH
Write-Host '[system-proxy] notified running apps'
