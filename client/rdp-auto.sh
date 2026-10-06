#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rdp-auto.sh - fully automated connect from Linux or macOS.
#
#   * finds a session that is already live, or starts the workflow for you
#   * waits for the desktop, then opens xfreerdp already logged in
#   * --watch keeps following the endpoint and reconnects when a free tunnel
#     rotates its address
#   * --restart also starts a new machine when the run hits GitHub's 6h limit
#
# Needs: gh (authenticated once with "gh auth login")
#        xfreerdp (sudo apt install freerdp2-x11) or remmina
#
# Usage:
#   ./rdp-auto.sh                      # connect now
#   ./rdp-auto.sh --watch              # connect and stay connected
#   ./rdp-auto.sh --new --restart      # fresh machine, auto restart later
#   ./rdp-auto.sh --repo owner/name --duration 330
# ---------------------------------------------------------------------------
set -uo pipefail

REPO=""
WORKFLOW="main.yml"
REF=""
TUNNEL="auto"
DURATION=330
TIMEOUT_MIN=15
POLL=20
NEW=0
WATCH=0
RESTART=0
NOLAUNCH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --workflow) WORKFLOW="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        --tunnel) TUNNEL="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --timeout) TIMEOUT_MIN="$2"; shift 2 ;;
        --poll) POLL="$2"; shift 2 ;;
        --new) NEW=1; shift ;;
        --watch) WATCH=1; shift ;;
        --restart) RESTART=1; WATCH=1; shift ;;
        --no-launch) NOLAUNCH=1; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

say()  { echo "[rdp] $*"; }
ok()   { printf '\033[32m[rdp] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[rdp] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m[rdp] %s\033[0m\n' "$*" >&2; }

command -v gh >/dev/null 2>&1 || { bad "The GitHub CLI (gh) is missing. Install it from https://cli.github.com and run 'gh auth login'."; exit 1; }
gh auth status >/dev/null 2>&1 || { bad "Not logged in. Run 'gh auth login' once, then try again."; exit 1; }

if [ -z "$REPO" ]; then
    remote="$(git remote get-url origin 2>/dev/null || true)"
    REPO="$(printf '%s' "$remote" | sed -n 's#.*github\.com[:/]\(.*\)#\1#p' | sed 's#\.git$##')"
fi
[ -n "$REPO" ] || { bad "Could not work out the repository. Pass --repo owner/name."; exit 1; }

if [ -z "$REF" ]; then
    REF="$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rdp-auto"
mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/session.env"

echo
echo "=============================================================="
echo "  Auto connecting to your RDP session"
echo "  repository: $REPO   ref: $REF"
echo "=============================================================="
echo

reachable() {                      # reachable host:port -> 0
    [ -n "${1:-}" ] || return 1
    local h="${1%%:*}" p="${1##*:}"
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/$h/$p" 2>/dev/null
}

save_cache() {                     # save_cache ADDRESS USER PASS PROVIDER RUNID
    umask 077
    {
        echo "ADDRESS='$1'"
        echo "USERNAME='$2'"
        echo "PASSWORD='$3'"
        echo "PROVIDER='$4'"
        echo "RUN_ID='$5'"
    } > "$CACHE"
}

load_cache() { [ -f "$CACHE" ] && . "$CACHE"; return 0; }

latest_run() {                     # prints "id status"
    gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 10 \
        --json databaseId,status,conclusion 2>/dev/null |
        tr '}' '\n' | grep -v '"status":"completed"' | sed -n 's/.*"databaseId":\([0-9]*\).*/\1/p' | head -1
}

details_for() {                    # details_for RUN_ID -> writes details file, 0 on success
    local run="$1" tmp="$STATE_DIR/artifact" file
    rm -rf "$tmp"
    if gh run download "$run" --repo "$REPO" -n rdp-connection-info -D "$tmp" >/dev/null 2>&1; then
        file="$(find "$tmp" -name rdp-info.txt 2>/dev/null | head -1)"
        if [ -n "$file" ]; then
            HOST="$(sed -n 's/^HOST=//p' "$file" | head -1)"
            PORT="$(sed -n 's/^PORT=//p' "$file" | head -1)"
            USERNAME="$(sed -n 's/^USERNAME=//p' "$file" | head -1)"
            PASSWORD="$(sed -n 's/^PASSWORD=//p' "$file" | head -1)"
            PROVIDER="$(sed -n 's/^PROVIDER=//p' "$file" | head -1)"
            if [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$USERNAME" ]; then
                ADDRESS="$HOST:$PORT"
                return 0
            fi
        fi
    fi
    # fall back to the log
    local log
    log="$(gh run view "$run" --repo "$REPO" --log 2>/dev/null)"
    [ -n "$log" ] || return 1
    ADDRESS="$(printf '%s\n' "$log" | sed -n 's/.*\[rdp-info\] address=//p' | tail -1 | tr -d '\r')"
    USERNAME="$(printf '%s\n' "$log" | sed -n 's/.*\[rdp-info\] username=//p' | tail -1 | tr -d '\r')"
    PASSWORD="$(printf '%s\n' "$log" | sed -n 's/.*\[rdp-info\] password=//p' | tail -1 | tr -d '\r')"
    PROVIDER="$(printf '%s\n' "$log" | sed -n 's/.*\[rdp-info\] provider=//p' | tail -1 | tr -d '\r')"
    [ -n "$ADDRESS" ] && [ -n "$USERNAME" ]
}

start_run() {
    say "Starting a fresh workflow run (tunnel=$TUNNEL, duration=${DURATION}m) ..."
    if ! out="$(gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF" \
            -f "tunnel=$TUNNEL" -f "duration_minutes=$DURATION" -f save_data=on 2>&1)"; then
        bad "Could not start the workflow: $out"
        warn "If Actions is disabled for the repository, nothing can run:"
        echo "    https://github.com/$REPO/settings/actions"
        return 1
    fi
    for _ in $(seq 1 30); do
        sleep 4
        local id
        id="$(latest_run)"
        [ -n "$id" ] && { echo "$id"; return 0; }
    done
    return 1
}

wait_for_details() {               # wait_for_details RUN_ID
    local run="$1" waited=0 limit=$((TIMEOUT_MIN * 60))
    while [ "$waited" -lt "$limit" ]; do
        if details_for "$run"; then return 0; fi
        sleep 15; waited=$((waited + 15))
        if [ $((waited % 60)) -eq 0 ]; then say "still waiting ... (${waited}s)"; fi
    done
    return 1
}

open_client() {                    # open_client ADDRESS USER PASS
    [ "$NOLAUNCH" -eq 1 ] && return 0
    # The password is passed on the command line, so it is visible to "ps" for
    # your own user on this machine only. The cached copy in $CACHE is 0600.
    if command -v xfreerdp >/dev/null 2>&1; then
        xfreerdp "/v:$1" "/u:$2" "/p:$3" /dynamic-resolution +clipboard /cert:tofu /f &
    elif command -v xfreerdp3 >/dev/null 2>&1; then
        xfreerdp3 "/v:$1" "/u:$2" "/p:$3" /dynamic-resolution +clipboard /cert:tofu /f &
    elif command -v remmina >/dev/null 2>&1; then
        remmina -c "rdp://$2:$3@$1" &
    else
        warn "No RDP client found. Install one, then connect with:"
        echo "    sudo apt install freerdp2-x11"
        return 0
    fi
    CLIENT_PID=$!
    return 0
}

# ------------------------------------------------------------ find session --
load_cache
ADDRESS="${ADDRESS:-}"
if [ "$NEW" -eq 0 ] && [ -n "$ADDRESS" ] && reachable "$ADDRESS"; then
    ok "Found a live session at $ADDRESS (cached)."
else
    ADDRESS=""
    RUN_ID="$(latest_run)"
    if [ -n "$RUN_ID" ]; then
        say "Run $RUN_ID is going, waiting for its address ..."
        if wait_for_details "$RUN_ID" && reachable "$ADDRESS"; then ok "Endpoint: $ADDRESS"; else ADDRESS=""; fi
    fi
fi

if [ -z "$ADDRESS" ]; then
    RUN_ID="$(start_run)" || exit 1
    [ -n "$RUN_ID" ] || { bad "The new run did not appear."; exit 1; }
    say "Run $RUN_ID started. Waiting for the desktop (about two minutes) ..."
    wait_for_details "$RUN_ID" || {
        bad "No address after ${TIMEOUT_MIN} minutes. Check the log:"
        echo "    gh run view $RUN_ID --repo $REPO --log" >&2
        exit 1
    }
fi

save_cache "$ADDRESS" "$USERNAME" "$PASSWORD" "${PROVIDER:-unknown}" "${RUN_ID:-}"

echo
ok "=============================================================="
ok "  CONNECTING"
ok "=============================================================="
echo "  Address  : $ADDRESS"
echo "  Username : $USERNAME"
echo "  Password : $PASSWORD"
echo "  Provider : ${PROVIDER:-unknown}"
ok "=============================================================="
echo

CLIENT_PID=""
open_client "$ADDRESS" "$USERNAME" "$PASSWORD"
[ "$NOLAUNCH" -eq 1 ] && { echo "  xfreerdp /v:$ADDRESS /u:$USERNAME /p:'$PASSWORD' /cert:tofu"; exit 0; }

[ "$WATCH" -eq 0 ] && exit 0

say "Auto reconnect is on: checking $ADDRESS every ${POLL}s. Ctrl-C to stop watching."
while true; do
    sleep "$POLL"
    if [ -n "$CLIENT_PID" ] && ! kill -0 "$CLIENT_PID" 2>/dev/null; then
        say "You closed the RDP client, stopping the watch."
        break
    fi
    reachable "$ADDRESS" && continue

    warn "The endpoint $ADDRESS stopped answering."
    RUN_ID="$(latest_run)"
    if [ -n "$RUN_ID" ] && wait_for_details "$RUN_ID" && reachable "$ADDRESS"; then
        ok "Reconnecting to $ADDRESS ..."
        save_cache "$ADDRESS" "$USERNAME" "$PASSWORD" "${PROVIDER:-unknown}" "$RUN_ID"
        open_client "$ADDRESS" "$USERNAME" "$PASSWORD"
        continue
    fi

    if [ "$RESTART" -eq 1 ]; then
        say "This run is over, starting a new machine ..."
        if RUN_ID="$(start_run)" && wait_for_details "$RUN_ID" && reachable "$ADDRESS"; then
            ok "Reconnecting to $ADDRESS ..."
            save_cache "$ADDRESS" "$USERNAME" "$PASSWORD" "${PROVIDER:-unknown}" "$RUN_ID"
            warn "That is a brand new machine, so anything not saved in the rdp-data branch did not come with it."
            open_client "$ADDRESS" "$USERNAME" "$PASSWORD"
            continue
        fi
    fi
    warn "No replacement endpoint yet, will keep trying."
done
