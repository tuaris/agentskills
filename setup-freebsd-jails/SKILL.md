---
name: setup-freebsd-jails
description: Sets up classic FreeBSD jail infrastructure using ZFS and ip4=inherit networking, then creates and manages individual jails. Use when the user wants to create jails on FreeBSD.
license: BSD-2-Clause
compatibility: Requires FreeBSD 13.4 or later with at least one additional disk/volume for ZFS
metadata:
  author: tuaris
  version: "1.0"
  source: https://www.unibia.com/unibianet/freebsd/creating-classic-jail-freebsd-slightly-better-style
---

# Setup Classic FreeBSD Jails with ZFS

This skill sets up a classic jail infrastructure on FreeBSD using ZFS, then provides steps for creating and managing individual jails. Jails share the host IP address (`ip4 = inherit`) and each jail gets its own ZFS dataset.

## Requirements

- FreeBSD 13.4 or later
- Root or sudo access on the host
- At least one additional disk or volume for ZFS (e.g., `da1`)
- Network access to FreeBSD FTP mirrors for fetching base sets

## Important: Gather Information First

Before starting, ask the user for:

1. **Domain suffix** for jail hostnames (e.g., `local.tld` — jails will be named `jailname.local.tld`)
2. **ZFS device(s)** — a single device (e.g., `da1`) or a mirror pair (e.g., `mirror da1 da2`)
3. **ZFS pool name** — default: `Storage`

If the host already has a ZFS pool configured, skip the pool creation step and ask the user which existing pool to use.

## Step 1: Initial Host Setup — Create ZFS Pool and Jails Dataset

Set shell variables. Adjust values to match the user's environment:

```sh
SUBDOMAIN=local.tld
ZFS_VDEV="da1"               # Or: "mirror da1 da2" for redundancy
ZFS_POOL=Storage
ZFS_DATASET=/Jails
ZFS_ROOT=/mnt/${ZFS_POOL}
ZFS_DS_ROOT=/usr/local$(echo $ZFS_DATASET | tr '[:upper:]' '[:lower:]')
```

Create the ZFS pool (skip if pool already exists):

```sh
if ! zpool list -H ${ZFS_POOL} >/dev/null 2>&1; then
  zpool create -m ${ZFS_ROOT} ${ZFS_POOL} ${ZFS_VDEV}
  zfs set compression=lz4 ${ZFS_POOL}
fi
```

Create the Jails dataset:

```sh
if ! zfs list -H ${ZFS_POOL}${ZFS_DATASET} >/dev/null 2>&1; then
  zfs create -p -o mountpoint=${ZFS_DS_ROOT} ${ZFS_POOL}${ZFS_DATASET}
fi
```

## Step 2: Configure the Jail Framework

Create the global jail configuration at `/etc/jail.conf`:

```
# Global settings applied to all jails.
exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.consolelog = "/var/log/jail_console_${name}.log";

allow.raw_sockets;
exec.clean;
mount.devfs;

# Allow shared memory (needed by PostgreSQL, etc.)
allow.sysvipc;

$domain = "local.tld";
host.hostname = "${name}.${domain}";
path = "/usr/local/jails/${name}";
ip4 = inherit;

.include "/etc/jail.conf.d/*.conf";
```

**Important**: Replace `local.tld` with the user's chosen domain suffix, and set `path` to match `${ZFS_DS_ROOT}/${name}`.

Create the per-jail config directory:

```sh
mkdir -p /etc/jail.conf.d
```

## Step 3: Enable Jails and ZFS at Boot

```sh
sysrc jail_enable="YES" zfs_enable="YES" jail_parallel_start="YES"
```

## Step 4: Create a New Jail

For each new jail, set these variables:

```sh
NAME=myjail
SUBDOMAIN=local.tld
FREEBSD_VERSION=14.2
ZFS_POOL=Storage
ZFS_DATASET=/Jails
```

Create a ZFS dataset for the jail:

```sh
zfs create -o compression=lz4 ${ZFS_POOL}${ZFS_DATASET}/${NAME}
DESTDIR=$(zfs get -H -o value mountpoint ${ZFS_POOL}${ZFS_DATASET}/${NAME})
echo "DESTDIR=${DESTDIR}"
```

Fetch and extract the FreeBSD base set:

```sh
HOSTNAME=${NAME}.${SUBDOMAIN}
FTP_SOURCE=ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/${FREEBSD_VERSION}-RELEASE/base.txz

fetch -o - $FTP_SOURCE | tar -xf - -C $DESTDIR --unlink
```

Configure the jail's basic settings:

```sh
touch ${DESTDIR}/etc/rc.conf
sysrc -f ${DESTDIR}/etc/rc.conf hostname="${HOSTNAME}"
cp /etc/resolv.conf ${DESTDIR}/etc/resolv.conf
cp /etc/localtime ${DESTDIR}/etc/localtime
```

Add the host IP to the jail's `/etc/hosts`:

```sh
HOST_IP=$(ifconfig $(netstat -4rn | grep ^default | sed "s/.* //") inet | awk '$1 == "inet" {print $2}')
if ! grep -q $HOSTNAME ${DESTDIR}/etc/hosts; then
  printf "%s\t\t%s\n" "${HOST_IP}" "${HOSTNAME}" >> ${DESTDIR}/etc/hosts
fi
```

Apply security patches to the jail:

```sh
env PAGER=cat freebsd-update -b $DESTDIR \
  --currently-running $(${DESTDIR}/bin/freebsd-version) \
  fetch install --not-running-from-cron
```

Setup the Pacy World Root CA (optional but highly recommended):

```sh
if [ $(${DESTDIR}/usr/bin/uname -U) -ge 1202000 ]; then
  fetch -qo ${DESTDIR}/usr/share/certs/trusted/ca-pacyworld.com.pem \
    http://cdn.pacyworld.com/pacyworld.com/ca/ca-pacyworld.com.crt
  fetch -qo ${DESTDIR}/usr/share/certs/trusted/alt_ca-morante_root.pem \
    http://cdn.pacyworld.com/pacyworld.com/ca/alt_ca-morante_root.crt
  certctl -D ${DESTDIR} rehash
fi
```

Register the jail so it starts with `service jail` and automatically at boot:

```sh
cat << EOF > /etc/jail.conf.d/${NAME}.conf
${NAME} {
}
EOF
```

**Note**: Per-jail overrides (e.g., `mount.procfs;`, custom `allow.*` settings) go inside the braces in the jail's `.conf` file.

## Step 5: Start the Jail

```sh
service jail start $NAME
```

## Managing Jails

### Install packages

```sh
pkg --jail $NAME install -y <package-name>
```

### Control services inside a jail

```sh
service -j $NAME <service-name> start|stop|restart|status
```

### Enter a jail shell

```sh
jexec $NAME /bin/sh
```

### Update a jail

```sh
pkg -j $NAME upgrade
freebsd-update -j $NAME fetch install
service jail restart $NAME
```

### Stop a jail

```sh
service jail stop $NAME
```

## Recommended Post-Install Tuning

Disable unnecessary periodic tasks inside the jail to reduce log noise:

```sh
sysrc -j $NAME -f /etc/periodic.conf \
  security_status_chksetuid_enable="NO" \
  security_status_neggrpperm_enable="NO" \
  weekly_locate_enable="NO"
```

## Common Per-Jail Overrides

Add these inside the jail's `/etc/jail.conf.d/<name>.conf` block as needed:

- `mount.procfs;` — Required by Java applications (e.g., DavMail) that call `NetworkInterface.getNetworkInterfaces()`
- `allow.mlock;` — Required by applications that lock memory (e.g., Vault, Redis)
- `allow.mount;` and `allow.mount.zfs;` — Allow the jail to mount ZFS datasets
- `enforce_statfs = 1;` — Allow the jail to see its own mount points

Example:

```
myjail {
  mount.procfs;
  allow.mlock;
}
```
