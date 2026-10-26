---
name: setup-freebsd-cline
description: Sets up Cline Desktop (the standalone Cline app) for remote development against a FreeBSD host over SSH - the host passes the app's Linux platform probe via the vscode skill's extended uname shim, and the app's bundled Linux helper runs under the Linuxulator. Includes an idempotent host setup/update script
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

## Step 2: Add the host in Cline Desktop

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
- Have the agent run `echo ok && uname -s` - the command executes in the
  host's native login shell (FreeBSD).

## Updating

- **Cline Desktop updated locally:** the helper is versioned with the app;
  the next connect uploads and uses the new helper automatically (cached per
  Cline version). If the connect fails afterwards, run
  `setup-cline-remote-host.sh`, or `setup-cline-remote-host.sh
  --refresh-helper` to force a re-upload on the next connect.
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
- This skill does not touch the Devin (`~/.devin-server`), Zed
  (`~/.zed_server`), or OpenCode setups; it only extends the vscode skill's
  uname shim additively (backup kept) and adds `/bin/bash`.
