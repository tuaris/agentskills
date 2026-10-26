---
name: setup-freebsd-cline
description: Sets up Cline Desktop (the standalone Cline app) for remote development against a FreeBSD host over SSH - the host passes the app's Linux platform probe via the vscode skill's extended uname shim, and the helper runs natively (built from the open source CLI/Hub with Bun) or under the Linuxulator. Includes idempotent host setup and native build/update scripts
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

**Recommended: build the helper natively (Step 2).** The Linuxulator's path
redirection between the native tree and `/compat/linux` causes problems for
some file reads/writes by the Linux helper. The Cline CLI and Hub are open
source (Apache-2.0, `github.com/cline/cline`, `apps/cli` + `apps/cline-hub`;
CLI releases are tagged `cli-v<version>`), and they are compiled with Bun,
which publishes official FreeBSD builds - so the helper can be built
natively on the host, the same pattern as `setup-freebsd-zed-remote`. The
Linuxulator path above remains a fully working fallback (and is still what
the app does by default).

## Requirements

- FreeBSD 14+ (64-bit) host with the Linuxulator enabled and
  `linux_base-rl9` installed (the `setup-freebsd-vscode` or
  `setup-freebsd-cascade` skill does this)
- The vscode skill's uname shim installed at
  `~/.local/share/vscode-shim/uname` and first in PATH for non-interactive
  SSH (the fish `conf.d/10-vscode-shim.fish` hook, or bash equivalent)
- Key-based SSH login that needs no prompts, with the host key already
  trusted (Cline runs ssh with `BatchMode=yes StrictHostKeyChecking=yes` and
  can never answer a prompt)
- Cline Desktop on the local machine (macOS, Windows, or Linux)

## Step 1: Run the host setup script (on the FreeBSD host)

Install `scripts/setup-cline-remote-host.sh` as `~/bin/setup-cline-remote-host`
and run it:

```sh
mkdir -p ~/bin
# copy the script, then:
chmod 755 ~/bin/setup-cline-remote-host
~/bin/setup-cline-remote-host
```

It is idempotent and safe to re-run; it does:

- verifies the `linux64` kernel module is loaded (tries `doas kldload`
  if not)
- creates the `/bin/bash -> /usr/local/bin/bash` symlink when missing
  (doas; refused if `/bin/bash` already exists as a real file)
- installs the extended uname shim (with the `CLINE_REMOTE_INSPECT_V1`
  pattern) over `~/.local/share/vscode-shim/uname`, backing up the previous
  copy, and checks the PATH hook exists
- runs the app's exact inspect probe over ssh and verifies the payload
  parses as Linux + x64
- if `~/.cline/remote/` already holds a helper, verifies it is an
  executable ELF

`--refresh-helper` additionally removes the staged helper so the next
Cline Desktop connect re-uploads it; `--host HOST --user USER` point the
probe at a specific target (default: self-ssh as the current user).

## Step 2: Build the native helper (on the FreeBSD host)

Install `scripts/build-cline-remote-helper.sh` as `~/bin/build-cline-remote-helper`
and run it:

```sh
~/bin/build-cline-remote-helper              # auto-detect version
~/bin/build-cline-remote-helper 3.0.74       # pin an exact version (Zed-style)
~/bin/build-cline-remote-helper -f           # force a rebuild
```

Version handling, both styles:

- **Auto-detect (Devin-style, default):** reads the version from the helper
  Cline Desktop has staged in `~/.cline/remote/` (the app uploads one on
  connect), so the native build always tracks what the app ships. If no
  helper is staged yet, it falls back to the newest `cli-v*` release tag on
  GitHub (with a warning).
- **Pin (Zed-style):** pass the exact CLI version to build.

What it does (idempotent, safe to re-run):

- resolves the version and checks whether that version is already staged as
  a native binary (skips the build if so; `-f` forces a rebuild)
- checks out `cli-v<version>` from `github.com/cline/cline` into
  `~/Documents/Code/cline-cli` (or `CLINE_SRC_DIR` if the root filesystem is
  tight; needs ~3 GB for source + node_modules)
- applies three local-only patches to the build tree: adds `freebsd` to the
  compile target matrix, installs deps with `--ignore-scripts` (grpc-tools,
  an SDK dev dependency, has no FreeBSD build and none of its output is
  needed), and swaps the webview's `@vitejs/plugin-react-swc` for the
  babel-based `@vitejs/plugin-react` (`@swc/core` publishes no FreeBSD
  bindings)
- builds with the repo's own pipeline (`apps/cli/script/build.ts --single`),
  which runs the repo's own native smoke tests: the binary must report the
  exact version and pass a hub start/status/stop cycle in an isolated HOME
- stages the result as `~/.cline/remote/cline-x86_64-unknown-linux-gnu`
  (the exact name the app derives from the probed platform), keeping the
  previous Linux helper as `cline-x86_64-unknown-linux-gnu.linux-elf`
- runs a live `hub ensure` / `hub stop` with the app's exact launch command
  and verifies the loopback endpoint answers

Native prerequisites: `git`, `curl`, `bun` 1.4+ (native FreeBSD build), and
the Step 1 prerequisites (`/bin/bash`, the uname shim - the app's probe
still decides which helper filename to use, so the shim stays either way).

## Step 3: Add the host in Cline Desktop

1. Settings -> Remote -> add the host (name, host name, user, port; leave
   the identity file blank to let SSH choose, or point it at the key).
2. Pick the host in the environment selector next to the workspace picker
   and start a session. First connect uploads the helper (one-time, ~160 MB)
   and starts the hub; the Environment status panel shows the SSH client's
   own error if anything fails.

## Verify

- Environment status panel is healthy and a session starts on the remote.
- On the host: `ps -axww -o pid,stat,command | grep cline-x86_64 | grep -v grep`
  shows the helper running a loopback hub, and
  `sockstat -l | grep 127.0.0.1` shows it bound to loopback only.
- `file ~/.cline/remote/cline-x86_64-unknown-linux-gnu` shows "FreeBSD" for
  the native build (or "Linux" for the app's default helper).
- Have the agent run `echo ok && uname -s` - the command executes in the
  host's native login shell (FreeBSD).

## Updating

- **Cline Desktop updated locally:** the helper is versioned with the app;
  the next connect uploads and uses the official Linux helper automatically
  (cached per Cline version) - this **overwrites a staged native helper**.
  To restore the native build for the new version, run
  `build-cline-remote-helper.sh` with no arguments (it auto-detects the
  version from the freshly staged helper) or pin it explicitly.
- **Native helper maintenance:** re-run `build-cline-remote-helper.sh`
  (idempotent; skips the build when the version is already staged, `-f`
  forces). Point `CLINE_SRC_DIR` at a roomier dataset if the build tree
  grows too large for `/`.
- **Host-side repairs** (reboot dropped the module, `/bin/bash` gone, shim
  overwritten): re-run `setup-cline-remote-host.sh`; it repairs in place and
  re-verifies the probe.
- The extended shim keeps the original VS Code/Agents/Zed/Devin patterns, so
  the other remote setups keep working.

## Troubleshooting

- **"Remote target ... is unsupported"** (probe passed or not): the inspect
  payload did not parse as Linux/x64. Run the script's probe step (it
  prints the raw payload). Usual causes: shim missing or not first in PATH
  for non-interactive SSH (check the fish `conf.d` hook), or the shim
  missing the `CLINE_REMOTE_INSPECT_V1` pattern (script reinstalls it).
- **Helper fails to start / `No such file or directory` after upload:**
  missing `/bin/bash` symlink (script creates it) or the Linuxulator not
  loaded (`kldstat | grep linux64`; script loads it). Check `dmesg` for
  `linux:` warnings; the usual ones (io_uring_setup, prctl, TIOCGPTPEER)
  are harmless.
- **`Timed out after 15000ms waiting for detached hub startup`:** the hub
  daemon died while starting; the actual error is at the end of
  `~/.cline/data/logs/hub-daemon.log`. The app's exact launch command
  (what `build-cline-remote-helper.sh` runs in its live check) reproduces
  it. Common cause: a stale discovery record or lock in
  `~/.cline/data/remote/` from a crashed run - remove the stale files and
  retry.
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
- This skill does not touch the Devin (`~/.devin-server`), Zed
  (`~/.zed_server`), or OpenCode setups; it only extends the vscode skill's
  uname shim additively (backup kept) and adds `/bin/bash`.
