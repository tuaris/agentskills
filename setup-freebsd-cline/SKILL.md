---
name: setup-freebsd-cline
description: Sets up Cline Desktop (the standalone Cline app) for remote development against a FreeBSD host over SSH with one idempotent script - it extends the vscode skill's uname shim so the app's platform probe passes, builds the open-source CLI/Hub natively with Bun, re-stamps the ELF ABI tag to the host's __FreeBSD_version, and stages the native binary over the helper the app actually executes (the Zed-skill pattern). The Linuxulator remains a fallback
---

# Set Up Cline Desktop Remote Access on a FreeBSD Host

Cline Desktop (the standalone app, https://cline.bot/desktop) has a native SSH
remote mode: add a host under Settings -> Remote, pick it from the
environment selector, and every session runs on that host - file edits,
terminal commands, Git, and MCP servers all execute there while chat,
approvals, and live output stay in the app on your computer.

On first connect the app copies a self-contained helper binary
(`cline-x86_64-unknown-linux-gnu`, ~160 MB in 0.0.49) to `~/.cline/remote/`
on the host, starts it, and tunnels it with `ssh -L` to a random local port.
No packages, no root, no open ports, and nothing on the host is exposed to
the network.

Cline Desktop's documented remote hosts are Linux (x64/arm64) and macOS. A
FreeBSD host works with two adaptations:

1. **The platform probe must say Linux.** On connect the app runs, through
   plain ssh,

   ```sh
   sh -c 'printf "\0CLINE_REMOTE_INSPECT_V1\0%s\0%s\0%s\0" "$(uname -s)" "$(uname -m)" "$HOME"'
   ```

   and accepts only `Linux` or `Darwin` as the system (the arch check accepts
   FreeBSD's `amd64` natively). The uname shim from the
   `setup-freebsd-vscode` skill (`~/.local/share/vscode-shim/uname`, first in
   PATH for non-interactive SSH) already answers Linux for VS Code, Agents
   window, Zed, and Devin probe patterns; this skill's script extends it with
   the `CLINE_REMOTE_INSPECT_V1` pattern (backing up the original first).
   Every other caller still gets the real FreeBSD uname.
2. **The helper is a Linux glibc binary.** It needs at most GLIBC_2.17, so
   the Linuxulator userland from the vscode/cascade skills
   (`linux64` + `linux_base-rl9`, glibc 2.34) runs it fine. The app launches
   it through `/bin/bash`, which does not exist on stock FreeBSD: a
   `/bin/bash -> /usr/local/bin/bash` symlink (the native bash port) is
   required, and it is what lets the native bash exec the Linux ELF, which
   then runs under the Linuxulator.

After that, everything is standard: the helper starts a Cline Hub bound to
the host's loopback, the app forwards it over the SSH tunnel, tool execution
and session storage happen on the host (`~/.cline/data/remote/`), and the
agent's terminal commands run in the host's login shell (native FreeBSD -
`pkg`, `doas`, `sysrc` all work). A Cline CLI already running on the same
account is left untouched; the desktop's helper uses its own isolated hub.

**Recommended: build the helper natively (Step 1 does this).** The
Linuxulator's path redirection between the native tree and `/compat/linux`
causes problems for some file reads/writes by the Linux helper. The Cline CLI
and Hub are open source (Apache-2.0, `github.com/cline/cline`, `apps/cli` +
`apps/cline-hub`; CLI releases are tagged `cli-v<version>`), and they are
compiled with Bun, which publishes official FreeBSD builds - so the helper
can be built natively on the host, the same pattern as
`setup-freebsd-zed-remote`. The Linuxulator path above remains a fully
working fallback (and is still what the app does by default).

## Requirements

- FreeBSD 14+ (64-bit) host. The Linuxulator (`linux64` + `linux_base-rl9`,
  from the `setup-freebsd-vscode` or `setup-freebsd-cascade` skill) is only
  needed for the app's own Linux helper fallback and for the other remote
  setups - the native path in this skill needs neither the kernel module nor
  `/compat/linux` to satisfy the probe.
- The vscode skill's uname shim at `~/.local/share/vscode-shim/uname`, first
  in PATH for non-interactive SSH (the fish `conf.d/10-vscode-shim.fish`
  hook, or a bash equivalent). The script installs/extends it itself.
- Key-based SSH login that needs no prompts, with the host key already
  trusted (Cline runs ssh with `BatchMode=yes StrictHostKeyChecking=yes` and
  can never answer a prompt)
- For the native build: `git`, `curl`, `perl`, and **bun 1.4+ (native
  FreeBSD build)**, plus ~3 GB of free space for the source tree and
  `node_modules` (keep it on a roomy dataset; `/` on freebsd-dev1 is tight)
- Cline Desktop on the local machine (macOS, Windows, or Linux)

## Step 1: Run the single setup script (on the FreeBSD host)

Install `scripts/setup-freebsd-cline-remote.sh` as
`~/bin/setup-freebsd-cline-remote` and run it:

```sh
mkdir -p ~/bin
install -m 755 scripts/setup-freebsd-cline-remote.sh ~/bin/setup-freebsd-cline-remote
~/bin/setup-freebsd-cline-remote          # auto-detect the version
~/bin/setup-freebsd-cline-remote 3.0.74   # pin an exact CLI version (Zed-style)
```

It does everything, idempotently, in one pass:

1. **Host prerequisites** - `/bin/bash -> /usr/local/bin/bash` (the app
   launches the helper through bash), the extended uname shim (the
   `CLINE_REMOTE_INSPECT_V1` pattern plus the VS Code/Agents/Zed/Devin
   patterns, with a static `Linux`/`x86_64` fallback when `/compat/linux` is
   absent), the fish `conf.d` PATH hook, and a live self-ssh probe that must
   parse as `Linux/x86_64`.
2. **Native build** - resolves the CLI version (auto-detected from the helper
   Cline Desktop staged in `~/.cline/remote/`, falling back to the newest
   `cli-v*` tag on GitHub), checks out `github.com/cline/cline` at that tag
   into `~/Documents/Code/cline-cli` (override with `CLINE_SRC_DIR`), applies
   the three local-only build patches, and builds with the repo's own
   pipeline (`apps/cli/script/build.ts --single`, target
   `bun-freebsd-x64`), which also runs the repo's native smoke tests.
3. **ABI fix** - re-stamps `NT_FREEBSD_ABI_TAG` in the built ELF from Bun's
   14.3 toolchain value to the host's `kern.osreldate` (1501000 on 15.1), so
   `file` reports "for FreeBSD 15.1" and the artifact matches the system it
   was built and runs on. See "About the ABI stamp" below.
4. **Staging (the Zed-skill pattern)** - replaces the helper the app actually
   executes, `~/.cline/remote/cline-linux-x64-<sha256:16>`, with the native
   binary (atomic rename, so a running helper is never truncated), keeping
   the app's Linux ELF as `*.linux-elf`.
5. **Verification** - every staged helper must be a FreeBSD ELF reporting
   the exact version and the ABI stamp, then the app's exact `hub ensure`
   launch command is run and the loopback hub must come up before it is
   stopped again.

Flags: `-f/--force` rebuild, `--host`/`--user` for the probe target,
`--abi N` to override the stamp, `--build-only` to stop after the build, and
`--restore-linux` to put the app's Linux helpers back (rollback).

### Why staging by hash name matters

Cline Desktop resolves the helper on the **client** machine
(`CLINE_REMOTE_HELPER_BINARY`, then `CLINE_REMOTE_HELPER_DIRECTORY`, then
`<app exec dir>/remote-helpers/cline-<platform-arch>`), hashes it, and
uploads it to the remote as
`~/.cline/remote/cline-<platform>-<arch>-<sha256[0:16]>`. On reconnect,
`installHelper()` skips the upload when that exact path already exists and is
executable - which is what makes swapping in the native binary stick.

A native binary dropped at
`~/.cline/remote/cline-x86_64-unknown-linux-gnu` (the client-side lookup name)
is **inert**: the app never executes that path. Earlier versions of this
skill staged there and silently kept running the Linux helper.

### About the ABI stamp

`bun build --compile` appends the bundle to a copy of the Bun executable, so
the ELF note (`NT_FREEBSD_ABI_TAG`) and the build ID come from Bun's published
FreeBSD runtime, which is linked on FreeBSD 14.3. Nothing in the runtime is
14.3-specific (FreeBSD keeps backward compatibility, and the kernel and
`ld-elf.so` ignore the note), but the artifact's metadata said "for FreeBSD
14.3" on this 15.1 host. The script rewrites the 4-byte note value after the
build and verifies it with `elfdump`. A 15.1-stamped Bun (for example
`lang/bun` from the ports tree, built locally) would make the re-stamp
unnecessary - point `bun` at it and the note will already match.

## Step 2: Add the host in Cline Desktop

1. Settings -> Remote -> add the host (name, host name, user, port; leave
   the identity file blank to let SSH choose, or point it at the key).
2. Pick the host in the environment selector next to the workspace picker
   and start a session. First connect uploads the helper (one-time, ~160 MB)
   and starts the hub; the Environment status panel shows the SSH client's
   own error if anything fails.

## Verify

- Environment status panel is healthy and a session starts on the remote.
- On the host, the helper that is *running* must be the native one:
  `ps -axww -o pid,command | grep cline-linux-x64 | grep -v grep` shows
  `~/.cline/remote/cline-linux-x64-<sha256:16> ... hub ...`. If the process
  predates the staging, disconnect and reconnect Cline Desktop - a running
  helper keeps its old inode.
- `file ~/.cline/remote/cline-linux-x64-*` reports "for FreeBSD 15.1", and
  `elfdump -n <helper> | grep NT_FREEBSD_ABI_TAG` reports the same number as
  `sysctl -n kern.osreldate` (1501000 on 15.1-RELEASE).
- `sockstat -l | grep 127.0.0.1` shows the hub bound to loopback only.
- Have the agent run `echo ok && uname -s` - the command executes in the
  host's native login shell (FreeBSD).

## Updating

- **Cline Desktop updated locally:** on the next connect the app uploads its
  own Linux helper again, under a new hash name - that **replaces the native
  helper for the new version**. Re-run `setup-freebsd-cline-remote` with no
  arguments: it auto-detects the new version from the staged helper, rebuilds
  if needed, re-stamps the ABI, and re-stages. Then disconnect/reconnect.
- **ABI stamp after a host upgrade:** re-run with `-f` (or `--abi N`); the
  default stamp is always the host's current `kern.osreldate`.
- **Rollback:** `--restore-linux` puts every `*.linux-elf` backup back and
  exits (the app's own helper runs again, under the Linuxulator).
- **Host-side repairs** (reboot, `/bin/bash` gone, shim overwritten): the same
  script repairs in place and re-verifies the probe; `--build-only` skips the
  staging step if you only want a build.
- The extended shim keeps the original VS Code/Agents/Zed/Devin patterns, so
  the other remote setups keep working.

## Troubleshooting

- **"Remote target ... is unsupported"** (probe passed or not): the inspect
  payload did not parse as Linux/x64. Run the script's probe step (it
  prints the raw payload). Usual causes: shim missing or not first in PATH
  for non-interactive SSH (check the fish `conf.d` hook), or the shim
  missing the `CLINE_REMOTE_INSPECT_V1` pattern (script reinstalls it).
- **Helper fails to start / `No such file or directory` after upload:**
  missing `/bin/bash` symlink (the script creates it). If the *Linux*
  fallback helper is what runs, also check the Linuxulator
  (`kldstat | grep linux64`) and `/compat/linux`. Check `dmesg` for `linux:`
  warnings; the usual ones (io_uring_setup, prctl, TIOCGPTPEER) are harmless.
- **`Timed out after 15000ms waiting for detached hub startup`:** the hub
  daemon died while starting; the actual error is at the end of
  `~/.cline/data/logs/hub-daemon.log`. The script's live check runs the app's
  exact launch command and reproduces it. Common cause: a stale discovery
  record or lock in `~/.cline/data/remote/` from a crashed run - remove the
  stale files and retry.
- **The app still runs the Linux helper after a successful run:** the running
  process keeps its old inode - disconnect and reconnect in Cline Desktop.
  If a *new* hash-named helper appears afterwards, the app updated and
  re-uploaded; re-run the script.
- **`file` still says "for FreeBSD 14.3":** an older native build is staged
  (before the ABI stamp existed). Re-run with `-f`.
- **Native helper works but the app reports an environment error after an
  update:** version skew - the staged native binary must match the app's CLI
  version; re-run the script (it reads the version from the staged helper).
- **`Permission denied (publickey)` / `Host key verification failed`:**
  Cline cannot answer prompts; fix key auth and trust the host key from a
  terminal first (`ssh user@host`).
- **Passphrase-protected key:** load it into the SSH agent on the desktop
  machine; Cline never asks for passphrases.
- **Model/egress problems:** the agent and MCP servers run on the host, so
  model traffic leaves from the FreeBSD host; test with
  `curl -sI https://<provider-host>`.

## Caveats

- One host at a time in Cline Desktop; switching hosts disconnects the
  current one. If the network drops, the tunnel closes after ~45 seconds.
- The `/bin/bash` symlink points at the native bash port
  (`/usr/local/bin/bash`); upgrading or removing that port breaks the
  helper launch - re-run the script if you change it.
- The native helper is built for the hub/remote path only: the interactive
  `cline` TUI is not available in the native build (OpenTUI publishes no
  FreeBSD native bindings), which does not affect Cline Desktop remote
  sessions. The native binary reports `platform: freebsd` in its hub
  response; the app does not validate that field (it only checks the
  inspect probe), so this is harmless.
- The ABI stamp is metadata: `bun build --compile` embeds Bun's published
  FreeBSD runtime, and that runtime is linked on 14.3. Re-stamping the
  `NT_FREEBSD_ABI_TAG` note makes the artifact say "for FreeBSD 15.1" and
  keeps packaging/tooling honest, but it does not re-link Bun itself. Bun's
  FreeBSD builds are backward-compatible, so this is the correct artifact
  for a 15.1 host; if a locally built 15.1 Bun (`lang/bun` from ports) is
  used, the note already matches and no stamp change is needed.
- If the native build is unavailable, nothing is broken: the app's Linux
  helper + Linuxulator + `/bin/bash` remains the fallback, and
  `--restore-linux` returns to it.
- This skill does not touch the Devin (`~/.devin-server`), Zed
  (`~/.zed_server`), or OpenCode setups; it only extends the vscode skill's
  uname shim additively (backup kept) and adds `/bin/bash`.
