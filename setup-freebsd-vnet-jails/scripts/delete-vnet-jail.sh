#!/bin/sh
#
# delete-vnet-jail.sh — Delete a vnet FreeBSD jail and its ZFS dataset
#
# Usage: delete-vnet-jail.sh -n name [-f] [-p pool]
#
# Options:
#   -n NAME    Jail name to delete (required)
#   -f         Force deletion without confirmation
#   -p POOL    ZFS pool name (default: Storage)
#

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

NAME=""
ZFS_POOL="Storage"
FORCE=0

usage() {
    echo "Usage: $0 -n name [-f] [-p pool]"
    exit 1
}

while getopts "n:p:fh" opt; do
    case $opt in
        n) NAME="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        f) FORCE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

[ -n "$NAME" ] || { echo "Error: -n (name) is required."; usage; }

ZFS_DS="${ZFS_POOL}/Jails/${NAME}"
JAIL_CONF="/etc/jail.conf.d/${NAME}.conf"
CONSOLE_LOG="/var/log/jail_console_${NAME}.log"

# Check existence
HAS_ZFS=0
HAS_CONF=0
zfs list -H "${ZFS_DS}" >/dev/null 2>&1 && HAS_ZFS=1
[ -f "${JAIL_CONF}" ] && HAS_CONF=1

if [ "${HAS_ZFS}" -eq 0 ] && [ "${HAS_CONF}" -eq 0 ]; then
    echo "Error: Jail '${NAME}' not found."
    exit 1
fi

echo "==> Will delete jail '${NAME}':"
[ "${HAS_ZFS}" -eq 1 ] && echo "    ZFS: ${ZFS_DS}"
[ "${HAS_CONF}" -eq 1 ] && echo "    Config: ${JAIL_CONF}"
[ -f "${CONSOLE_LOG}" ] && echo "    Log: ${CONSOLE_LOG}"
echo ""

if [ "${FORCE}" -eq 0 ]; then
    printf "Type 'yes' to confirm: "
    read confirm
    [ "${confirm}" = "yes" ] || { echo "Cancelled."; exit 0; }
fi

# Stop if running
if jls -j "${NAME}" >/dev/null 2>&1; then
    echo "==> Stopping jail '${NAME}'..."
    service jail stop "${NAME}"
fi

# Destroy ZFS
if [ "${HAS_ZFS}" -eq 1 ]; then
    echo "==> Destroying ZFS dataset..."
    zfs destroy -r "${ZFS_DS}"
fi

# Remove config
[ "${HAS_CONF}" -eq 1 ] && rm "${JAIL_CONF}"
[ -f "${CONSOLE_LOG}" ] && rm "${CONSOLE_LOG}"

echo "==> Jail '${NAME}' deleted."
