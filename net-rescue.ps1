# net-rescue.ps1
# ASCII-only on purpose (PowerShell 5.1 + UTF-8 no-BOM = GBK decode trap).
#
# Run this when the machine looks OFFLINE after a reboot.
#
# It does two things:
#   1. FIX  -- clears a leftover Windows system proxy. That is the known
#              self-inflicted cause: start-ag-proxy.bat sets ProxyEnable=1 and
#              ProxyServer=127.0.0.1:7897, which SURVIVES a reboot. If mihomo is
#              not running, every WinINet app (Edge, Chrome, Electron, Store)
#              hangs on a dead port and the whole machine looks offline.
#              Guarded: only cleared when nothing is listening on 7897, so a
#              legitimately running proxy is never killed by accident.
#   2. REPORT -- WARP service state, per-adapter DNS, default route, direct
#              reachability. Cloudflare WARP auto-starts (service StartMode=Auto)
#              and rewrites DNS on EVERY adapter to 127.0.2.2/127.0.2.3; if
#              warp-svc is down while that DNS override is still in place, all
#              name resolution fails. That one is NOT caused by this project.
#
# Log: net-rescue.log next to this script.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest progress bar is noise

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$key         = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$runonceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runonceName = 'AG-EGRESS-proxy-autoclean'
$log         = Join-Path $root 'net-rescue.log'
$clean       = Join-Path $root 'system-proxy-autoclean.ps1'

function Line([string]$s) {
  Write-Host $s
  Add-Content -Path $log -Value $s -Encoding UTF8
}

Line ''
Line '=== ag-egress network rescue ==='
Line ('time : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Line ('root : ' + $root)
Line ''

# ---------------------------------------------------------------- 1. FIX
Line '--- [1] leftover system proxy -------------------------------------'
$ie = Get-ItemProperty -Path $key
$listen = @(netstat -ano | Select-String ':7897 ' | Select-String 'LISTENING')
$inUse = ($listen.Count -gt 0)
Line ('  ProxyEnable                = ' + $ie.ProxyEnable)
Line ('  ProxyServer                = ' + $ie.ProxyServer)
Line ('  ProxyOverride              = ' + $ie.ProxyOverride)
Line ('  something listens on 7897  = ' + $inUse)
Line ''

if ($ie.ProxyEnable -eq 1 -and (-not $inUse)) {
  Line '  >> ProxyEnable=1 but NOTHING listens on 7897.'
  Line '  >> THIS is why the network is dead. Clearing it now.'
  if (Test-Path $clean) {
    & $clean
  } else {
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 0 -Type DWord
    Line ('  >> ' + $clean + ' missing - did a plain ProxyEnable=0 instead')
  }
  Remove-ItemProperty -Path $runonceKey -Name $runonceName -Force -ErrorAction SilentlyContinue
  Line ('  >> now: ProxyEnable = ' + (Get-ItemProperty -Path $key).ProxyEnable)
} elseif ($ie.ProxyEnable -eq 1 -and $inUse) {
  Line '  >> ProxyEnable=1 and 7897 IS listening - the proxy is legitimately up.'
  Line '     Left alone. Run stop-ag-proxy.bat if you actually want it off.'
} else {
  Line '  >> ProxyEnable=0 - no leftover proxy. This is NOT the cause of your outage.'
}
Line ''

$ro = Get-ItemProperty -Path $runonceKey
$armed = $ro.PSObject.Properties | Where-Object { $_.Name -eq $runonceName }
if ($armed) { Line ('  auto-expiry armed for next logon: ' + $armed.Value) } else { Line '  auto-expiry: not armed' }
Line ''

# ---------------------------------------------------------------- 2. REPORT
Line '--- [2] WARP ------------------------------------------------------'
$ws = Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'WARP|Cloudflare' }
if ($ws) {
  foreach ($s in $ws) { Line ('  svc  ' + $s.Name + '  state=' + $s.State + '  start=' + $s.StartMode) }
} else { Line '  no Cloudflare WARP service installed' }
$wp = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'warp' }
if ($wp) { foreach ($p in $wp) { Line ('  proc ' + $p.Name + '  pid ' + $p.ProcessId) } } else { Line '  no WARP process running' }
Line '  NOTE: the project docs require WARP Disconnected. WARP Connected was'
Line '        measured to break TCP to the VPS. WARP is NOT started by this project.'
Line ''

Line '--- [3] DNS per adapter -------------------------------------------'
$dns = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses }
if ($dns) {
  foreach ($d in $dns) { Line ('  ' + $d.InterfaceAlias + ' : ' + ($d.ServerAddresses -join ',')) }
} else { Line '  (no adapter has a DNS server configured)' }
Line '  127.0.2.2 / 127.0.2.3 belong to Cloudflare WARP. If warp-svc is dead while'
Line '  DNS still points there, ALL name resolution fails -> looks like no network.'
Line ''

Line '--- [4] default route ---------------------------------------------'
$rt = Get-NetRoute -DestinationPrefix '0.0.0.0/0'
if ($rt) {
  foreach ($r in $rt) { Line ('  ifIndex ' + $r.ifIndex + '  via ' + $r.NextHop + '  metric ' + $r.RouteMetric) }
} else { Line '  NO DEFAULT ROUTE - that alone means no network.' }
Line ''

Line '--- [5] reachability ----------------------------------------------'
foreach ($u in @('https://www.baidu.com', 'https://www.google.com')) {
  try {
    $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing -Proxy $null -ErrorAction Stop
    Line ('  OK   ' + $u + '  status=' + $r.StatusCode)
  } catch {
    Line ('  FAIL ' + $u + '  ' + $_.Exception.Message)
  }
}
Line ''
Line ('=== end. full log: ' + $log + ' ===')
Line ''
