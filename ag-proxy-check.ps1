# ag-proxy-check.ps1 - self-check for the OCI (self-hosted VPS) egress setup
#
# ============================================================
#  WHAT THIS SCRIPT CAN AND CANNOT PROVE   (read this)
# ============================================================
#  CAN prove:
#    * the link is up: SOCKS5 -> mihomo -> VPS:443 -> Google answers
#    * the egress IP is not judged CN      <-- this is the meaningful pre-check
#
#  CANNOT prove:
#    * that Google ACCEPTS the region.
#      A token-less request NEVER triggers the region check, so HTTP 401 only
#      means "the pipe works". It is NOT a green light.
#      THE ONLY REAL VERDICT is Antigravity making a CREDENTIALED call.
#
# ============================================================
#  WARP MUST BE DISCONNECTED   (opposite of the old CF-Worker setup)
# ============================================================
#  Measured 2026-09-11 (Shanghai):
#    WARP connected    -> TCP to VPS:443 times out 8/8  (while VPS:22 works fine)
#    WARP disconnected -> "Connection refused", latency 450ms -> 206ms
#  So WARP now BREAKS the tunnel instead of carrying it. It is redundant:
#  its only job used to be carrying traffic to the (now abandoned) CF Worker.
#
#  IMPORTANT: the service "CloudflareWARP" keeps RUNNING even while WARP is
#  DISCONNECTED. Get-Service therefore reports a false positive. Ask warp-cli.
#
# ============================================================
#  WHY curl.exe AND NOT Invoke-WebRequest
# ============================================================
#  Invoke-WebRequest resolves DNS LOCALLY and prefers IPv6, then asks the proxy
#  to CONNECT to an IPv6 literal. mihomo runs with ipv6:false and fails that
#  request -> a false negative.
#  The real traffic path is: version.dll (dns_mode=proxy) sends the HOSTNAME
#  over SOCKS5 and lets mihomo resolve it (ipv6:false => IPv4).
#  curl.exe -x socks5h:// is exactly that path, so we test with it.
#  ("curl" is a built-in alias for Invoke-WebRequest in PowerShell - use curl.exe)
#
# ============================================================
#  ASCII-only
# ============================================================
#  PowerShell 5.1 decodes a BOM-less UTF-8 .ps1 as GBK and can swallow a quote
#  following a CJK char, breaking the whole script.

param([int]$Port = 7897)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$lines = New-Object System.Collections.ArrayList
$pass  = $true

function Emit($s) { [void]$lines.Add($s); Write-Host $s }

# ---------------------------------------------------------------
# [A] WARP state -- DISCONNECTED is the good case now
#     NOTE: test "Disconnected" BEFORE "Connected": the word
#     "Disconnected" contains the substring "Connected".
# ---------------------------------------------------------------
$warpCli = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
$warpState = 'not-found'
if (Test-Path $warpCli) {
    $st = (& $warpCli status 2>$null) -join ' '
    if     ($st -match 'Disconnected') { $warpState = 'disconnected' }
    elseif ($st -match 'Connected')    { $warpState = 'connected' }
    else                               { $warpState = 'unknown' }
}
switch ($warpState) {
    'disconnected' { Emit "    [A] Cloudflare WARP        : Disconnected   OK (must stay off)" }
    'connected'    {
        Emit "    [A] Cloudflare WARP        : CONNECTED  -- WILL BREAK THE TUNNEL"
        Emit "                               Disconnect it (tray icon), or add the VPS IP"
        Emit "                               to Settings > Advanced > Split Tunnels (Exclude)."
        $pass = $false
    }
    'unknown'      { Emit "    [A] Cloudflare WARP        : state unknown - check manually" }
    default        { Emit "    [A] Cloudflare WARP        : not installed (fine)" }
}

# ---------------------------------------------------------------
# [B] mihomo port
# ---------------------------------------------------------------
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Emit "    [B] mihomo 127.0.0.1:$Port      : listening"
} else {
    Emit "    [B] mihomo 127.0.0.1:$Port      : NOT listening - run start-ag-proxy.bat"
    $pass = $false
}

# ---------------------------------------------------------------
# [B2] hysteria2 upstream (added 2026-09-20)
#
#  AG-TUNNEL is now a FALLBACK group: ag-oci-hy2 first, ag-oci second.
#  So a dead hysteria does NOT break the chain -- mihomo silently drops to
#  the ss node. That is deliberate, but it is also invisible: you would be
#  on a path measured ~100-180x slower and never notice from Antigravity
#  alone. Hence this explicit line.
#
#  NOT a hard failure on purpose: the link is still usable.
# ---------------------------------------------------------------
$sockPort = 7899
if (Get-NetTCPConnection -LocalPort $sockPort -State Listen -ErrorAction SilentlyContinue) {
    Emit "    [B2] hysteria2 upstream :$sockPort : listening  (FAST path active)"
} else {
    Emit "    [B2] hysteria2 upstream :$sockPort : NOT listening"
    Emit "                                 -> AG-TUNNEL fell back to ag-oci (ss, SLOW)"
    Emit "                                 -> re-run start-ag-proxy.bat;"
    Emit "                                    log: hy2\hysteria-run.log"
}

# ---------------------------------------------------------------
# [C] DLL hook
#     An Antigravity update wipes resources\bin and silently removes the hook.
# ---------------------------------------------------------------
$dll = 'C:\Users\john\AppData\Local\Programs\antigravity\resources\bin\version.dll'
if (Test-Path $dll) { Emit "    [C] version.dll hook          : deployed" }
else { Emit "    [C] version.dll hook          : MISSING - language_server bypasses proxy"; $pass = $false }

# ---------------------------------------------------------------
# [D] Cloud Code reachability. Expected 401. This is a LINK test only.
#     Body is captured so a failure can be read instead of guessed at.
# ---------------------------------------------------------------
function Probe($url) {
    $a = @('-s', '--max-time', '30', '-x', "socks5h://127.0.0.1:$Port",
           '-X', 'POST', '-H', 'content-type: application/json',
           '-d', "@$Root\mihomo\probe-body.json",
           '-w', '|||%{http_code}', $url)
    $out = (& curl.exe @a 2>$null) -join "`n"
    $code = -1
    $body = ''
    $i = $out.LastIndexOf('|||')
    if ($i -ge 0) {
        $t = $out.Substring($i + 3).Trim()
        if ($t -match '^\d+$') { $code = [int]$t }
        $body = $out.Substring(0, $i)
    }
    return @{ Code = $code; Body = $body }
}

Emit "    [D] Cloud Code reachability  (LINK ONLY - not a region verdict) --"
foreach ($h in @('cloudcode-pa.googleapis.com', 'daily-cloudcode-pa.googleapis.com')) {
    $r = Probe "https://$h/v1internal:streamGenerateContent"
    if ($r.Code -eq 401) {
        Emit "        $h -> HTTP 401  link OK"
    } elseif ($r.Code -eq 400) {
        # With NO token the region check is not even reached, so a 400 here is
        # almost certainly a generic bad request (our body is a dummy), NOT
        # "location not supported". Print the body so it is not guessed at.
        $b = ($r.Body -replace '\s+', ' ').Trim()
        if ($b.Length -gt 240) { $b = $b.Substring(0, 240) + '...' }
        Emit "        $h -> HTTP 400  (not a region verdict - body: $b)"
    } elseif ($r.Code -eq -1) {
        Emit "        $h -> connect FAILED (proxy down / egress unreachable)"
        $pass = $false
    } else {
        Emit "        $h -> HTTP $($r.Code)"
    }
}

# ---------------------------------------------------------------
# [E] Tunnel egress -- THE MEANINGFUL PRE-CHECK
#     Use ipinfo.io/json. Do NOT use cloudflare.com/cdn-cgi/trace here:
#     its "loc=" field is the Cloudflare colo country, NOT the client country,
#     so reading "loc=" as the egress country is simply wrong.
# ---------------------------------------------------------------
$ego = (& curl.exe -s --max-time 25 -x "socks5h://127.0.0.1:$Port" https://ipinfo.io/json 2>$null) -join "`n"
if ($ego) {
    try {
        $j = $ego | ConvertFrom-Json
        Emit "    [E] tunnel egress IP       : $($j.ip)"
        Emit "        location               : $($j.city) / $($j.region) / $($j.country)"
        Emit "        org                    : $($j.org)"
        if ($j.country -eq 'CN') {
            Emit "        >>> BAD: egress is judged CN - Google WILL reject this"
            $pass = $false
        } else {
            Emit "        >>> OK: egress is NOT CN"
        }
    } catch {
        Emit "    [E] tunnel egress IP       : could not parse response"
        $pass = $false
    }
} else {
    Emit "    [E] tunnel egress IP       : FAILED - no response through the proxy"
    $pass = $false
}

# ---------------------------------------------------------------
# [F] Direct egress (no proxy) for comparison. Should be the local CN IP.
#     Uses ipinfo.io/json (UTF-8). Do NOT use myip.ipip.net here: it returns
#     GBK bytes, which garble when this script reads them as text.
# ---------------------------------------------------------------
$dir = (& curl.exe -s --max-time 15 https://ipinfo.io/json 2>$null) -join "`n"
if ($dir) {
    try {
        $d = $dir | ConvertFrom-Json
        Emit "    [F] direct egress (no proxy): $($d.ip)  $($d.city) / $($d.country)"
    } catch {
        Emit "    [F] direct egress (no proxy): unparseable response"
    }
} else {
    Emit "    [F] direct egress (no proxy): skipped (no response)"
}

Emit ""
if ($pass) { Emit "RESULT=PASS" } else { Emit "RESULT=FAIL" }
Emit ""
Emit "  PASS above means: link is up AND egress is not CN."
Emit "  It does NOT prove Google accepts the region."
Emit "  THE ONLY REAL VERDICT: launch Antigravity and send a prompt."
Emit "  (401 is not a green light - a token-less request never triggers"
Emit "   the region check.)"

Set-Content -Path (Join-Path $Root 'ag-proxy-check.log') -Value $lines -Encoding UTF8
