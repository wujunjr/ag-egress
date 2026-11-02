# setup.ps1 - first-time configuration for ag-egress
#
# Generates the three runtime configs that contain your server credentials:
#
#   mihomo\config-proxy.yaml                  <- mihomo\config.example.yaml
#   hy2\client.yaml                           <- hy2\client.example.yaml
#   oci-egress\sing-box-server-config.json    <- oci-egress\...example.json
#
# The generated files are listed in .gitignore. NEVER commit them.
#
# WHY THIS SCRIPT EXISTS
#   A public repo cannot ship your tunnel key. Clone once, run this, done.
#
# ASCII-only on purpose: PowerShell 5.1 decodes a BOM-less UTF-8 .ps1 as GBK
# and can swallow a quote that follows a CJK character, breaking the script.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
#   powershell ... -File setup.ps1 -ServerHost 203.0.113.10 -SsPassword '...' -Hy2Password '...'
#   ... -Force        overwrite existing configs
#
param(
    [string]$ServerHost,
    [string]$SsPassword,
    [string]$Hy2Password,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$Targets = @(
    @{ Real = 'mihomo\config-proxy.yaml';                  Example = 'mihomo\config.example.yaml' },
    @{ Real = 'hy2\client.yaml';                           Example = 'hy2\client.example.yaml' },
    @{ Real = 'oci-egress\sing-box-server-config.json';    Example = 'oci-egress\sing-box-server-config.example.json' }
)

function Write-Step($s) { Write-Host ('  ' + $s) }

function Read-SecretText($prompt) {
    $sec = Read-Host -Prompt $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Write-Host ''
Write-Host '=== ag-egress setup ==='
Write-Host ('project root : ' + $Root)
Write-Host ''

# --------------------------------------------------------------- sanity
foreach ($t in $Targets) {
    if (-not (Test-Path (Join-Path $Root $t.Example))) {
        Write-Host ('[ERROR] template missing: ' + $t.Example)
        Write-Host '        The repo is incomplete. Re-clone it.'
        exit 1
    }
}

$existing = @()
foreach ($t in $Targets) {
    if (Test-Path (Join-Path $Root $t.Real)) { $existing += $t.Real }
}
if ($existing.Count -gt 0 -and -not $Force) {
    Write-Host 'These configs already exist:'
    foreach ($e in $existing) { Write-Step $e }
    Write-Host ''
    Write-Host 'Nothing to do. Re-run with -Force to overwrite them.'
    exit 0
}

# --------------------------------------------------------------- input
if (-not $ServerHost) {
    $ServerHost = Read-Host -Prompt 'VPS host or IP (e.g. 203.0.113.10)'
}
$ServerHost = $ServerHost.Trim()
if ($ServerHost -match '^[a-zA-Z]+://') {
    Write-Host '[ERROR] give a bare host or IP, without http:// or https://'
    exit 1
}
# tolerate "IP:port" pasted from a browser
if ($ServerHost -match '^(.+):\d+$') { $ServerHost = $Matches[1].Trim() }
if ($ServerHost -eq '' -or $ServerHost -match '\s') {
    Write-Host '[ERROR] host must be non-empty and contain no spaces'
    exit 1
}

if (-not $SsPassword) {
    $SsPassword = Read-SecretText 'shadowsocks-2022 password (base64, 44 chars, input hidden)'
}
$SsPassword = $SsPassword.Trim()
if ($SsPassword -eq '') {
    Write-Host '[ERROR] shadowsocks password is empty'
    exit 1
}
if ($SsPassword.Length -ne 44) {
    Write-Host ('[WARN] shadowsocks-2022 key is usually 44 chars (got ' + $SsPassword.Length + ').')
    Write-Host '       Continuing anyway. If the tunnel fails, check this value first.'
}

if (-not $Hy2Password) {
    $Hy2Password = Read-SecretText 'hysteria2 password (input hidden)'
}
$Hy2Password = $Hy2Password.Trim()
if ($Hy2Password -eq '') {
    Write-Host '[ERROR] hysteria2 password is empty'
    exit 1
}

# --------------------------------------------------------------- render
Write-Host ''
Write-Host '--- writing configs ---'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$map = @{
    '__SERVER_HOST__'     = $ServerHost
    '__SS2022_PASSWORD__' = $SsPassword
    '__HY2_PASSWORD__'    = $Hy2Password
}

foreach ($t in $Targets) {
    $text = [System.IO.File]::ReadAllText((Join-Path $Root $t.Example),
                                          [System.Text.Encoding]::UTF8)
    foreach ($k in $map.Keys) { $text = $text.Replace($k, $map[$k]) }

    $left = @()
    foreach ($k in $map.Keys) { if ($text.Contains($k)) { $left += $k } }
    if ($left.Count -gt 0) {
        Write-Host ('[ERROR] placeholder not replaced in ' + $t.Example + ': ' + ($left -join ', '))
        exit 1
    }

    [System.IO.File]::WriteAllText((Join-Path $Root $t.Real), $text, $utf8NoBom)
    Write-Step ($t.Real + '  (' + $text.Length + ' bytes)')
}

Write-Host ''
Write-Host '--- next ---'
Write-Host '  1. Make sure the VPS side is already running (hysteria2 on UDP 8443,'
Write-Host '     sing-box / shadowsocks-2022 on TCP 443). See oci-egress\REBUILD-CHECKLIST.md'
Write-Host '     if you need to build it from scratch.'
Write-Host '  2. Double-click start-ag-proxy.bat'
Write-Host '  3. In the self-check, [E] tunnel egress country must NOT be CN.'
Write-Host '  4. Launch Antigravity and send a prompt. That is the only real test.'
Write-Host ''
Write-Host 'Done.'
