---
name: setup-freebsd-vnet-jails
description: Sets up vnet (VIMAGE) FreeBSD jail infrastructure using ZFS, bridge0, and epair interfaces. Each jail gets its own network stack with a unique IP on an internal bridge. Use when the user wants isolated network jails for multi-server testing.
license: BSD-2-Clause
compatibility: Requires FreeBSD 14.2 or later with VIMAGE support (default in GENERIC), ZFS, and at least one additional disk/volume
metadata:
  author: Daniel Morante
  version: "1.0"
---

# Setup FreeBSD vnet Jails with ZFS

This skill sets up a vnet jail infrastructure on FreeBSD using ZFS. Each jail gets its own full network stack (VIMAGE) with a dedicated IP address on an internal bridge network. The host provides NAT (via pf) for outbound internet access and can optionally run Unbound for local DNS.

## Key Differences from Classic Jails

| Classic (`ip4=inherit`) | vnet (VIMAGE) |
|------------------------|---------------|
| Shares host IP/ports | Own IP stack per jail |
| Cannot bind same port in 2 jails | Each jail has unique IP, any port |
| No raw sockets without `allow.raw_sockets` | Full raw socket access (own stack) |
| Simple, no bridge needed | Requires bridge + epair interfaces |
| No inter-jail routing | Jails can communicate via bridge |

## Requirements

- FreeBSD 14.2+ with VIMAGE in kernel (default in GENERIC since 12.0)
- Root or sudo access
- At least one additional disk/volume for ZFS
- Network interface for the host's external connectivity

## Important: Gather Information First

Before starting, ask the user for:

1. **Domain suffix** for jail hostnames (e.g., `vnet.morante.com`)
2. **ZFS device(s)** — a single device (e.g., `da1`) or mirror
3. **ZFS pool name** — default: `Storage`
4. **Bridge subnet** — default: `10.99.0.0/24`, gateway at `.254`
5. **External interface** — e.g., `vmx0`, `em0`, `vtnet0`
6. **DNS strategy** — local Unbound on the host, or forward to an external resolver

## Step 1: Initial Host Setup

Run `setup-vnet-host.sh` or perform these steps manually:

```sh
# Create ZFS pool (skip if exists)
zpool create -o ashift=12 Storage da1
zfs set compression=lz4 Storage
zfs create Storage/Jails
zfs create Storage/Jails/templates

# Enable IP forwarding
sysrc gateway_enable="YES"
sysctl net.inet.ip.forwarding=1

# Create bridge
sysrc cloned_interfaces="bridge0"
sysrc ifconfig_bridge0="inet 10.99.0.254/24 up"
ifconfig bridge0 create
ifconfig bridge0 inet 10.99.0.254/24 up

# Enable pf for NAT
sysrc pf_enable="YES"
kldload pf 2>/dev/null || true
```

## Step 2: Configure pf for NAT

Create `/etc/pf.conf`:

```
ext_if = "vmx0"
jail_net = "10.99.0.0/24"

set skip on lo0

# NAT jail traffic to internet
nat on $ext_if from $jail_net to any -> ($ext_if)

# Allow all (test host — tighten for production)
pass all
```

Load it:
```sh
pfctl -f /etc/pf.conf
pfctl -e
```

## Step 3: Configure the Jail Framework

Create `/etc/jail.conf`:

```
# Global vnet jail settings
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown jail";
exec.consolelog = "/var/log/jail_console_${name}.log";

exec.clean;
mount.devfs;

$domain = "vnet.morante.com";
host.hostname = "${name}.${domain}";
path = "/Storage/Jails/${name}";

# vnet is default on this host
vnet;
vnet.interface = "epair${id}b";

# Per-jail overrides (epair creation, IP assignment)
.include "/etc/jail.conf.d/*.conf";
```

**CRITICAL**: Do NOT put `allow.raw_sockets` or `allow.sysvipc` in the global section — those inject `ip4=new` in FreeBSD 15+ which is incompatible with vnet. Set them per-jail if needed:
```
myjail {
    allow.raw_sockets;
    allow.sysvipc;
}
```

Create the per-jail config directory:
```sh
mkdir -p /etc/jail.conf.d
```

Enable jails at boot:
```sh
sysrc jail_enable="YES" jail_parallel_start="YES"
```

## Step 4: Create a vnet Jail

For each new jail, the key addition vs classic jails is the **epair interface** and **per-jail network config**.

### Variables

```sh
NAME=myjail
JAIL_IP=10.99.0.1
BRIDGE_GW=10.99.0.254
JAIL_ID=0          # Unique integer per jail (for epair numbering)
FREEBSD_VERSION=15.1
ZFS_POOL=Storage
```

### Create ZFS dataset + extract base

```sh
zfs create -o compression=lz4 ${ZFS_POOL}/Jails/${NAME}
DESTDIR=/Storage/Jails/${NAME}

# Fetch from local mirror (fast)
fetch -o - "https://download.morante.org/releases/amd64/amd64/${FREEBSD_VERSION}-RELEASE/base.txz" \
    | tar -xf - -C ${DESTDIR} --unlink
```

### Configure jail networking (inside the jail root)

```sh
# rc.conf inside the jail
sysrc -f ${DESTDIR}/etc/rc.conf hostname="${NAME}.vnet.morante.com"
sysrc -f ${DESTDIR}/etc/rc.conf ifconfig_epair${JAIL_ID}b="inet ${JAIL_IP}/24"
sysrc -f ${DESTDIR}/etc/rc.conf defaultrouter="${BRIDGE_GW}"

# DNS resolver pointing to bridge gateway (where Unbound listens)
cat << EOF > ${DESTDIR}/etc/resolv.conf
nameserver ${BRIDGE_GW}
EOF

# Timezone
cp /etc/localtime ${DESTDIR}/etc/localtime
```

### Install Pacy World Root CA

```sh
fetch -qo ${DESTDIR}/usr/share/certs/trusted/ca-pacyworld.com.pem \
    http://cdn.pacyworld.com/pacyworld.com/ca/ca-pacyworld.com.crt
fetch -qo ${DESTDIR}/usr/share/certs/trusted/alt_ca-morante_root.pem \
    http://cdn.pacyworld.com/pacyworld.com/ca/alt_ca-morante_root.crt
certctl -D ${DESTDIR} rehash
```

### Apply security patches

```sh
env PAGER=cat freebsd-update -b ${DESTDIR} \
    --currently-running $(${DESTDIR}/bin/freebsd-version) \
    fetch install --not-running-from-cron || true
```

### Register the jail (per-jail config with epair + bridge)

```sh
cat << EOF > /etc/jail.conf.d/${NAME}.conf
${NAME} {
    \$id = "${JAIL_ID}";

    # Create epair, assign b-side to jail, add a-side to bridge
    exec.prestart  = "ifconfig epair${id} create up";
    exec.prestart += "ifconfig bridge0 addm epair${id}a";
    exec.poststop  = "ifconfig epair${id}a destroy";
}
EOF
```

### Start the jail

```sh
service jail start ${NAME}
```

### Verify networking

```sh
jexec ${NAME} ifconfig epair${JAIL_ID}b    # Should show ${JAIL_IP}
jexec ${NAME} ping -c1 10.99.0.254         # Gateway reachable
jexec ${NAME} ping -c1 1.1.1.1             # Internet via NAT
jexec ${NAME} drill google.com             # DNS works
```

## Step 5: Install Packages

Since jails have internet access via NAT:

```sh
pkg -j ${NAME} install -y <package>
```

Or enter the jail and use pkg directly:
```sh
jexec ${NAME} pkg install -y postfix
```

## Managing vnet Jails

### Enter a jail
```sh
jexec ${NAME} /bin/sh
```

### Stop/start
```sh
service jail stop ${NAME}
service jail start ${NAME}
```

### Delete a jail
```sh
service jail stop ${NAME}
zfs destroy -r Storage/Jails/${NAME}
rm /etc/jail.conf.d/${NAME}.conf
rm -f /var/log/jail_console_${NAME}.log
```

## Networking Reference

```
                    Internet
                       |
                   [ vmx0 ]  192.168.x.x (host external)
                       |
                   [ pf NAT ]
                       |
                  [ bridge0 ]  10.99.0.254/24 (host gateway)
                   /   |   \
          epair0a  epair1a  epair2a   (host-side, in bridge)
             |        |        |
          epair0b  epair1b  epair2b   (jail-side, vnet.interface)
             |        |        |
         [jail-0]  [jail-1]  [jail-2]
         10.99.0.1 10.99.0.2 10.99.0.3
```

## Installing the Helper Scripts

```sh
install -m 755 scripts/setup-vnet-host.sh /usr/local/sbin/setup-vnet-host
install -m 755 scripts/create-vnet-jail.sh /usr/local/sbin/create-vnet-jail
install -m 755 scripts/delete-vnet-jail.sh /usr/local/sbin/delete-vnet-jail
```

## Common Issues

### "vnet jails cannot have IP address restrictions"
Caused by `allow.raw_sockets` or `allow.sysvipc` in the GLOBAL jail.conf (FreeBSD 15+ injects `ip4=new`). Move them to per-jail configs.

### Jail can't reach internet
1. Check `net.inet.ip.forwarding` is 1
2. Check pf is loaded and NAT rule active: `pfctl -s nat`
3. Check bridge has the epairXa member: `ifconfig bridge0`

### Jail can't resolve DNS
1. Verify Unbound is listening on bridge gateway IP
2. Verify jail's `resolv.conf` points to gateway
3. Check Unbound `access-control` includes the bridge subnet
