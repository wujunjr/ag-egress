# Second sweep: autostart surfaces the first scan did not cover,
# plus a hunt for WorkBuddy's own openAtLogin preference.
# READ ONLY.  PowerShell 5.1.

$ErrorActionPreference = 'SilentlyContinue'
$out = "D:\Windsurf_Workspace\ag-egress\_tools\autostart-scan2.log"
function W($s) { $s | Out-File -FilePath $out -Append -Encoding utf8 }

"=== deep autostart scan: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -FilePath $out -Encoding utf8
W ""

# ---------- A. every classic autostart registry location ----------
W "########## A. classic autostart registry locations (non-empty only) ##########"
$keys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunServices',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunServicesOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System\Shell',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\Run',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\load',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell',
    'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Userinit',
    'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Policies\Microsoft\Windows\System\Scripts\Logon',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnceEx',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunServices',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Windows\AppInit_DLLs',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Userinit',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify',
    'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Terminal Server\Install\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Active Setup\Installed Components'
)
foreach ($p in $keys) {
    if (-not (Test-Path $p)) { continue }
    $v = Get-ItemProperty -Path $p
    $vals = $v.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
    if (-not $vals) { continue }
    W "--- $p ---"
    foreach ($x in $vals) {
        $s = [string]$x.Value
        if ($x.Value -is [byte[]]) {
            $s = "[" + (($x.Value | ForEach-Object { $_.ToString('x2') }) -join ' ') + "]"
        }
        W ("  {0} = {1}" -f $x.Name, $s)
    }
}
W ""

# ---------- B. Active Setup StubPath values ----------
W "########## B. Active Setup StubPath values ##########"
foreach ($root in @('HKLM:\Software\Microsoft\Active Setup\Installed Components', 'HKCU:\Software\Microsoft\Active Setup\Installed Components')) {
    if (-not (Test-Path $root)) { continue }
    $children = Get-ChildItem -Path $root
    foreach ($c in $children) {
        $sp = (Get-ItemProperty -Path $c.PSPath).StubPath
        if ($sp) { W ("  {0}" -f $c.PSChildName); W ("      {0}" -f $sp) }
    }
}
W ""

# ---------- C. keyword sweep, bounded to \Windows\CurrentVersion trees ----------
W "########## C. keyword sweep: any value mentioning ag-proxy / ag-egress ##########"
$hits = @()
foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion', 'HKLM:\Software\Microsoft\Windows\CurrentVersion', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion')) {
    if (-not (Test-Path $root)) { continue }
    $subs = Get-ChildItem -Path $root -Recurse
    foreach ($k in $subs) {
        $props = Get-ItemProperty -Path $k.PSPath
        if (-not $props) { continue }
        foreach ($pr in $props.PSObject.Properties) {
            if ($pr.Name -match '^PS') { continue }
            if ([string]$pr.Value -match 'ag-proxy|ag-egress|start-ag-proxy|hysteria') {
                $hits += ("{0} :: {1} = {2}" -f $k.PSPath, $pr.Name, [string]$pr.Value)
            }
        }
    }
}
if ($hits.Count -gt 0) { foreach ($h in $hits) { W "  HIT: $h" } }
else { W "  (nothing under any \\Windows\\CurrentVersion tree mentions ag-proxy / ag-egress / start-ag-proxy / hysteria)" }
W ""

# ---------- D. WorkBuddy openAtLogin preference ----------
W "########## D. WorkBuddy openAtLogin preference hunt ##########"
$cfgRoots = @("$env:USERPROFILE\.workbuddy", "$env:USERPROFILE\.workbuddy-ai")
$patterns = 'autoLaunch|auto-launch|autolaunch|openAtLogin|open-at-login|startAtLogin|launchOnBoot|startup'
foreach ($cr in $cfgRoots) {
    W "--- $cr ---"
    if (-not (Test-Path $cr)) { W "  (not present)"; continue }
    $files = Get-ChildItem -Path $cr -Force -File | Where-Object { $_.Name -match '\.(json|js|txt|log|yaml|yml)$' -and $_.Length -lt 4000000 }
    foreach ($f in $files) {
        $m = Select-String -Path $f.FullName -Pattern $patterns -ErrorAction SilentlyContinue
        if ($m) {
            foreach ($x in $m) {
                $line = $x.Line.Trim()
                if ($line.Length -gt 240) { $line = $line.Substring(0, 240) }
                W ("  {0}:{1}: {2}" -f $f.Name, $x.LineNumber, $line)
            }
        }
    }
}
W ""

# ---------- E. proxy state now ----------
W "########## E. proxy processes + WinINet system proxy ##########"
$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'hysteria|mihomo|Clash.Meta|Clash\.Meta' }
if ($procs) { foreach ($p in $procs) { W ("  RUNNING pid {0}  {1}" -f $p.ProcessId, $p.Name) } }
else { W "  (hysteria.exe / mihomo NOT running right now)" }
W ""
$ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if (Test-Path $ie) {
    $v = Get-ItemProperty -Path $ie
    W ("  ProxyEnable   = {0}" -f $v.ProxyEnable)
    W ("  ProxyServer   = {0}" -f $v.ProxyServer)
    W ("  ProxyOverride = {0}" -f $v.ProxyOverride)
    W ("  AutoConfigURL = {0}" -f $v.AutoConfigURL)
}
W ""
W "=== end of deep scan ==="
