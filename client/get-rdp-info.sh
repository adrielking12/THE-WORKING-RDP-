#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# get-rdp-info.sh - read the address / username / password of the newest
# Windows RDP session out of the GitHub Actions log.
#
# Works on Linux and macOS. Needs:
#   * the GitHub CLI (gh), authenticated once with "gh auth login"
#   * optionally xfreerdp (package freerdp2-x11 or freerdp3-x11) to connect
#
# Usage:
#   ./get-rdp-info.sh                        # show the connection details
#   ./get-rdp-info.sh --wait                 # wait until a run publishes them
#   ./get-rdp-info.sh --connect              # start xfreerdp right away
#   ./get-rdp-info.sh --repo owner/name --workflow main.yml
# ---------------------------------------------------------------------------
set -uo pipefail

REPO=""
WORKFLOW="main.yml"
WAIT=0
CONNECT=0
POLL=20

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --workflow) WORKFLOW="$2"; shift 2 ;;
        --wait) WAIT=1; shift ;;
        --connect) CONNECT=1; shift ;;
        --poll) POLL="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v gh >/dev/null 2>&1 || {
    echo "The GitHub CLI (gh) is required. Install it from https://cli.github.com and run 'gh auth login'." >&2
    exit 1
}

if [ -z "$REPO" ]; then
    remote="$(git remote get-url origin 2>/dev/null || true)"
    REPO="$(printf '%s' "$remote" | sed -n 's#.*github\.com[:/]\(.*\)#\1#p' | sed 's#\.git$##')"
fi
[ -n "$REPO" ] || { echo "Could not work out the repository, pass --repo owner/name" >&2; exit 1; }

echo "[get-rdp-info] repository: $REPO"

fetch_details() {
    run_id="$1"
    gh run view "$run_id" --repo "$REPO" --log 2>/dev/null |
        grep -o '\[rdp-info\] [a-z_]*=.*' |
        sed 's/\[rdp-info\] //'
}

while true; do
    run_json="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 10 \
        --json databaseId,status,conclusion,createdAt,headBranch 2>/dev/null)"
    [ -n "$run_json" ] || { echo "No runs of '$WORKFLOW' found in $REPO. Start the workflow first." >&2; exit 2; }

    # newest run that is still going, else the newest one overall
    run_id="$(printf '%s' "$run_json" | tr '}' '\n' | grep -v '"status":"completed"' | sed -n 's/.*"databaseId":\([0-9]*\).*/\1/p' | head -1)"
    status="running"
    if [ -z "$run_id" ]; then
        run_id="$(printf '%s' "$run_json" | tr '}' '\n' | sed -n 's/.*"databaseId":\([0-9]*\).*/\1/p' | head -1)"
        status="completed"
    fi
    [ -n "$run_id" ] || { echo "Could not list workflow runs." >&2; exit 2; }

    echo "[get-rdp-info] newest run: $run_id ($status)"
    details="$(fetch_details "$run_id")"

    if [ -n "$details" ]; then
        break
    fi

    if [ "$status" = "completed" ]; then
        echo "That run has finished, so its RDP session is gone. Start a new run and try again." >&2
        exit 3
    fi
    if [ "$WAIT" -ne 1 ]; then
        echo "The run has not published an endpoint yet. Use --wait to keep polling." >&2
        exit 4
    fi
    echo "[get-rdp-info] no endpoint yet, retrying in ${POLL}s ..."
    sleep "$POLL"
done

get() { printf '%s\n' "$details" | sed -n "s/^$1=//p" | head -1; }

PROVIDER="$(get provider)"
ADDRESS="$(get address)"
USERNAME="$(get username)"
PASSWORD="$(get password)"
VERIFIED="$(get verified)"

echo
echo "=============================================================="
echo "  RDP SESSION FOUND"
echo "=============================================================="
echo "  Address  : $ADDRESS"
echo "  Username : $USERNAME"
echo "  Password : $PASSWORD"
echo "  Provider : $PROVIDER   (end-to-end verified: $VERIFIED)"
echo "=============================================================="
echo

if [ "$CONNECT" -eq 1 ]; then
    if command -v xfreerdp >/dev/null 2>&1; then
        echo "[get-rdp-info] starting xfreerdp ..."
        exec xfreerdp "/v:$ADDRESS" "/u:$USERNAME" "/p:$PASSWORD" /dynamic-resolution +clipboard /cert:tofu
    elif command -v xfreerdp3 >/dev/null 2>&1; then
        exec xfreerdp3 "/v:$ADDRESS" "/u:$USERNAME" "/p:$PASSWORD" /dynamic-resolution +clipboard /cert:tofu
    elif command -v remmina >/dev/null 2>&1; then
        exec remmina -c "rdp://$USERNAME:$PASSWORD@$ADDRESS"
    else
        echo "No xfreerdp/remmina found. Install one of these, then connect with:" >&2
        echo "  sudo apt install freerdp2-x11" >&2
    fi
fi

echo "Connect with one of these:"
echo "  Linux   : xfreerdp /v:$ADDRESS /u:$USERNAME /p:'$PASSWORD' /dynamic-resolution +clipboard /cert:tofu"
echo "  macOS   : Microsoft Remote Desktop app, PC name $ADDRESS"
echo "  Windows : mstsc /v:$ADDRESS"
