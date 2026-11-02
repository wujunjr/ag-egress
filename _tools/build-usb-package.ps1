# build-usb-package.ps1
# ASCII-only on purpose (PowerShell 5.1 + UTF-8 no-BOM = GBK decode trap).
#
# Assembles a self-contained folder that can be copied to a USB stick and run on
# another x64 Windows machine.
#
# The SOURCE OF TRUTH stays the project itself. This script only COPIES, so
# there is no second copy of any script to keep in sync by hand -- that is the
# "one original, one pointer" rule from README.md, applied to packaging.
#
# Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File _tools\build-usb-package.ps1
#
# Output: _usb-package\ag-egress\      <-- copy THIS folder to the stick

$ErrorActionPreference = 'Stop'

$src   = Split-Path -Parent $PSScriptRoot          # project root
$stage = Join-Path $src '_usb-package'
$dest  = Join-Path $stage 'ag-egress'

Write-Host ''
Write-Host '=== ag-egress USB package builder ==='
Write-Host ('source : ' + $src)
Write-Host ('output : ' + $dest)
Write-Host ''

# ---------------------------------------------------------------- fresh build
if (Test-Path $stage) {
  Write-Host 'removing previous build ...'
  try { Remove-Item -Path $stage -Recurse -Force -ErrorAction Stop }
  catch { Write-Host ('  [WARN] could not remove old build: ' + $_.Exception.Message) }
}
New-Item -ItemType Directory -Path $dest -Force | Out-Null
foreach ($d in @('mihomo', 'hy2', 'ag-proxy-dll')) {
  New-Item -ItemType Directory -Path (Join-Path $dest $d) -Force | Out-Null
}

# ---------------------------------------------------------------- file list
# Everything the package needs, and nothing else: no logs, no cache.db,
# no probe files, no docs, no _tools.
$files = @(
  'start-ag-proxy.bat',
  'stop-ag-proxy.bat',
  'fix-network.bat',
  'system-proxy.ps1',
  'system-proxy-autoclean.ps1',
  'net-rescue.ps1',
  'ag-proxy-check.ps1',
  'mihomo\config-proxy.yaml',
  'mihomo\Clash.Meta-windows-amd64-compatible.exe',
  'mihomo\Country.mmdb',
  'mihomo\geoip.metadb',
  'mihomo\geosite.dat',
  'hy2\hysteria.exe',
  'hy2\client.yaml',
  'ag-proxy-dll\version.dll',
  'ag-proxy-dll\dbghelp.dll',
  'ag-proxy-dll\config.json'
)

$missing = @()
foreach ($f in $files) {
  $from = Join-Path $src $f
  if (-not (Test-Path $from)) { $missing += $f; continue }
  Copy-Item -Path $from -Destination (Join-Path $dest $f) -Force
}

# The target machine reads this one. Renamed to an ASCII name so this script
# stays ASCII-only; the CONTENT is UTF-8 Chinese and is copied byte for byte.
$readme = Join-Path $src '_tools\usb-package-README-FIRST.txt'
if (Test-Path $readme) { Copy-Item -Path $readme -Destination (Join-Path $dest 'README-FIRST.txt') -Force }
else { $missing += '_tools\usb-package-README-FIRST.txt' }

# ---------------------------------------------------------------- verify CRLF
# cmd.exe mis-parses a .bat whose lines end in LF only, and it does so SILENTLY.
# That cost a whole evening on 2026-09-21, so it is asserted on every build.
Write-Host '--- CRLF check on packaged .bat files ---'
$crlfBad = @()
foreach ($b in @('start-ag-proxy.bat', 'stop-ag-proxy.bat', 'fix-network.bat')) {
  $p = Join-Path $dest $b
  if (-not (Test-Path $p)) { continue }
  $bytes = [System.IO.File]::ReadAllBytes($p)
  $cr = 0; $lf = 0
  foreach ($x in $bytes) { if ($x -eq 13) { $cr++ } elseif ($x -eq 10) { $lf++ } }
  if ($cr -eq $lf -and $cr -gt 0) { Write-Host ('  OK    ' + $b + '  CR=' + $cr + ' LF=' + $lf) }
  else { Write-Host ('  BAD   ' + $b + '  CR=' + $cr + ' LF=' + $lf); $crlfBad += $b }
}

# ---------------------------------------------------------------- manifest
$items = Get-ChildItem -Path $dest -Recurse -File | Sort-Object FullName
$total = ($items | Measure-Object -Property Length -Sum).Sum

$man = New-Object System.Collections.Generic.List[string]
$man.Add('ag-egress USB package manifest')
$man.Add('built : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$man.Add('files : ' + $items.Count)
$man.Add('bytes : ' + $total)
$man.Add('')
$man.Add('MD5                               SIZE        PATH')
foreach ($i in $items) {
  $rel = $i.FullName.Substring($dest.Length + 1)
  $h = (Get-FileHash -Path $i.FullName -Algorithm MD5).Hash.ToLower()
  $man.Add(('{0}  {1,10}  {2}' -f $h, $i.Length, $rel))
}
$man | Set-Content -Path (Join-Path $dest 'MANIFEST.txt') -Encoding UTF8

# ---------------------------------------------------------------- report
Write-Host ''
Write-Host '--- package contents ---'
foreach ($i in $items) {
  $rel = $i.FullName.Substring($dest.Length + 1)
  Write-Host ('  {0,12:N0}  {1}' -f $i.Length, $rel)
}
Write-Host ('  ' + ('-' * 40))
Write-Host ('  {0,12:N0}  TOTAL  ({1:N1} MB)' -f $total, ($total / 1MB))
Write-Host ''
Write-Host ('files : ' + $items.Count)
Write-Host ('output: ' + $dest)
Write-Host ''

if ($missing.Count -gt 0) {
  Write-Host '!! MISSING SOURCE FILES - the package is INCOMPLETE:'
  foreach ($m in $missing) { Write-Host ('   ' + $m) }
  Write-Host ''
  exit 1
}
if ($crlfBad.Count -gt 0) {
  Write-Host '!! these .bat files are not CRLF and will misbehave:'
  foreach ($m in $crlfBad) { Write-Host ('   ' + $m) }
  Write-Host ''
  exit 1
}

Write-Host 'OK - copy the folder below to the USB stick:'
Write-Host ('   ' + $dest)
Write-Host ''
exit 0
