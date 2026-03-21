---
name: setup-freebsd-cascade
description: Sets up a FreeBSD host for Windsurf Cascade remote development, including Linux compatibility layer, required utilities, and manual server installation
---

# Setup FreeBSD Host for Windsurf Cascade

This skill guides you through setting up a FreeBSD 15+ host for remote development with Windsurf Cascade.

## Requirements

- FreeBSD 15.0 or later (required for inotify emulation)
- Network access to the FreeBSD machine
- Root password (for initial setup)

## Important: Initial Setup Requires Manual Steps

On a fresh FreeBSD installation, SSH access and sudo are NOT configured. The user must perform Steps 1-2 manually on the FreeBSD console (or via existing SSH with password authentication) as root before Cascade can manage the system remotely.

**Ask the user and strongly encourage SSH key setup:**
1. Do you have SSH key access configured? If not, guide them through Step 0 first.
2. Is sudo already installed and configured? If not, Steps 1-2 must be done as root.

## Step 0: Setup SSH Key Authentication (on local machine)

**Strongly recommended before proceeding.** This enables passwordless remote access.

Generate SSH key if needed:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

Copy to FreeBSD host (requires password authentication this one time):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@freebsd-host
```

On Windows without ssh-copy-id, manually append the public key:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh user@freebsd-host "cat >> ~/.ssh/authorized_keys"
```

Add to SSH config (`%USERPROFILE%\.ssh\config` on Windows, `~/.ssh/config` on Linux/macOS):

```
Host freebsd-dev
    HostName <ip-or-hostname>
    User <username>
    IdentityFile ~/.ssh/id_ed25519
```

## Step 1: Install Sudo (as root)

Run this command as root on the FreeBSD host:

```bash
pkg install -y sudo
```

Note: doas (security/doas) won't work - Cascade specifically invokes sudo.

## Step 2: Configure Sudo (as root)

Still as root, add the user to the wheel group and enable passwordless sudo for Cascade turbo mode:

```bash
pw groupmod wheel -m USERNAME
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/USERNAME
chown root:wheel /usr/local/etc/sudoers.d/USERNAME
chmod 440 /usr/local/etc/sudoers.d/USERNAME
```

Replace `USERNAME` with the actual username.

## Step 3: Install Remaining Utilities

Now that sudo is configured, install the remaining packages:

```bash
sudo pkg install -y flock bash curl
```

## Step 4: Change Default Shell to Bash

```bash
sudo chsh -s /usr/local/bin/bash USERNAME
```

## Step 5: Enable Linux Compatibility Layer

```bash
sudo kldload linux64
sudo sysrc linux_enable="YES"
sudo service linux start
```

**Note:** `service linux status` does NOT work on FreeBSD. The linux rc script only supports start/stop/restart.

## Step 6: Install Linux Userland (Rocky Linux 9)

Rocky Linux 9 (emulators/linux_base-rl9) provides glibc 2.28+, required by Windsurf's Node.js runtime. Do NOT use CentOS 7.

```bash
sudo pkg install -y linux_base-rl9
sudo service linux restart
```

## Step 7: Manually Install Windsurf Server

Windsurf does NOT auto-install on FreeBSD. Get the commit ID and version from Windsurf's connection logs:

1. Attempt to connect with Windsurf
2. Open Output panel (Ctrl+Shift+U)
3. Select "Remote-SSH" from dropdown
4. Look for `DISTRO_COMMIT` and `DISTRO_WINDSURF_VERSION`

Then run on the FreeBSD host:

```bash
COMMIT_ID="<commit_id_from_logs>"
VERSION="<version_from_logs>"

mkdir -p ~/.windsurf-server/bin/${COMMIT_ID}
cd ~/.windsurf-server/bin/${COMMIT_ID}

curl -L -o windsurf-server.tar.gz \
  "https://windsurf-stable.codeiumdata.com/linux-reh-x64/stable/${COMMIT_ID}/windsurf-reh-linux-x64-${VERSION}.tar.gz"

tar -xzf windsurf-server.tar.gz --strip-components=1
rm windsurf-server.tar.gz
```

## Step 8: Verify Server Works

```bash
~/.windsurf-server/bin/${COMMIT_ID}/bin/windsurf-server --version
~/.windsurf-server/bin/${COMMIT_ID}/extensions/windsurf/bin/language_server_linux_x64 --version
```

Both commands should execute without errors.

## Step 9: Configure Windsurf Terminal (on local machine)

Add to Windsurf settings.json:

```json
{
  "terminal.integrated.profiles.linux": {
    "bash": {
      "path": "/usr/local/bin/bash"
    }
  },
  "terminal.integrated.defaultProfile.linux": "bash"
}
```

## Step 10: Install Windsurf Update Helper Script

Install the shell executable script from `scripts/update-windsurf-server.sh` into the user's `~/bin` folder.  
Then instruct the user they can run `update-windsurf-server` on the FreeBSD host after upgrading the Windsurf 
IDE client.

IMPORTANT: the destinations filename is `~/bin/update-windsurf-server` and should be user executable.

## Known Issues

Kernel messages like these in dmesg are harmless:

```
linux: jid 0 pid 2598 (node): syscall io_uring_setup not implemented
linux: jid 0 pid 2602 (language_server_lin): unsupported prctl option 1398164801
linux: jid 0 pid 2690 (libuv-worker): unsupported ioctl TIOCGPTPEER
```

Windsurf and Cascade function correctly despite these warnings.
