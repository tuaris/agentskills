---
name: setup-freebsd-qoder
description: Configure Qoder Desktop (the standalone Qoder app) remote SSH to a FreeBSD host. Qoder auto-installs a Linux remote runtime (Node.js host + worker) on connect; this skill prepares the host with the Linuxulator (Rocky 9) and three additive shims (uname, getconf, mv) so the bootstrap accepts FreeBSD, without breaking Devin, VS Code, Cline, OpenCode, or Zed. Includes an update/repair helper for the runtime.
---

# Set Up Qoder Desktop Remote SSH for FreeBSD

Qoder Desktop has a built-in remote SSH mode: add a host under **Remote
connections**, connect, and every task runs on that host - file edits, terminal
commands, Git, and the agent all execute there while chat and approvals stay in
the app on your computer.

On connect, Qoder runs a bootstrap over plain SSH that **auto-installs a remote
runtime** into `~/.qoder/remote/protocol-v1/` on the host: a bundled Linux
Node.js (`bin/node`), a runtime host (`bin/qoder-runtime-host`), and a worker
(`bin/qoder-worker-runtime`). It then launches the host over the SSH connection
and tunnels its stdio protocol. No packages, no root, and no open ports are
needed on the host beyond what SSH already uses.

Qoder's documented remote targets are Linux (x64/arm64, glibc) and macOS. A
FreeBSD host is rejected by the bootstrap in three places, each fixed by a
small, caller-specific shim:

1. **`uname -s` reports `FreeBSD`.** The preflight exits 20 unless it reads
   `Linux`. Qoder runs its bootstrap scripts as `sh -s -- <args> .qoder`, so the
   shared uname shim gains one pattern for that parent.
2. **`getconf GNU_LIBC_VERSION` is unknown on FreeBSD.** The preflight exits 22
   unless it reads `glibc <version>`, and the runtime host re-checks it at
   startup. A getconf shim answers from the Linuxulator for Qoder callers only.
3. **The install scripts use GNU-only `mv -Tf`** for the atomic `current`
   symlink swap; BSD mv rejects `-T`. An mv shim routes `-T` to the
   Linuxulator's GNU mv.

The runtime itself is a set of Linux ELF binaries, so it runs under the
FreeBSD **Linuxulator** (`linux64` + `linux_base-rl9`, Rocky 9, glibc 2.34).
The agent's terminal commands run in the host's native login shell (FreeBSD -
`pkg`, `doas`, `sysrc` all work), exactly like the Devin setup.

**Coexistence is guaranteed by construction.** The shims live in the same
`~/.local/share/vscode-shim/` directory the VS Code and Cline skills use. The
uname shim is a *superset* of the existing one (every Devin/VS Code/Cline/Zed
pattern is preserved); getconf and mv are new and pass every non-Qoder caller
straight through to the real FreeBSD tool. Nothing in `~/.devin-server`,
`~/.vscode-server`, `~/.cline`, `~/.zed_server`, or the OpenCode install is
touched.

**Verified state (2026-11-11, FreeBSD 15.1-RELEASE-p2):** runtime **0.5.7**
(protocol 1.29, worker 1.1.79-hotfix.19, Node 22.23.2) installs and serves on
a FreeBSD 15.1 host; the preflight reports `linux/x64/glibc 2.34` and the runtime
host emits its `QODER-REMOTE-HOST/1` handshake under the Linuxulator.

## Requirements

- FreeBSD 14+ (64-bit) host reachable over SSH. Tested on 15.1-RELEASE.
- Root via `doas` for the one-time setup (kernel module, packages, `/bin/bash`).
- Qoder Desktop on the local machine (macOS, Windows, or Linux).
- Key-based SSH login that needs no prompts, with the host key already trusted
  (Qoder runs the system `ssh` with batch-mode options and cannot answer a
  passphrase or host-key prompt).
- The `setup-freebsd-vscode` or `setup-freebsd-cascade` skill is a helpful
  prerequisite (it sets up the Linuxulator and the shared shim directory), but
  this skill's script installs anything missing itself.

## Step 0: SSH key access (local machine)

Same as the Devin setup. From the machine running Qoder Desktop:

```sh
ssh-keygen -t ed25519 -C "qoder-remote"          # skip if you already have a key
ssh-copy-id <user>@freebsd-host                   # install the public key
```

Add a plain alias to `~/.ssh/config` (Qoder reads this file to list hosts). Do
NOT add `RemoteCommand` or `RequestTTY`:

```sshconfig
Host freebsd-host
    HostName <ip-or-hostname>
    User <user>
    IdentityFile ~/.ssh/id_ed25519
```

Verify non-interactive login works and the host key is trusted:

```sh
ssh -o BatchMode=yes freebsd-host 'echo ok'
```

## Step 1: Run the setup script (FreeBSD host)

Install `scripts/setup-freebsd-qoder-remote.sh` as
`~/bin/setup-freebsd-qoder-remote` and `scripts/update-qoder-runtime.sh` as
`~/bin/update-qoder-runtime`, then run the setup script:

```sh
mkdir -p ~/bin
install -m 755 scripts/setup-freebsd-qoder-remote.sh ~/bin/setup-freebsd-qoder-remote
install -m 755 scripts/update-qoder-runtime.sh ~/bin/update-qoder-runtime
~/bin/setup-freebsd-qoder-remote
```

It does everything, idempotently, in one pass:

1. **Prerequisites** - `bash`, `curl`, `jq`, `git` (installs any that are
   missing); loads `linux64` and installs `linux_base-rl9` if absent; creates
   the `/bin/bash -> /usr/local/bin/bash` symlink the runtime's terminal
   fallback needs.
2. **Shims** - installs/extends `uname`, `getconf`, and `mv` in
   `~/.local/share/vscode-shim/`, keeping a dated backup of any replaced file
   (`<shim>.bak-qoder-<date>`).
3. **PATH hook** - ensures the shim directory is first for non-interactive SSH
   (the fish `conf.d/10-vscode-shim.fish` hook, or a note for other shells).
4. **Live probe** - reproduces Qoder's exact platform check over self-ssh
   (`sh -s -- <id> .qoder`) and requires `Linux/x86_64/glibc`.

Flags: `--host H` / `--user U` to probe a different target (default
`localhost` as the current user).

The script does **not** install the runtime - Qoder does that on first connect.
To pre-seed it (instant first connect) or repair it, run `update-qoder-runtime`
(see Updating).

## Step 2: Add and connect the host in Qoder Desktop

1. Open the **Remote connections** panel ("Manage SSH hosts ... then create
   workspaces").
2. Click **Add** -> **Add SSH connection**. Qoder reads `~/.ssh/config` and
   lists the available connections; select the FreeBSD host alias, give it a
   display name, and add it.
3. Click **Connect**. On first connect Qoder runs the preflight, downloads the
   runtime (~80 MB), installs it, and launches the host. The status goes
   `Connecting` -> `Connected`.
4. Choose a remote workspace in a task. File edits, terminal commands, and the
   agent now run on the FreeBSD host.

If you pre-seeded with `update-qoder-runtime`, the download is skipped and the
connect is near-instant.

## Verify

- The Remote connections status is **Connected** (not "Connected - Thin SSH";
  Thin is a reduced fallback, see Troubleshooting).
- On the host, the installed runtime is present and version-checks:

  ```sh
  readlink ~/.qoder/remote/protocol-v1/current
  ~/.qoder/remote/protocol-v1/current/bin/qoder-runtime-host --version
  # {"version":"0.5.7","protocol":"1.29"}
  ~/.qoder/remote/protocol-v1/current/bin/qoder-worker-runtime --version
  # 1.1.79-hotfix.19
  ```

- The running host is the Linux runtime under the Linuxulator:

  ```sh
  ps -axww -o pid,command | grep runtime-host.cjs | grep -v grep
  ```

- Have the agent run `echo ok && uname -s` - it executes in the host's native
  login shell and prints `FreeBSD` (the shim only fakes the probe callers).

## Updating

- **Qoder Desktop updated locally:** on the next connect the client compares the
  installed runtime version against its own and auto-downloads/installs the new
  one. Nothing to do on the host. If the shims were overwritten by re-running
  another skill's setup, re-run `setup-freebsd-qoder-remote` first.
- **Pre-seed or repair the runtime:** `~/bin/update-qoder-runtime`. It fetches
  the same manifest the client uses, verifies checksums, and runs Qoder's own
  install logic (extract, smoke test, atomic swap, rollback on failure):

  ```sh
  ~/bin/update-qoder-runtime                 # install / reuse last version
  ~/bin/update-qoder-runtime -f              # force reinstall
  ~/bin/update-qoder-runtime --version 0.6.0 --commit <hash>   # a new client build
  ```

  The manifest is keyed by the client's runtime **version and commit** (there is
  no "latest" endpoint). The defaults match Qoder Desktop 0.5.7; the last-used
  pair is remembered in `~/.qoder/remote/protocol-v1/.runtime-manifest-state`.
- **Host-side repairs** (reboot, `/bin/bash` gone, shim overwritten): re-run
  `setup-freebsd-qoder-remote`; it repairs in place and re-verifies the probe.

## Coexistence with other IDEs and agents

This skill only **adds** to the shared host setup:

- The uname shim keeps every existing pattern (VS Code Remote-SSH bare `sh`,
  the Agents window `-c uname -s|-m`, Zed/Devin `-sm`, Cline
  `CLINE_REMOTE_INSPECT_V1`) and adds the Qoder `sh -s -- ... .qoder` pattern.
- getconf and mv are new shims; any caller that is not Qoder gets the real
  FreeBSD `getconf`/`mv`. `mv -T` never worked on BSD mv, so routing it to GNU
  mv cannot change any previously-working behavior.
- Nothing under `~/.devin-server`, `~/.vscode-server`, `~/.cline`,
  `~/.zed_server`, or the OpenCode install is read or written.

The one caveat (shared with the Cline skill): if you later re-run the VS Code
or Cline setup, those write their own uname shim *without* the Qoder pattern.
If Qoder then fails to connect, re-run `setup-freebsd-qoder-remote` to restore
it. Backups are always kept.

## Troubleshooting

- **Preflight exit 20 / "unsupported operating system":** the uname shim is
  missing the Qoder pattern or not first in PATH for non-interactive SSH. Re-run
  the setup script and check the fish `conf.d` hook.
- **Preflight exit 22 / "unsupported libc":** the getconf shim is missing or the
  Linuxulator userland is absent (`/compat/linux/usr/bin/getconf`). Re-run the
  setup script; confirm `linux_base-rl9` is installed.
- **Install step failed: `mv: illegal option -- T`:** the mv shim is missing or
  not first in PATH. Re-run the setup script.
- **Status "Connected - Thin SSH":** the client fell back to the reduced Thin
  mode (no terminal/agent). This happens when the full runtime bootstrap fails
  or `QODER_REMOTE_SSH_FORCE_THIN` is set. Check the host runtime with the
  Verify commands and re-run `update-qoder-runtime`; unset the env var.
- **Runtime host fails to start / glibc error:** confirm the Linuxulator is
  loaded (`kldstat | grep linux64`) and `/compat/linux` is populated. The
  bundled Node 22 needs glibc 2.28+; Rocky 9 provides 2.34. Do not substitute
  the CentOS 7 userland (glibc 2.17 is too old for Node 22).
- **`Permission denied (publickey)` / `Host key verification failed`:** Qoder
  cannot answer prompts; fix key auth and trust the host key from a terminal
  first (`ssh <user>@host`). Load passphrase-protected keys into the local SSH
  agent.
- **Terminal opens but commands fail with `/bin/bash: not found`:** the
  `/bin/bash` symlink is gone (the runtime falls back to it when `SHELL` is
  unset). Re-run the setup script.
- **Linuxulator warnings in dmesg** (`io_uring_setup`, unsupported `prctl`,
  `TIOCGPTPEER`): harmless, same as the Devin/VS Code setups. Investigate only
  if they coincide with a failure.
- **Stale `/compat/linux/home/<user>` tree:** if a previous chroot/nullfs setup
  left files there, Linux processes resolve that tree before the native home
  and split the runtime's state. Remove the stale tree (and any `/etc/fstab`
  nullfs entries); this skill never creates one.

## How it works

The client drives the whole install over SSH exec (login shell `-c` wrapper),
piping each script into `sh -s -- <args> .qoder`:

- **Preflight** checks `uname -s`/`-m`, `getconf GNU_LIBC_VERSION`, home
  writability, `tar`, a sha256 tool, `/dev/ptmx`, an exec-able runtime dir, and
  free disk; it reports the currently installed version and component checksums
  as hex-encoded JSON between `qoder-remote-bootstrap:<id>:start/end` markers.
- **Download** fetches each component into `cache/<sha256>.tar.gz` with `curl`
  (or `wget`), verifying size and checksum.
- **Install** takes a lock, extracts into a staging dir, re-verifies checksums,
  smoke-tests `qoder-runtime-host --version` and `qoder-worker-runtime
  --version`, atomically swaps the `current` symlink with `mv -Tf`, and rolls
  back to `previous` if the post-swap health check fails. It then GCs old
  installs and unreferenced cache entries.
- **Launch** runs
  `QODER_REMOTE_HOST_ID=<id> QODER_CONFIG_DIR_NAME=.qoder
  QODER_EXECUTION_HOST_KIND=ssh exec .../current/bin/qoder-runtime-host serve
  --stdio`. The launcher is a native `sh` script that execs the bundled Linux
  Node on `lib/runtime-host.cjs`; the host re-checks glibc via `getconf` and
  speaks the `QODER-REMOTE-HOST/1` stdio protocol.

The three shims map exactly onto the three FreeBSD blockers (uname, getconf,
mv). Because each shim answers only its specific parent process, the host
behaves as stock FreeBSD for everything else - which is why the other IDEs and
agents keep working unchanged.