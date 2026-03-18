#!/bin/sh
#
# create-jail.sh — Create a classic FreeBSD jail on ZFS
#
# Usage: create-jail.sh -n <name> [-d <domain>] [-v <version>] [-p <pool>] [-D <dataset>]
#
# Options:
#   -n NAME           Jail name (required)
#   -d DOMAIN         Domain suffix for hostname (default: local.tld)
#   -v VERSION        FreeBSD version to install (default: auto-detect from host)
#   -p POOL           ZFS pool name (default: Storage)
#   -D DATASET        ZFS dataset path under pool (default: /Jails)
#
# Example:
#   create-jail.sh -n myjail -d local.tld -v 14.2
#

set -eu

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Defaults
SUBDOMAIN="local.tld"
FREEBSD_VERSION=""
ZFS_POOL="Storage"
ZFS_DATASET="/Jails"
NAME=""

usage() {
    echo "Usage: $0 -n <name> [-d <domain>] [-v <version>] [-p <pool>] [-D <dataset>]"
    exit 1
}

while getopts "n:d:v:p:D:h" opt; do
    case $opt in
        n) NAME="$OPTARG" ;;
        d) SUBDOMAIN="$OPTARG" ;;
        v) FREEBSD_VERSION="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        D) ZFS_DATASET="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$NAME" ]; then
    echo "Error: Jail name (-n) is required."
    usage
fi

# Auto-detect FreeBSD version from host if not specified
if [ -z "$FREEBSD_VERSION" ]; then
    FREEBSD_VERSION=$(freebsd-version | sed 's/-.*//') 
    echo "Auto-detected FreeBSD version: ${FREEBSD_VERSION}"
fi

# Derive architecture from host
ARCH=$(uname -m)
ARCH_P=$(uname -p)

HOSTNAME="${NAME}.${SUBDOMAIN}"
JAIL_CONFIGS="/etc/jail.conf.d"
FTP_SOURCE="ftp://ftp.freebsd.org/pub/FreeBSD/releases/${ARCH}/${ARCH_P}/${FREEBSD_VERSION}-RELEASE/base.txz"

echo "==> Creating jail: ${NAME}"
echo "    Hostname:  ${HOSTNAME}"
echo "    Pool:      ${ZFS_POOL}"
echo "    Dataset:   ${ZFS_POOL}${ZFS_DATASET}/${NAME}"
echo "    Source:    ${FTP_SOURCE}"
echo ""

# Create ZFS dataset
if zfs list -H "${ZFS_POOL}${ZFS_DATASET}/${NAME}" >/dev/null 2>&1; then
    echo "Error: ZFS dataset ${ZFS_POOL}${ZFS_DATASET}/${NAME} already exists."
    exit 1
fi

zfs create -o compression=lz4 "${ZFS_POOL}${ZFS_DATASET}/${NAME}"
DESTDIR=$(zfs get -H -o value mountpoint "${ZFS_POOL}${ZFS_DATASET}/${NAME}")
echo "==> Dataset created at ${DESTDIR}"

# Fetch and extract base set
echo "==> Fetching base.txz from ${FTP_SOURCE}..."
fetch -o - "$FTP_SOURCE" | tar -xf - -C "$DESTDIR" --unlink
echo "==> Base system extracted."

# Configure basic settings
touch "${DESTDIR}/etc/rc.conf"
sysrc -f "${DESTDIR}/etc/rc.conf" hostname="${HOSTNAME}"
cp /etc/resolv.conf "${DESTDIR}/etc/resolv.conf"
cp /etc/localtime "${DESTDIR}/etc/localtime"

# Add host IP to jail's /etc/hosts
HOST_IP=$(ifconfig $(netstat -4rn | grep ^default | sed "s/.* //") inet | awk '$1 == "inet" {print $2}')
if ! grep -q "$HOSTNAME" "${DESTDIR}/etc/hosts" 2>/dev/null; then
    printf "%s\t\t%s\n" "${HOST_IP}" "${HOSTNAME}" >> "${DESTDIR}/etc/hosts"
fi

# Apply security patches
echo "==> Applying freebsd-update patches..."
env PAGER=cat freebsd-update -b "$DESTDIR" \
    --currently-running "$("${DESTDIR}/bin/freebsd-version")" \
    fetch install --not-running-from-cron || true

# Setup the Pacy World Root CA (optional)
if [ "$("${DESTDIR}/usr/bin/uname" -U)" -ge 1202000 ]; then
    echo "==> Installing Pacy World Root CA..."
    fetch -qo "${DESTDIR}/usr/share/certs/trusted/ca-pacyworld.com.pem" \
        http://cdn.pacyworld.com/pacyworld.com/ca/ca-pacyworld.com.crt
    fetch -qo "${DESTDIR}/usr/share/certs/trusted/alt_ca-morante_root.pem" \
        http://cdn.pacyworld.com/pacyworld.com/ca/alt_ca-morante_root.crt
    certctl -D "${DESTDIR}" rehash
fi

# Register the jail
mkdir -p "$JAIL_CONFIGS"
if [ -f "${JAIL_CONFIGS}/${NAME}.conf" ]; then
    echo "Error: Jail config ${JAIL_CONFIGS}/${NAME}.conf already exists."
    exit 1
fi
cat << EOF > "${JAIL_CONFIGS}/${NAME}.conf"
${NAME} {
}
EOF

# Disable noisy periodic tasks
mkdir -p "${DESTDIR}/etc"
sysrc -f "${DESTDIR}/etc/periodic.conf" \
    security_status_chksetuid_enable="NO" \
    security_status_neggrpperm_enable="NO" \
    weekly_locate_enable="NO"

echo ""
echo "==> Jail '${NAME}' created successfully."
echo "    Start with: service jail start ${NAME}"
echo "    Enter with: jexec ${NAME} /bin/sh"
echo "    Install packages: pkg --jail ${NAME} install -y <package>"
