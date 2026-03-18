#!/bin/sh
#
# delete-jail.sh — Delete a classic FreeBSD jail and its ZFS dataset
#
# Usage: delete-jail.sh -n <name> [-f] [-p <pool>] [-D <dataset>]
#
# Options:
#   -n NAME           Jail name to delete (required)
#   -f                Force deletion without confirmation prompt
#   -p POOL           ZFS pool name (default: Storage)
#   -D DATASET        ZFS dataset path under pool (default: /Jails)
#
# Example:
#   delete-jail.sh -n myjail
#   delete-jail.sh -n myjail -f
#

set -eu

# Defaults
ZFS_POOL="Storage"
ZFS_DATASET="/Jails"
JAIL_CONFIGS="/etc/jail.conf.d"
NAME=""
FORCE=0

usage() {
    echo "Usage: $0 -n <name> [-f] [-p <pool>] [-D <dataset>]"
    exit 1
}

while getopts "n:p:D:fh" opt; do
    case $opt in
        n) NAME="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        D) ZFS_DATASET="$OPTARG" ;;
        f) FORCE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$NAME" ]; then
    echo "Error: Jail name (-n) is required."
    usage
fi

ZFS_DS="${ZFS_POOL}${ZFS_DATASET}/${NAME}"
JAIL_CONF="${JAIL_CONFIGS}/${NAME}.conf"
CONSOLE_LOG="/var/log/jail_console_${NAME}.log"

# Check that at least one artifact exists
HAS_ZFS=0
HAS_CONF=0

if zfs list -H "${ZFS_DS}" >/dev/null 2>&1; then
    HAS_ZFS=1
fi

if [ -f "${JAIL_CONF}" ]; then
    HAS_CONF=1
fi

if [ "${HAS_ZFS}" -eq 0 ] && [ "${HAS_CONF}" -eq 0 ]; then
    echo "Error: Jail '${NAME}' not found (no ZFS dataset or config file)."
    exit 1
fi

MOUNTPOINT=""
if [ "${HAS_ZFS}" -eq 1 ]; then
    MOUNTPOINT=$(zfs get -H -o value mountpoint "${ZFS_DS}")
fi

# Show what will be deleted
echo "==> Jail '${NAME}' will be deleted:"
if [ "${HAS_ZFS}" -eq 1 ]; then
    echo "    ZFS dataset : ${ZFS_DS}"
    echo "    Mountpoint  : ${MOUNTPOINT}"
fi
if [ "${HAS_CONF}" -eq 1 ]; then
    echo "    Config file : ${JAIL_CONF}"
fi
if [ -f "${CONSOLE_LOG}" ]; then
    echo "    Console log : ${CONSOLE_LOG}"
fi
echo ""

# Confirm unless -f
if [ "${FORCE}" -eq 0 ]; then
    printf "Type 'yes' to confirm: "
    read confirm
    [ "${confirm}" = "yes" ] || { echo "Cancelled."; exit 0; }
fi

# Stop the jail if it's running
if jls -j "${NAME}" >/dev/null 2>&1; then
    echo "==> Stopping jail '${NAME}'..."
    service jail stop "${NAME}"
fi

# Destroy ZFS dataset (recursively, in case of child datasets)
if [ "${HAS_ZFS}" -eq 1 ]; then
    echo "==> Destroying ZFS dataset '${ZFS_DS}'..."
    zfs destroy -r "${ZFS_DS}"
fi

# Remove jail configuration
if [ "${HAS_CONF}" -eq 1 ]; then
    echo "==> Removing config '${JAIL_CONF}'..."
    rm "${JAIL_CONF}"
fi

# Remove console log if it exists
if [ -f "${CONSOLE_LOG}" ]; then
    echo "==> Removing console log '${CONSOLE_LOG}'..."
    rm "${CONSOLE_LOG}"
fi

echo ""
echo "==> Jail '${NAME}' deleted."
