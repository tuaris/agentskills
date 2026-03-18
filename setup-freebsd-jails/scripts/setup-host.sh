#!/bin/sh
#
# setup-host.sh — Initialize FreeBSD host for classic jail infrastructure
#
# Usage: setup-host.sh [-d <domain>] [-p <pool>] [-v <vdev>] [-D <dataset>]
#
# Options:
#   -d DOMAIN         Domain suffix for jail hostnames (default: local.tld)
#   -p POOL           ZFS pool name (default: Storage)
#   -v VDEV           ZFS vdev specification (default: da1)
#   -D DATASET        ZFS dataset path under pool (default: /Jails)
#
# Example:
#   setup-host.sh -d local.tld -p Storage -v "mirror da1 da2"
#

set -eu

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Defaults
SUBDOMAIN="local.tld"
ZFS_POOL="Storage"
ZFS_VDEV="da1"
ZFS_DATASET="/Jails"

usage() {
    echo "Usage: $0 [-d <domain>] [-p <pool>] [-v <vdev>] [-D <dataset>]"
    exit 1
}

while getopts "d:p:v:D:h" opt; do
    case $opt in
        d) SUBDOMAIN="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        v) ZFS_VDEV="$OPTARG" ;;
        D) ZFS_DATASET="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

ZFS_ROOT="/mnt/${ZFS_POOL}"
ZFS_DS_ROOT="/usr/local$(echo $ZFS_DATASET | tr '[:upper:]' '[:lower:]')"
JAIL_CONFIGS="/etc/jail.conf.d"

echo "==> Setting up FreeBSD jail infrastructure"
echo "    Domain:    ${SUBDOMAIN}"
echo "    Pool:      ${ZFS_POOL}"
echo "    Vdev:      ${ZFS_VDEV}"
echo "    Dataset:   ${ZFS_POOL}${ZFS_DATASET}"
echo "    Jail root: ${ZFS_DS_ROOT}"
echo ""

# Create ZFS pool if it doesn't exist
if ! zpool list -H "${ZFS_POOL}" >/dev/null 2>&1; then
    echo "==> Creating ZFS pool '${ZFS_POOL}'..."
    zpool create -m "${ZFS_ROOT}" ${ZFS_POOL} ${ZFS_VDEV}
    zfs set compression=lz4 "${ZFS_POOL}"
else
    echo "==> ZFS pool '${ZFS_POOL}' already exists, skipping creation."
fi

# Create Jails dataset if it doesn't exist
if ! zfs list -H "${ZFS_POOL}${ZFS_DATASET}" >/dev/null 2>&1; then
    echo "==> Creating Jails dataset '${ZFS_POOL}${ZFS_DATASET}'..."
    zfs create -p -o mountpoint="${ZFS_DS_ROOT}" "${ZFS_POOL}${ZFS_DATASET}"
else
    echo "==> Jails dataset '${ZFS_POOL}${ZFS_DATASET}' already exists, skipping creation."
fi

# Write global jail configuration
echo "==> Writing /etc/jail.conf..."
cat << EOF > /etc/jail.conf
# Global settings applied to all jails.
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.consolelog = "/var/log/jail_console_\${name}.log";

allow.raw_sockets;
exec.clean;
mount.devfs;

# Allow shared memory (needed by PostgreSQL, etc.)
allow.sysvipc;

\$domain = "${SUBDOMAIN}";
host.hostname = "\${name}.\${domain}";
path = "${ZFS_DS_ROOT}/\${name}";
ip4 = inherit;

.include "${JAIL_CONFIGS}/*.conf";
EOF

# Create per-jail config directory
mkdir -p "${JAIL_CONFIGS}"

# Enable services at boot
sysrc jail_enable="YES" zfs_enable="YES" jail_parallel_start="YES"

echo ""
echo "==> Host setup complete."
echo "    Create jails with: create-jail.sh -n <name> -d ${SUBDOMAIN}"
