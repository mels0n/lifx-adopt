#!/bin/bash
# lifx-adopt.sh -- adopt factory-reset LIFX bulbs onto your WiFi network.
#
# A bulb that has been hardware-reset (5 power cycles) broadcasts its own open
# setup AP (named like "LIFX Mini D 1a2b3c") and listens on 172.16.0.1:56700.
# This script finds such an AP, joins it with an otherwise idle WiFi radio,
# hands the bulb your network's credentials, and drops the radio back down.
#
# Invoked by lifx-adopt.timer every few minutes; safe to run by hand at any time.
#
# The radio is only brought up for the duration of a run and is ALWAYS put back
# down on exit, including on error or SIGTERM.
#
# Credentials come from a root-only file (default /etc/lifx-adopt/lifx-adopt.env)
# that defines LIFX_SSID and LIFX_PSK. They never appear in this script.
#
# Environment overrides (all optional):
#   CONFIG_FILE      credential file (default /etc/lifx-adopt/lifx-adopt.env)
#   WIFI_IFACE       wireless interface to use (default: first one found)
#   DRY_RUN=1        scan and report, touch nothing
#   RSSI_FLOOR=-75   ignore setup APs weaker than this (dBm)
#   MAX_PER_RUN=3    stop after this many bulbs in one pass
#   COOLDOWN_FAILS=3 consecutive failures before a bulb is suppressed
#   COOLDOWN_SECS    how long to suppress it (default 86400)
#
# Exit status is 0 whenever the run completed, including "nothing found" and
# "a bulb failed". A non-zero exit means the run itself could not proceed.

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/lifx-adopt/lifx-adopt.env}"
STATE_DIR="${STATE_DIR:-/var/lib/lifx-adopt}"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER="${PROVISIONER:-$SELF_DIR/../src/lifx_set_ssid.py}"

WIFI_IFACE="${WIFI_IFACE:-}"
DRY_RUN="${DRY_RUN:-0}"
RSSI_FLOOR="${RSSI_FLOOR:--75}"
MAX_PER_RUN="${MAX_PER_RUN:-3}"
COOLDOWN_FAILS="${COOLDOWN_FAILS:-3}"
COOLDOWN_SECS="${COOLDOWN_SECS:-86400}"
ASSOC_TIMEOUT="${ASSOC_TIMEOUT:-30}"
SCAN_TRIGGER_TIMEOUT="${SCAN_TRIGGER_TIMEOUT:-15}"
SCAN_DUMP_TIMEOUT="${SCAN_DUMP_TIMEOUT:-20}"
SCAN_SETTLE="${SCAN_SETTLE:-8}"
RADIO_WARMUP="${RADIO_WARMUP:-4}"
SETTLE_SECS="${SETTLE_SECS:-5}"
BULB_WAIT="${BULB_WAIT:-25}"
# These two are defined by LIFX's setup AP, not by you.
BULB_GW=172.16.0.1
SELF_ADDR=172.16.0.2/24

IFACE=""
adopted=0
failed=0

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

find_iface() {
    local wdir
    if [[ -n "$WIFI_IFACE" ]]; then
        printf '%s\n' "$WIFI_IFACE"
        return 0
    fi
    for wdir in /sys/class/net/*/wireless; do
        [[ -e "$wdir" ]] || continue
        basename "$(dirname "$wdir")"
        return 0
    done
    return 1
}

# --radio-down: unconditional radio teardown, used as the unit's ExecStopPost so
# a killed or crashed run can never leave the interface associated. Deliberately
# runs before any preflight, because it must work even when the credential file
# is gone.
if [[ "${1:-}" == "--radio-down" ]]; then
    i="$(find_iface)" || exit 0
    ip addr flush dev "$i" 2>/dev/null
    iw dev "$i" disconnect 2>/dev/null
    ip link set "$i" down 2>/dev/null
    exit 0
fi

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$IFACE" ]]; then
        ip addr flush dev "$IFACE" 2>/dev/null
        iw dev "$IFACE" disconnect 2>/dev/null
        ip link set "$IFACE" down 2>/dev/null
        log "radio $IFACE returned to DOWN"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# --- preflight ---------------------------------------------------------------

[[ $EUID -eq 0 ]] || { err "must run as root"; exit 1; }

for tool in iw ip python3 flock timeout; do
    command -v "$tool" >/dev/null || { err "missing required tool: $tool"; exit 1; }
done

[[ -r "$PROVISIONER" ]] || { err "provisioner not readable: $PROVISIONER"; exit 1; }

if [[ ! -r "$CONFIG_FILE" ]]; then
    err "credential file missing: $CONFIG_FILE"
    exit 1
fi
# The file holds a WiFi passphrase. Refuse to use it if anyone but root can read it.
mode="$(stat -c %a "$CONFIG_FILE")"
if [[ "$mode" != "600" && "$mode" != "400" ]]; then
    err "$CONFIG_FILE has mode $mode; it must be 0600 or 0400 and owned by root"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${LIFX_SSID:?LIFX_SSID not set in $CONFIG_FILE}"
: "${LIFX_PSK:?LIFX_PSK not set in $CONFIG_FILE}"
# Handed to the provisioner through its environment, never through argv, so the
# passphrase does not show up in `ps` or /proc/<pid>/cmdline.
export LIFX_PSK
[[ -n "${LIFX_SECURITY:-}" ]] && export LIFX_SECURITY

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

# Single instance per node.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another run holds the lock; exiting"; exit 0; }

IFACE="$(find_iface)" || { err "no wireless interface on this host"; exit 1; }
log "interface=$IFACE target_ssid=$LIFX_SSID dry_run=$DRY_RUN"

# --- state helpers -----------------------------------------------------------
# State file lines: "<bssid> <consecutive failures> <epoch of last attempt>"

fails_for() {  # mac -> consecutive failure count
    awk -v m="$1" '$1==m {print $2; found=1} END{if(!found) print 0}' "$STATE_FILE" | tail -1
}

last_attempt_for() {
    awk -v m="$1" '$1==m {print $3; found=1} END{if(!found) print 0}' "$STATE_FILE" | tail -1
}

set_state() {  # mac fails ts
    local tmp; tmp="$(mktemp)"
    awk -v m="$1" '$1!=m' "$STATE_FILE" > "$tmp" 2>/dev/null
    printf '%s %s %s\n' "$1" "$2" "$3" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

in_cooldown() {  # mac -> 0 if suppressed
    local mac="$1" f last now
    f="$(fails_for "$mac")"
    [[ "$f" -ge "$COOLDOWN_FAILS" ]] || return 1
    last="$(last_attempt_for "$mac")"
    now="$(date +%s)"
    (( now - last < COOLDOWN_SECS ))
}

# --- scanning ----------------------------------------------------------------

# Emits TAB-separated "BSSID<TAB>SIGNAL<TAB>SSID".
#
# Tab-separated because real LIFX setup SSIDs contain spaces ("LIFX Mini D
# 1a2b3c", not "LIFX_1a2b3c"). Splitting on whitespace truncates the SSID to
# "LIFX" and every join attempt then fails.
#
# Only open networks are emitted. A setup AP is always unencrypted; requiring
# that stops us from ever trying to join a real network whose name happens to
# start with LIFX.
scan_lifx() {
    # `iw scan` is trigger + wait + dump in one call, and the wait half can
    # block indefinitely on some hardware (observed hanging past 45s on
    # iwlwifi, surviving SIGTERM, and holding the lock through inherited fds).
    # Triggering asynchronously and then reading the cached BSS table means
    # neither half can stall the run.
    timeout -k 5 "$SCAN_TRIGGER_TIMEOUT" iw dev "$IFACE" scan trigger >/dev/null 2>&1
    sleep "$SCAN_SETTLE"
    timeout -k 5 "$SCAN_DUMP_TIMEOUT" iw dev "$IFACE" scan dump 2>/dev/null | awk '
        $1=="BSS" {
            bss=$2; sub(/\(on.*/, "", bss); sig=""; priv=0; ssid=""; next
        }
        $1=="signal:"     { sig=int($2); next }
        $1=="capability:" { if ($0 ~ /Privacy/) priv=1; next }
        /^[[:space:]]*(RSN|WPA):/ { priv=1; next }
        /^[[:space:]]*SSID: / {
            ssid=substr($0, index($0, "SSID: ") + 6)
            if (ssid ~ /^LIFX/ && priv==0) printf "%s\t%s\t%s\n", bss, sig, ssid
            next
        }
    '
}

still_beaconing() {  # ssid -> 0 if the setup AP is still up
    scan_lifx | awk -F'\t' -v s="$1" '$3==s {found=1} END{exit !found}'
}

# Association completing is not the same as the bulb being reachable. Observed
# failure: `iw connect` reports success, the address is assigned, and the very
# next packet gets EHOSTUNREACH because ARP has not resolved yet. Poll the port
# we actually need, using bash's own /dev/tcp so there is no ping/arping
# dependency.
wait_for_bulb() {
    local deadline=$(( SECONDS + BULB_WAIT ))
    while (( SECONDS < deadline )); do
        if timeout 2 bash -c "exec 3<>/dev/tcp/$BULB_GW/56700" 2>/dev/null; then
            log "bulb reachable at $BULB_GW:56700"
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- main --------------------------------------------------------------------

# A cold radio loads firmware on first up; scanning too early can block for a
# long time. Every scan is also timeout-bounded so a wedged driver can never
# hold the unit open.
ip link set "$IFACE" up || { err "could not bring $IFACE up"; exit 1; }
sleep "$RADIO_WARMUP"

mapfile -t candidates < <(scan_lifx | sort -t$'\t' -k2 -nr)

if [[ ${#candidates[@]} -eq 0 ]]; then
    log "no LIFX setup APs in range"
    exit 0
fi

log "found ${#candidates[@]} LIFX setup AP(s)"

processed=0
for entry in "${candidates[@]}"; do
    IFS=$'\t' read -r mac signal ssid <<<"$entry"

    if (( processed >= MAX_PER_RUN )); then
        log "reached MAX_PER_RUN=$MAX_PER_RUN, leaving the rest for the next pass"
        break
    fi

    if (( signal < RSSI_FLOOR )); then
        log "skip $ssid ($mac): ${signal}dBm below floor ${RSSI_FLOOR}dBm"
        continue
    fi

    if in_cooldown "$mac"; then
        log "skip $ssid ($mac): in cooldown after $(fails_for "$mac") failures"
        continue
    fi

    log "--- $ssid ($mac) ${signal}dBm ---"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: would join $ssid and provision it onto $LIFX_SSID"
        processed=$((processed + 1))
        continue
    fi

    processed=$((processed + 1))
    ok=0

    if ! timeout "$ASSOC_TIMEOUT" iw dev "$IFACE" connect -w "$ssid" 2>&1; then
        err "association with $ssid failed"
    elif ! iw dev "$IFACE" link 2>/dev/null | grep -q "Connected to"; then
        err "associated but link not established to $ssid"
    else
        log "associated with $ssid"
        ip addr flush dev "$IFACE" 2>/dev/null
        if ! ip addr add "$SELF_ADDR" dev "$IFACE" 2>&1; then
            err "could not assign $SELF_ADDR on $IFACE"
        elif ! wait_for_bulb; then
            err "bulb unreachable at $BULB_GW:56700 after ${BULB_WAIT}s"
        else
            python3 "$PROVISIONER" "$LIFX_SSID" "$BULB_GW"
            prc=$?
            if (( prc == 0 )); then
                ok=1
            else
                err "provisioner exited $prc for $ssid"
            fi
        fi
    fi

    # Always release before verifying.
    ip addr flush dev "$IFACE" 2>/dev/null
    iw dev "$IFACE" disconnect 2>/dev/null
    sleep "$SETTLE_SECS"

    # Success is decided by the bulb's own StateAccessPoint reply, which echoes
    # back the SSID it stored. Absence of the setup AP is NOT used as the test:
    # `iw scan dump` reads a cached BSS table that keeps listing an AP for tens
    # of seconds after it stops beaconing, and the bulb needs time to reboot
    # regardless. Treating absence as authoritative marks a confirmed adoption
    # as failed.
    if (( ok == 1 )); then
        log "ADOPTED $ssid ($mac): bulb confirmed ssid $LIFX_SSID"
        set_state "$mac" 0 "$(date +%s)"
        adopted=$((adopted + 1))
        if still_beaconing "$ssid"; then
            log "note: $ssid still present in the scan cache; expected to clear shortly"
        fi
    else
        n=$(( $(fails_for "$mac") + 1 ))
        err "FAILED $ssid ($mac): attempt $n"
        set_state "$mac" "$n" "$(date +%s)"
        failed=$((failed + 1))
        if (( n >= COOLDOWN_FAILS )); then
            err "$ssid ($mac) suppressed for ${COOLDOWN_SECS}s after $n failures"
        fi
    fi
done

log "run complete: adopted=$adopted failed=$failed seen=${#candidates[@]}"
exit 0
