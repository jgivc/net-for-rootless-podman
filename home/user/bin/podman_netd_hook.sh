#!/bin/bash
set -euo pipefail

TAG="podman-netd-hook"
CURL_WAIT_TIMEOUT=30
log()  { logger -t "$TAG" -- "$*"; }
fail() { log "$2"; exit "$1"; }
warn_exit() { log "$1"; exit 0; }

for b in jq curl logger awk; do
    command -v "$b" >/dev/null || { echo "$TAG: no $b" >&2; exit 110; }
done

HOOK_STATE=$(cat)
PID=$(jq -r '.pid' <<<"$HOOK_STATE") || fail 2 "no pid in state"
BUNDLE=$(jq -r '.bundle' <<<"$HOOK_STATE") || fail 3 "no bundle in state"
HAVE_SANDBOX=$(jq -r '.annotations."io.kubernetes.cri-o.SandboxID" // empty' <<<"$HOOK_STATE")
CONFIG="$BUNDLE/config.json"
test -f "$CONFIG" || fail 4 "bundle config not found"

# Skip infra/service containers
if [ -z "$HAVE_SANDBOX" ]; then
    case "$(basename "$(jq -r '.process.args[0] // empty' "$CONFIG")")" in
        catatonit|pause)
            warn_exit "infra or service container. skip it"
        ;;
    esac
fi

HOSTNAME_=$(jq -r '.hostname // empty' "$CONFIG")
if [ -z "$HOSTNAME_" ]; then
    HOSTNAME_=$(jq -r '.process.env[]? | select(startswith("HOSTNAME="))
                        | sub("^HOSTNAME=";"") // empty' "$CONFIG")
fi
if [ -n "$HOSTNAME_" ]; then
    [[ "$HOSTNAME_" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]] || fail 5 "Bad hostname"
fi

OWNER_UID=$(awk '$1 == 0 {print $2; exit}' "/proc/$PID/uid_map")
[[ $OWNER_UID =~ ^[0-9]{1,10}$ ]] || fail 6 "cannot determine uid from uid_map"

SOCK="/run/user/$OWNER_UID/netd.sock"
test -S "$SOCK" || fail 7 "no service socket found"

RESOLV_CONF=$(mktemp)
trap 'rm -f "$RESOLV_CONF"' EXIT

ARGS=$(jq -cn --argjson pid "$PID" --arg hostname "$HOSTNAME_" \
              --arg resolvconf "$RESOLV_CONF" \
              '{pid:$pid, hostname:$hostname, resolvconf:$resolvconf}')

RESPONSE=$(curl -sS -f --max-time $CURL_WAIT_TIMEOUT --unix-socket "$SOCK" \
                -H 'Content-Type: application/json' -d "$ARGS" \
                http://localhost/ 2> >(logger -t "$TAG")) || fail 8 "netd request failed"

EXITCODE=$(jq -r '.exitcode' <<<"$RESPONSE") || fail 9 "bad response from netd: $RESPONSE"
[[ $EXITCODE =~ ^[0-9]+$ ]] || fail 10 "invalid exitcode: $EXITCODE"

if [ "$EXITCODE" -ne 0 ]; then
    log "netd returned exitcode $EXITCODE"
    [ "$EXITCODE" -le 255 ] || EXITCODE=1
    exit "$EXITCODE"
fi

# Install resolv.conf
ROOT=$(jq -r '.root // empty' <<<"$HOOK_STATE")
TARGET="$ROOT/etc/resolv.conf"
test -s "$RESOLV_CONF" || warn_exit "no resolv.conf for install"
test -d "$ROOT/etc" || warn_exit "destination container does not have /etc dir"
test -L "$TARGET" && warn_exit "destination /etc/resolv.conf is symlink. skip install"

install -m 0644 "$RESOLV_CONF" "$TARGET" || fail 11 "cannot install resolv.conf"

exit 0
