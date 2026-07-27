#!/bin/sh
#
# setup-vnet-host.sh — Initialize FreeBSD host for vnet jail infrastructure
#
# Usage: setup-vnet-host.sh [-d domain] [-p pool] [-v vdev] [-e ext_if] [-s subnet] [-g gateway]
#
# Options:
#   -d DOMAIN      Domain suffix for jail hostnames (default: vnet.morante.com)
#   -p POOL        ZFS pool name (default: Storage)
#   -v VDEV        ZFS vdev specification (default: da1)
#   -e EXT_IF      External network interface (default: auto-detect)
#   -s SUBNET      Bridge subnet CIDR (default: 10.99.0.0/24)
#   -g GATEWAY     Bridge gateway IP (default: 10.99.0.254)
#   -D DNS         DNS forwarder for Unbound (default: 1.1.1.1)
#

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Defaults
DOMAIN="vnet.morante.com"
ZFS_POOL="Storage"
ZFS_VDEV="da1"
EXT_IF=""
SUBNET="10.99.0.0/24"
GATEWAY="10.99.0.254"
DNS_FWD="1.1.1.1"

usage() {
    echo "Usage: $0 [-d domain] [-p pool] [-v vdev] [-e ext_if] [-s subnet] [-g gateway] [-D dns]"
    exit 1
}

while getopts "d:p:v:e:s:g:D:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        p) ZFS_POOL="$OPTARG" ;;
        v) ZFS_VDEV="$OPTARG" ;;
        e) EXT_IF="$OPTARG" ;;
        s) SUBNET="$OPTARG" ;;
        g) GATEWAY="$OPTARG" ;;
        D) DNS_FWD="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Auto-detect external interface
if [ -z "${EXT_IF}" ]; then
    EXT_IF=$(netstat -4rn | grep '^default' | sed 's/.* //')
    if [ -z "${EXT_IF}" ]; then
        echo "Error: Cannot auto-detect external interface. Use -e."
        exit 1
    fi
fi

NETMASK=$(echo "${SUBNET}" | sed 's|.*/||')

echo "==> Setting up FreeBSD vnet jail infrastructure"
echo "    Domain:     ${DOMAIN}"
echo "    Pool:       ${ZFS_POOL}"
echo "    Vdev:       ${ZFS_VDEV}"
echo "    Ext IF:     ${EXT_IF}"
echo "    Bridge:     ${GATEWAY}/${NETMASK}"
echo "    DNS fwd:    ${DNS_FWD}"
echo ""

# --- ZFS ---
if ! zpool list -H "${ZFS_POOL}" >/dev/null 2>&1; then
    echo "==> Creating ZFS pool '${ZFS_POOL}'..."
    zpool create -o ashift=12 ${ZFS_POOL} ${ZFS_VDEV}
    zfs set compression=lz4 "${ZFS_POOL}"
else
    echo "==> ZFS pool '${ZFS_POOL}' already exists."
fi

for ds in Jails Jails/templates; do
    if ! zfs list -H "${ZFS_POOL}/${ds}" >/dev/null 2>&1; then
        echo "==> Creating dataset '${ZFS_POOL}/${ds}'..."
        zfs create "${ZFS_POOL}/${ds}"
    fi
done

# --- Networking ---
echo "==> Configuring bridge0 and IP forwarding..."
sysctl net.inet.ip.forwarding=1 >/dev/null
sysrc gateway_enable="YES" >/dev/null
sysrc cloned_interfaces="bridge0" >/dev/null
sysrc ifconfig_bridge0="inet ${GATEWAY}/${NETMASK} up" >/dev/null

ifconfig bridge0 create 2>/dev/null || true
ifconfig bridge0 inet "${GATEWAY}/${NETMASK}" up 2>/dev/null || true

# --- pf NAT ---
echo "==> Configuring pf NAT..."
sysrc pf_enable="YES" >/dev/null
kldload pf 2>/dev/null || true

cat << EOF > /etc/pf.conf
# vnet jail host — NAT for jail bridge network
ext_if = "${EXT_IF}"
jail_net = "${SUBNET}"

set skip on lo0
nat on \$ext_if from \$jail_net to any -> (\$ext_if)
pass all
EOF

pfctl -f /etc/pf.conf 2>/dev/null
pfctl -e 2>/dev/null || true

# --- jail.conf ---
echo "==> Writing /etc/jail.conf..."
mkdir -p /etc/jail.conf.d

cat << EOF > /etc/jail.conf
# Global vnet jail settings
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown jail";
exec.consolelog = "/var/log/jail_console_\${name}.log";

exec.clean;
mount.devfs;

\$domain = "${DOMAIN}";
host.hostname = "\${name}.\${domain}";
path = "/${ZFS_POOL}/Jails/\${name}";

# vnet is default on this host
vnet;
vnet.interface = "epair\${id}b";

.include "/etc/jail.conf.d/*.conf";
EOF

sysrc jail_enable="YES" jail_parallel_start="YES" >/dev/null

# --- Unbound (optional local DNS) ---
if command -v unbound >/dev/null 2>&1; then
    echo "==> Configuring Unbound on ${GATEWAY}..."
    cat << EOF > /usr/local/etc/unbound/unbound.conf
server:
    interface: ${GATEWAY}
    interface: 127.0.0.1
    access-control: ${SUBNET} allow
    access-control: 127.0.0.0/8 allow
    do-not-query-localhost: no
    verbosity: 1

forward-zone:
    name: "."
    forward-addr: ${DNS_FWD}
    forward-addr: 8.8.8.8
EOF

    sysrc unbound_enable="YES" >/dev/null
    service unbound restart 2>/dev/null || service unbound start 2>/dev/null || true
fi

echo ""
echo "==> Host setup complete."
echo "    Create jails with: create-vnet-jail.sh -n <name> -i <ip> -I <id>"
echo "    Bridge gateway: ${GATEWAY}"
echo "    NAT: ${SUBNET} -> ${EXT_IF}"
