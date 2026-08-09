#!/bin/sh
#
# create-vnet-jail.sh — Create a vnet FreeBSD jail on ZFS with epair networking
#
# Usage: create-vnet-jail.sh -n name -i ip -I id [-d domain] [-v version]
#                            [-p pool] [-g gateway] [-m mirror] [-N netmask]
#                            [-6 ip6] [-L prefix6] [-G gateway6]
#
# Options:
#   -n NAME        Jail name (required)
#   -i IP          Jail IPv4 on the bridge subnet (required, e.g. 10.99.0.1)
#   -I ID          Unique integer for epair numbering (required, e.g. 0, 1, 2)
#   -d DOMAIN      Domain suffix (default: from jail.conf or vnet.morante.com)
#   -v VERSION     FreeBSD version (default: auto-detect from host)
#   -p POOL        ZFS pool name (default: Storage)
#   -g GATEWAY     Bridge IPv4 gateway (default: 10.99.0.254)
#   -m MIRROR      Base.txz mirror URL prefix (default: https://download.morante.org)
#   -N NETMASK     IPv4 subnet prefix length (default: 24)
#   -6 IP6         Jail IPv6 address (optional, e.g. fd10:99::21)
#   -L PREFIX6     IPv6 prefix length (default: 64)
#   -G GATEWAY6    Bridge IPv6 gateway (optional, e.g. fd10:99::254)
#

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Defaults
NAME=""
JAIL_IP=""
JAIL_ID=""
FREEBSD_VERSION=""
ZFS_POOL="Storage"
GATEWAY="10.99.0.254"
NETMASK="24"
JAIL_IP6=""
PREFIX6="64"
GATEWAY6=""
MIRROR="https://download.morante.org"
DOMAIN=$(grep '^\$domain' /etc/jail.conf 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
: "${DOMAIN:=vnet.morante.com}"

usage() {
    echo "Usage: $0 -n name -i ip -I id [-d domain] [-v version] [-p pool] [-g gateway] [-m mirror] [-6 ip6] [-L prefix6] [-G gateway6]"
    exit 1
}

while getopts "n:i:I:d:v:p:g:m:N:6:L:G:h" opt; do
    case $opt in
        n) NAME="$OPTARG" ;;
        i) JAIL_IP="$OPTARG" ;;
        I) JAIL_ID="$OPTARG" ;;
        d) DOMAIN="$OPTARG" ;;
        v) FREEBSD_VERSION="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        g) GATEWAY="$OPTARG" ;;
        m) MIRROR="$OPTARG" ;;
        N) NETMASK="$OPTARG" ;;
        6) JAIL_IP6="$OPTARG" ;;
        L) PREFIX6="$OPTARG" ;;
        G) GATEWAY6="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[ -n "$NAME" ] || { echo "Error: -n (name) is required."; usage; }
[ -n "$JAIL_IP" ] || { echo "Error: -i (IP) is required."; usage; }
[ -n "$JAIL_ID" ] || { echo "Error: -I (ID) is required."; usage; }

# Auto-detect FreeBSD version from host
if [ -z "$FREEBSD_VERSION" ]; then
    FREEBSD_VERSION=$(freebsd-version | sed 's/-.*//')
fi

ARCH=$(uname -m)
ARCH_P=$(uname -p)
HOSTNAME="${NAME}.${DOMAIN}"
DESTDIR="/${ZFS_POOL}/Jails/${NAME}"
BASE_URL="${MIRROR}/releases/${ARCH}/${ARCH_P}/${FREEBSD_VERSION}-RELEASE/base.txz"

echo "==> Creating vnet jail: ${NAME}"
echo "    Hostname:  ${HOSTNAME}"
echo "    IPv4:      ${JAIL_IP}/${NETMASK}"
if [ -n "$JAIL_IP6" ]; then
    echo "    IPv6:      ${JAIL_IP6}/${PREFIX6}"
fi
echo "    Epair ID:  ${JAIL_ID}"
echo "    Gateway:   ${GATEWAY}${GATEWAY6:+, ${GATEWAY6} (v6)}"
echo "    Dataset:   ${ZFS_POOL}/Jails/${NAME}"
echo "    Source:    ${BASE_URL}"
echo ""

# Check for conflicts
if zfs list -H "${ZFS_POOL}/Jails/${NAME}" >/dev/null 2>&1; then
    echo "Error: Dataset '${ZFS_POOL}/Jails/${NAME}' already exists."
    exit 1
fi
if [ -f "/etc/jail.conf.d/${NAME}.conf" ]; then
    echo "Error: Jail config already exists."
    exit 1
fi

# --- Create ZFS dataset ---
echo "==> Creating ZFS dataset..."
zfs create -o compression=lz4 "${ZFS_POOL}/Jails/${NAME}"

# --- Fetch and extract base ---
echo "==> Fetching base.txz from ${BASE_URL}..."
fetch -o - "${BASE_URL}" | tar -xf - -C "${DESTDIR}" --unlink
echo "==> Base system extracted."

# --- Configure networking inside jail ---
echo "==> Configuring jail networking..."
touch "${DESTDIR}/etc/rc.conf"
sysrc -f "${DESTDIR}/etc/rc.conf" hostname="${HOSTNAME}"
sysrc -f "${DESTDIR}/etc/rc.conf" "ifconfig_epair${JAIL_ID}b=inet ${JAIL_IP}/${NETMASK}"
sysrc -f "${DESTDIR}/etc/rc.conf" defaultrouter="${GATEWAY}"
if [ -n "$JAIL_IP6" ]; then
    sysrc -f "${DESTDIR}/etc/rc.conf" "ifconfig_epair${JAIL_ID}b_ipv6=inet6 ${JAIL_IP6}/${PREFIX6}"
    if [ -n "$GATEWAY6" ]; then
        sysrc -f "${DESTDIR}/etc/rc.conf" ipv6_defaultrouter="${GATEWAY6}"
    fi
fi

printf "nameserver %s\n" "${GATEWAY}" > "${DESTDIR}/etc/resolv.conf"
cp /etc/localtime "${DESTDIR}/etc/localtime"

# --- Install Pacy World Root CA ---
echo "==> Installing Pacy World Root CA..."
mkdir -p "${DESTDIR}/usr/share/certs/trusted"
fetch -qo "${DESTDIR}/usr/share/certs/trusted/ca-pacyworld.com.pem" \
    http://cdn.pacyworld.com/pacyworld.com/ca/ca-pacyworld.com.crt 2>/dev/null || true
fetch -qo "${DESTDIR}/usr/share/certs/trusted/alt_ca-morante_root.pem" \
    http://cdn.pacyworld.com/pacyworld.com/ca/alt_ca-morante_root.crt 2>/dev/null || true
if [ -x "${DESTDIR}/usr/sbin/certctl" ]; then
    certctl -D "${DESTDIR}" rehash 2>/dev/null || true
fi

# --- Apply security patches ---
echo "==> Applying freebsd-update patches..."
env PAGER=cat freebsd-update -b "${DESTDIR}" \
    --currently-running "$("${DESTDIR}/bin/freebsd-version")" \
    fetch install --not-running-from-cron 2>/dev/null || true

# --- Register jail config (epair + bridge) ---
echo "==> Writing jail config..."
mkdir -p /etc/jail.conf.d
cat << EOF > "/etc/jail.conf.d/${NAME}.conf"
${NAME} {
    \$id = "${JAIL_ID}";

    exec.prestart  = "ifconfig epair\${id} create up";
    exec.prestart += "ifconfig bridge0 addm epair\${id}a";
    exec.poststop  = "ifconfig epair\${id}a destroy";
}
EOF

# --- Disable noisy periodic tasks ---
mkdir -p "${DESTDIR}/etc"
sysrc -f "${DESTDIR}/etc/periodic.conf" \
    security_status_chksetuid_enable="NO" \
    security_status_neggrpperm_enable="NO" \
    weekly_locate_enable="NO" >/dev/null

echo ""
echo "==> Jail '${NAME}' created successfully."
echo "    Start:    service jail start ${NAME}"
echo "    Enter:    jexec ${NAME} /bin/sh"
echo "    Packages: pkg -j ${NAME} install -y <pkg>"
echo "    IPv4:     ${JAIL_IP} (epair${JAIL_ID}b)"
if [ -n "$JAIL_IP6" ]; then
    echo "    IPv6:     ${JAIL_IP6}/${PREFIX6} (epair${JAIL_ID}b)"
fi
