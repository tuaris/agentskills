---
name: setup-freebsd-vscode
description: Configure Visual Studio Code Remote-SSH to connect to a FreeBSD host by manually installing the Linux VS Code Server and running it through FreeBSD's Linuxulator, with an update helper script. No nullfs mounts.
---

# Set Up VS Code Remote-SSH for FreeBSD

This skill configures VS Code Remote-SSH for a FreeBSD host. VS Code does not
list FreeBSD as a supported server platform and cannot auto-install on it. The
approach mirrors the Devin/Cascade setup: the SSH session stays in a **native
FreeBSD shell**, the client is told to treat the host as Linux, and the Linux
server build is installed manually by a helper script. FreeBSD runs the Linux
ELF binaries directly, so no Linuxulator chroot shell and no nullfs mounts are
needed.

## Requirements

- FreeBSD 14+ (64-bit) reachable over SSH, key authentication recommended
- Root (or sudo/doas) for the initial setup
- VS Code with the Microsoft Remote - SSH extension on the local machine
- Rocky Linux 9 userland (`emulators/linux_base-rl9`)

This is a community workaround, not an officially supported target. Some
extensions or Linux syscalls may not work under Linuxulator.

## 1. Enable Linuxulator on FreeBSD

```sh
sudo kldload linux64
sudo sysrc linux_enable="YES"
sudo service linux start
sudo pkg install -y linux_base-rl9
sudo service linux restart
```

`kldload` may report that `linux64` is already loaded; continue. `service
linux status` is not implemented (only start/stop/restart).

## 2. Install utilities

```sh
sudo pkg install -y bash curl jq flock perl5
```

Remote-SSH starts `bash` for its bootstrap script, so `bash` must be on the
PATH. The login shell may be anything (tested with fish); the helper script is
plain `sh`. Do NOT install
`node`/`npm`; the server bundles its own Linux Node.js.

## 3. Configure the local SSH alias

Use a plain alias. Do NOT add `RemoteCommand` or `RequestTTY`:

```sshconfig
Host freebsd-dev1
    HostName <ip-or-hostname>
    User admin
    IdentityFile <existing-private-key>
```

## 4. Configure VS Code (local machine)

Merge into User Settings JSON:

```json
{
  "remote.SSH.remotePlatform": {
    "freebsd-dev1": "linux"
  },
  "remote.SSH.useLocalServer": false,
  "remote.SSH.useExecServer": true,
  "remote.SSH.useFlock": false
}
```

`useExecServer` stays on because agent mode connects through it.
`remotePlatform` skips the `uname` platform check that rejects FreeBSD. Replace
`freebsd-dev1` with the actual alias. Merge; do not replace unrelated settings.


## 5. Install the uname and ldd shims

`remotePlatform` is client-side only. Remote-SSH still pipes its bootstrap
script into a bare `sh` on the host, and that script exits with `Unsupported
platform: FreeBSD` (exit code 203) unless `uname -s` prints `Linux` and
`uname -m` prints `x86_64` (FreeBSD prints `amd64`). The shim answers with the
Linux `uname` (a Linux ELF that runs natively) only when its parent process is a
bare `sh`; every other caller gets the real FreeBSD `uname`, so builds and
terminals are unaffected.

Install `scripts/vscode-uname-shim.sh` and put its directory first in PATH for
non-interactive SSH commands:

```sh
mkdir -p ~/.local/share/vscode-shim
install -m 755 vscode-uname-shim.sh ~/.local/share/vscode-shim/uname
install -m 755 vscode-ldd-shim.sh ~/.local/share/vscode-shim/ldd
```

The second shim, `scripts/vscode-ldd-shim.sh`, is needed because the VS Code CLI
runs `ldd --version` to choose between glibc and musl. FreeBSD's `ldd` does not
print a glibc version, so the CLI fails with exit code 207 (`find
/lib/ld-musl-x86_64.so.1, which is required ... in musl environments`). When the
caller is the VS Code CLI, the shim runs the Linux `ldd` through the Linux
bash; all other callers get FreeBSD's `ldd`.

- fish login shell: create `~/.config/fish/conf.d/10-vscode-shim.fish` with
  `fish_add_path --path --prepend $HOME/.local/share/vscode-shim`
- bash login shell: add `export PATH="$HOME/.local/share/vscode-shim:$PATH"`
  at the top of `~/.bashrc`, above any interactive-shell guard

The Agents window runs its own platform probe, `uname -s` and `uname -m` as
separate SSH exec commands, and fails with `Unsupported remote platform:
FreeBSD amd64` otherwise (see `renderer.log` under
`%APPDATA%\Code\logs\<session>\window*\`). Those calls have a parent of
`<login shell> -c uname -s|-m`, which the shim also answers as Linux.

A pre-existing `~/.local/bin/uname` that only fakes `-sm` (for Devin) does not
satisfy VS Code, which calls `uname -s` and `uname -m` separately. Leave it in
place; the shim directory takes precedence.

Verify (expect `Linux x86_64 64`, then `Linux`, `x86_64`, then `FreeBSD amd64`):

```sh
printf 'echo "$(uname -s) $(uname -m) $(getconf LONG_BIT)"\n' | ssh -T freebsd-dev1 sh
ssh freebsd-dev1 'uname -s'; ssh freebsd-dev1 'uname -m'
ssh freebsd-dev1 "sh -c 'uname -s; uname -m'"
```

## 6. Install the update helper script

Install `scripts/update-vscode-server.sh` as `~/bin/update-vscode-server` on
the FreeBSD host and make it executable:

```sh
mkdir -p ~/bin
# copy the script, then:
chmod 755 ~/bin/update-vscode-server
```

The script uses the VS Code update API
(`https://update.code.visualstudio.com/api/versions/commit:<commit>/server-linux-x64/stable`)
for the exact URL, version and SHA-256, installs into
`~/.vscode-server/bin/<commit>/`, links
`~/.vscode-server/cli/servers/Stable-<commit>/server` when that placeholder
exists, writes remote telemetry-off settings (only if absent), and patches the
extension host's `navigator` migration guard (backup kept as
`.bak-navigator`).

Workflow after installing or upgrading the VS Code client:

1. Click Connect in VS Code (it fails and leaves a placeholder directory).
2. On the host run `update-vscode-server` (`-f` to reinstall, or pass a commit
   from Help > About).
3. Reconnect.

## 7. Verify

```sh
~/.vscode-server/bin/<commit>/bin/code-server --version
ps -axww -o pid,ppid,stat,command | grep -E 'type=agentHost|copilot-runtime'
```

## Troubleshooting

- **`SQLITE_READONLY_DBMOVED` / `sendMessage for unknown chat` / `Session history
  cannot be recovered` in the Agents window**: leftover state from the old
  nullfs/chroot setup. Linux processes under Linuxulator resolve a path in
  `/compat/linux` first, so a stale `/compat/linux/home/<user>/.vscode-server`
  or `.copilot` tree splits the same path across two filesystems, and deleting
  it while the agent host runs leaves SQLite with moved files. Unmount any
  nullfs mounts and remove those directories and their `/etc/fstab` entries,
  then restart the agent host (`pkill -f 'type=agentHost'`; the server respawns
  it) and start a new chat. Old chats are not recoverable.

- **`Waiting for server log...` forever / `Unable to connect to remote agent
  host`**: a leftover `RemoteCommand` (Linuxulator chroot bash) in the local SSH
  config. It makes the bootstrap write to `/compat/linux/home/<user>` while
  the native binaries use `/home/<user>`. Delete `RemoteCommand` and
  `RequestTTY` from the alias, and remove stale `enableRemoteCommand` /
  `useLocalServer: true` settings.

- **`exitCode==207` / `expected either... ld-musl-x86_64.so.1`**: the ldd shim
  from Step 5 is missing, not executable, or not first in PATH.
- **`Unsupported platform: FreeBSD` / `exitCode==203`**: the uname shim from
  Step 5 is missing, not first in PATH for non-interactive SSH, or not
  executable. Run the Step 5 verification.
- **Waiting for server log / install loops**: check the placeholder exists,
  run the helper script, and confirm `bash` is the login shell. Ensure no
  `RemoteCommand` remains in the SSH config.
- **Server fails to start**: confirm `service linux start` ran and
  `/compat/linux/usr/bin/bash` exists; run the `code-server --version` check.
- **Extension host exits with code 7**: check
  `~/.vscode-server/data/logs/*/exthost*/remoteexthost.log`. For
  `PendingMigrationError`, rerun `update-vscode-server -f`. For telemetry
  failures, confirm `~/.vscode-server/data/Machine/settings.json` exists.
- **Linuxulator warnings in dmesg** (`syscall io_uring_setup not implemented`,
  unsupported prctl/ioctl): usually harmless; investigate only if they coincide
  with a failure.
