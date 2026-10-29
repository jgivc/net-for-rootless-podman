#!/bin/bash
set -u

TAG="netd-handler"
IFACE_TYPE="veth"
BRIDGE_NAME="br0"
READ_TIMEOUT=5
LXC_USER_NIC=/usr/libexec/lxc/lxc-user-nic
DHCP_SCRIPT=/home/user/bin/dhcp.sh

write_response() {
    EXITCODE=$1

    RESPONSE_BODY=$(jq -cn --argjson exitcode "$EXITCODE" '{"exitcode":$exitcode}')
    RESPONSE_LENGTH=$(printf "%s" "$RESPONSE_BODY" | wc -c)

    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Length: %d\r\n" "$RESPONSE_LENGTH"
    printf "Content-Type: application/json; charset=utf-8\r\n"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$RESPONSE_BODY"
}

succeed() { write_response 0; exit 0; }

fail() {
    EXITCODE=$1
    ERROR=$2

    logger -t "$TAG" "$ERROR"
    write_response "$EXITCODE"

    exit 0
}

CONTENT_LENGTH=0
METHOD=""
PATH_REQ=""

while IFS= read -r -t $READ_TIMEOUT line; do
    line="${line%$'\r'}"

    [ -z "$line" ] && break

    if [ -z "$METHOD" ]; then
        read -r METHOD PATH_REQ _ <<< "$line"
        continue
    fi

    if [[ "${line,,}" =~ ^content-length:[[:space:]]*([0-9]+) ]]; then
        CONTENT_LENGTH="${BASH_REMATCH[1]}"
    fi
done

BODY=""
if [ "$CONTENT_LENGTH" -gt 0 ]; then
    read -r -t $READ_TIMEOUT -N "$CONTENT_LENGTH" BODY || fail 2 "cannot read body"
fi

CONTAINER_PID=$(jq -r '.pid' <<<"$BODY")
CONTAINER_HOSTNAME=$(jq -r '.hostname // empty' <<<"$BODY")
RESOLV_CONF=$(jq -r '.resolvconf // empty' <<<"$BODY")

if [ -n "$CONTAINER_HOSTNAME" ]; then
    [[ "$CONTAINER_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]] || fail 2 "Bad hostname"
fi

if [ -w "$RESOLV_CONF" ]; then
    export RESOLV_CONF
fi

[[ "$CONTAINER_PID" =~ ^[0-9]{1,7}$ ]] || fail 1 "Invalid PID"

exec {pfd}< "/proc/$CONTAINER_PID" || fail 3 "no such pid"
exec {userfd}< "/proc/self/fd/$pfd/ns/user" || fail 4 "no userns"
exec {netfd}<  "/proc/self/fd/$pfd/ns/net" || fail 5 "no netns"
exec {pfd}<&-

ns() { nsenter --user="/proc/self/fd/$userfd" --net="/proc/self/fd/$netfd" \
               --preserve-credentials -- "$@" > /dev/null 2>&1; }

if ! ns ip link show eth0; then
    "$LXC_USER_NIC" create "" "" "$CONTAINER_PID" "$IFACE_TYPE" "$BRIDGE_NAME" eth0 > /dev/null \
        || fail 6 "lxc-user-nic failed"
    ns ip link set eth0 up || fail 7 "cannot up eth0"
fi

HOSTNAME_ARGS=()
if [ -n "$CONTAINER_HOSTNAME" ]; then
    HOSTNAME_ARGS=(-x "hostname:$CONTAINER_HOSTNAME")
fi

# If it’s a pod, we still run a DHCP client so that it can generate a `resolv.conf` file for each container.
# Once the address has been obtained for the first time, the process runs quickly.
ns busybox udhcpc -q -n -t 3 -T 3 -i eth0 -s "$DHCP_SCRIPT" "${HOSTNAME_ARGS[@]}" || fail 8 "DHCP failed"

succeed
