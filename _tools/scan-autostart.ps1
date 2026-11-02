# Scan every Windows autostart surface for ag-proxy / WorkBuddy entries.
# Read-only: this script changes nothing.
# Deliberately PowerShell 5.1 compatible (no ?? / ternary / etc.).

$ErrorActionPreference = 'SilentlyContinue'
$out = "D:\Windsurf_Workspace\ag-egress\_tools\autostart-scan.log"

function W($s) { $s | Out-File -FilePath $out -Append -Encoding utf8 }

"=== autostart scan: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -FilePath $out -Encoding utf8
W ""

# ---------- 1. consolidated view ----------
W "########## 1. Win32_StartupCommand (consolidated) ##########"
$sc = Get-CimInstance Win32_StartupCommand
if ($sc) {
    foreach ($c in $sc) {
        W ("  [{0}] {1}" -f $c.Location, $c.Name)
        W ("      cmd : {0}" -f $c.Command)
        W ("      user: {0}" -f $c.User)
    }
} else { W "  (none / unavailable)" }
W ""

# ---------- 2. Run / RunOnce keys ----------
W "########## 2. Run / RunOnce registry keys ##########"
$runPaths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
)
foreach ($p in $runPaths) {
    W "--- $p ---"
    if (Test-Path $p) {
        $v = Get-ItemProperty -Path $p
        $vals = $v.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
        if ($vals) {
            foreach ($x in $vals) { W ("  {0} = {1}" -f $x.Name, $x.Value) }
        } else { W "  (key present, no values)" }
    } else { W "  (not present)" }
}
W ""

# ---------- 3. startup folders ----------
W "########## 3. Startup folders ##########"
function Get-LnkStrings($path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    $s = ""
    $res = @()
    foreach ($by in $b) {
        if ($by -ge 32 -and $by -lt 127) { $s += [char]$by }
        else { if ($s.Length -ge 4) { $res += $s }; $s = "" }
    }
    if ($s.Length -ge 4) { $res += $s }
    return ($res -join " | ")
}
$dirs = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
foreach ($d in $dirs) {
    W "--- $d ---"
    if (Test-Path $d) {
        $items = Get-ChildItem -Path $d -Force
        if ($items) {
            foreach ($i in $items) {
                W ("  {0}   ({1} bytes, {2})" -f $i.Name, $i.Length, $i.LastWriteTime)
                if ($i.Extension -eq '.lnk') { W ("      strings: " + (Get-LnkStrings $i.FullName)) }
            }
        } else { W "  (empty)" }
    } else { W "  (not present)" }
}
W ""

# ---------- 4. scheduled tasks ----------
W "########## 4. Scheduled tasks (non-Microsoft) ##########"
$tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft*' }
if ($tasks) {
    foreach ($t in $tasks) {
        W ("  [{0}] {1}{2}" -f $t.State, $t.TaskPath, $t.TaskName)
        foreach ($a in $t.Actions) { W ("      exec: {0}  args: {1}" -f $a.Execute, $a.Arguments) }
        foreach ($g in $t.Triggers) { W ("      trig: {0}" -f $g.CimClass.CimClassName) }
    }
} else { W "  (none)" }
W ""

W "########## 4b. ALL scheduled tasks whose name/exec mentions our keywords ##########"
$all = Get-ScheduledTask
foreach ($t in $all) {
    $blob = $t.TaskName + " " + ($t.Actions | ForEach-Object { $_.Execute + " " + $_.Arguments })
    if ($blob -match 'workbuddy|ag-proxy|ag-egress|antigravity|hysteria|mihomo|windsurf') {
        W ("  [{0}] {1}{2}" -f $t.State, $t.TaskPath, $t.TaskName)
        foreach ($a in $t.Actions) { W ("      exec: {0}  args: {1}" -f $a.Execute, $a.Arguments) }
        foreach ($g in $t.Triggers) { W ("      trig: {0}" -f $g.CimClass.CimClassName) }
        W ("      author: {0}" -f $t.Author)
    }
}
W ""

# ---------- 5. services ----------
W "########## 5. Services matching keywords ##########"
$svc = Get-CimInstance Win32_Service | Where-Object {
    ($_.Name + " " + $_.DisplayName + " " + $_.PathName) -match 'workbuddy|ag-proxy|antigravity|hysteria|mihomo|windsurf'
}
if ($svc) {
    foreach ($s in $svc) {
        W ("  {0}  ({1})" -f $s.Name, $s.DisplayName)
        W ("      state={0} startMode={1}" -f $s.State, $s.StartMode)
        W ("      path={0}" -f $s.PathName)
    }
} else { W "  (none)" }
W ""

# ---------- 6. installed apps ----------
W "########## 6. Installed programs: workbuddy / windsurf / antigravity ##########"
$uninst = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = Get-ItemProperty $uninst | Where-Object { $_.DisplayName -match 'workbuddy|windsurf|antigravity' }
if ($apps) {
    foreach ($a in $apps) {
        W ("  {0}  v{1}" -f $a.DisplayName, $a.DisplayVersion)
        W ("      loc : {0}" -f $a.InstallLocation)
        W ("      exe : {0}" -f $a.DisplayIcon)
        W ("      uninst: {0}" -f $a.UninstallString)
    }
} else { W "  (none)" }
W ""

# ---------- 7. file-system scan of likely autostart drop points ----------
W "########## 7. Files named *ag-proxy* / *workbuddy* in common autostart-ish dirs ##########"
$scanDirs = @(
    "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:LOCALAPPDATA",
    "$env:APPDATA"
)
foreach ($d in $scanDirs) {
    if (-not (Test-Path $d)) { continue }
    $f = Get-ChildItem -Path $d -Force -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match 'ag-proxy|ag-egress|workbuddy|windsurf' }
    if ($f) {
        W "--- $d ---"
        foreach ($i in $f) { W ("  {0}{1}  ({2})" -f $i.FullName, "", $i.LastWriteTime) }
    }
}
W ""

W "########## 8. Currently running processes: keywords ##########"
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'workbuddy|windsurf|hysteria|mihomo|Clash' -or $_.CommandLine -match 'workbuddy|windsurf|hysteria|mihomo' } |
    ForEach-Object { W ("  pid {0} {1}" -f $_.ProcessId, $_.Name); W ("      {0}" -f $_.CommandLine) }
W ""

W "=== end of scan ==="
