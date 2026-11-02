#!/usr/bin/env bash
# ============================================================
#  hy2-ab-test.sh -- BBR vs Brutal, same path, same file, back to back
#
#  Question it answers: is ~20 Mbps the LINK's ceiling, or is BBR
#  simply not filling it?
#
#  STATUS 2026-09-20: the Brutal arm does NOT run. A client config with a
#  `bandwidth:` block fails with "authentication error, HTTP status code:
#  404" -- reproducible in a clean environment, cause unknown (password,
#  YAML validity and unit syntax were all ruled out). See
#  多端接入计划-OCI出口.md section 9.5. The script is kept for when that
#  is solved; today only the BBR arm is usable.
#
#  Also note: this measures the RAW upstream (hysteria's own :7898), not
#  mihomo's :7897. For the production chain use:
#     curl.exe -x http://127.0.0.1:7897 ...
#
#  Run from Git Bash:  bash _tools/hy2-ab-test.sh
#
#  ASCII-only on purpose.
# ============================================================
set -u

TOOLS_WIN="D:/Windsurf_Workspace/ag-egress/_tools"
TOOLS_MSYS="/d/Windsurf_Workspace/ag-egress/_tools"
HYST_MSYS="/d/Windsurf_Workspace/ag-egress/hy2/hysteria.exe"
HYST_WIN="D:/Windsurf_Workspace/ag-egress/hy2/hysteria.exe"

#  Do NOT use speed.cloudflare.com here. Measured 2026-09-20: it rate-limits.
#  bytes=15000000 -> HTTP 403 even with no proxy; bytes=20000000 -> 200 but
#  truncated to ~10 MB. Use a plain file host instead.
URL="https://proof.ovh.net/files/100Mb.dat"

#  IMPORTANT: in Git Bash, taskkill needs a SINGLE slash (/F), not //F.
#  "//F" is passed through literally and taskkill rejects it with
#  "invalid argument" -- and if stderr is redirected you never notice,
#  so the old process survives and silently poisons the next measurement.
#  That mistake invalidated one round of testing on 2026-09-20.
kill_hysteria() {
    taskkill /F /IM hysteria.exe >/dev/null 2>&1
    sleep 3
}

run_one() {
    local cfg="$1" label="$2"
    echo "=============================================="
    echo "  $label   ($cfg)"
    echo "=============================================="
    kill_hysteria
    "$HYST_MSYS" client -c "$TOOLS_WIN/$cfg" >"$TOOLS_MSYS/ab-$label.log" 2>&1 &
    sleep 8

    local fatal
    fatal=$(grep -E "FATAL" "$TOOLS_MSYS/ab-$label.log" | head -1)
    if [ -n "$fatal" ]; then
        echo "  !! client failed to start:"
        echo "     $fatal"
        echo
        return
    fi

    local res code size speed
    res=$(curl.exe -s -x http://127.0.0.1:7898 -o NUL \
            -w "%{http_code} %{size_download} %{speed_download}" \
            --max-time 120 "$URL")
    code=$(echo "$res" | awk '{print $1}')
    size=$(echo "$res" | awk '{print $2}')
    speed=$(echo "$res" | awk '{print $3}')

    if [ "${size:-0}" -lt 1000000 ]; then
        echo "  !! http=$code size=$size -- source returned a short body."
        echo "     Do NOT read this as 'speed 0'; try another host."
    else
        printf "  http=%s  size=%s  speed=%s B/s  =  %.1f Mbps\n" \
               "$code" "$size" "$speed" "$(awk -v s="$speed" 'BEGIN{print s*8/1000000}')"
    fi
    echo
}

echo
echo "  A/B: BBR vs Brutal -- same server, same path, same 100 MB file"
echo

run_one "hy2-bbr.yaml"    "bbr"
run_one "hy2-brutal.yaml" "brutal25"

kill_hysteria
echo "  done. compare the two Mbps numbers above."
echo
