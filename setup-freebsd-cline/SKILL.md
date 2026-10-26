---
name: setup-freebsd-cline
description: Sets up Cline (the VS Code AI coding agent extension, marketplace ID saoudrizwan.claude-dev) to run on a FreeBSD host over Remote-SSH, with a helper script to install and update the Cline extension on the remote VS Code server
---

# Set Up Cline Remote Access on a FreeBSD Host

Cline is a VS Code extension (marketplace ID `saoudrizwan.claude-dev` — the
display name is "Cline" but the ID kept its old Claude Dev name). It runs in
VS Code's remote extension host, so the FreeBSD host work splits in two:

1. **VS Code remote server on FreeBSD.** Done by the separate
   `setup-freebsd-vscode` skill (Linux REH server under the Linuxulator,
   uname/ldd shims, `update-vscode-server`). This skill does not touch that
   layer.
2. **The Cline extension itself.** Cline is pure JavaScript with no native
   binaries, so — unlike `setup-freebsd-zed-remote` or `setup-freebsd-cascade`
   — there is no FreeBSD build or patch. The Linux extension host reports
   `process.platform === "linux"`, so all of Cline's Linux code paths run
   as-is. What remains is installing the extension into the remote server,
   keeping it in sync with the local client, and a few FreeBSD runtime facts
   (which shell Cline's commands run in, where its state lives).

## Requirements

- FreeBSD 14+ (64-bit) host where `setup-freebsd-vscode` is already applied
  (Linux REH server installed and shims in place)
- VS Code remote server **1.101.0 or newer** (Cline's `engines.vscode` is
  `^1.101.0`). Check with
  `jq -r .version ~/.vscode-server/bin/<commit>/product.json`
- Local machine with VS Code + Remote - SSH configured per the vscode skill
- `curl`, `jq`, `unzip`, `flock` on the FreeBSD host (installed by the vscode
  skill or its siblings)

## Step 1: Local VS Code client

1. Connect to the host per `setup-freebsd-vscode` (`remote.SSH.remotePlatform`,
   `useExecServer`, shims, ...).
2. Install Cline in the local client:

   ```sh
   code --install-extension saoudrizwan.claude-dev
   ```

   Searching the marketplace for "Cline" shows the display name; the
   extension ID is still the old Claude Dev one
   (`https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev`).

Do not rely on the client to auto-install Cline on the remote; install it
deterministically on the host with the helper script (Step 2).

## Step 2: Install the update helper script (on the FreeBSD host)

Install `scripts/update-cline-remote.sh` as `~/bin/update-cline-remote` and
run it:

```sh
mkdir -p ~/bin
# copy the script, then:
chmod 755 ~/bin/update-cline-remote
~/bin/update-cline-remote
```

What the script does:

- Detects the newest installed `~/.vscode-server/bin/<commit>/` (or takes a
  commit as an argument)
- Verifies the server's `product.json` version satisfies Cline's
  `^1.101.0` engine requirement
- Resolves the latest stable Cline version from Open VSX
  (`https://open-vsx.org/api/saoudrizwan/claude-dev`)
- Downloads the VSIX
  (`https://open-vsx.org/api/saoudrizwan/claude-dev/<ver>/file/saoudrizwan.claude-dev-<ver>.vsix`)
  and checks zip integrity
- Installs it with the server's own
  `code-server --install-extension`, which is what registers it in
  `~/.vscode-server/extensions/extensions.json`
- Re-runs are idempotent: if the latest version is already installed it exits
  with "up to date"

Usage: `update-cline-remote [-f] [--version VER] [--vsix FILE] [COMMIT]`

Why Open VSX instead of the VS Code Marketplace: Cline is open source
(github.com/cline/cline) and publishes to both registries. The marketplace's
direct VSIX endpoint 404s when hit from this network, while Open VSX offers a
plain API plus file URLs. If Open VSX is ever unreachable, download the VSIX
in a browser and pass it with `--vsix`.

## Step 3: Configure Cline on the remote

Cline creates `~/.cline/` on first activation (plain FreeBSD files — the
Linux node writes them natively, no `/compat/linux` involvement):

- MCP server config: `~/.cline/data/settings/cline_mcp_settings.json`
  (holds tokens; keep mode 600)
- Task history and other state: under `~/.cline/data/`

Open the Cline panel (side-bar icon) in a remote window and sign in /
configure a model provider. API keys are stored per Cline instance: the remote
instance has its own separate from any local one. If you use MCP servers on
both, replicate the config file onto the host (it contains secrets).

## FreeBSD runtime facts (no action needed, but know them)

- **Cline's commands run in the remote login shell.** The extension host
  inherits the SSH session environment, so the integrated terminal resolves
  `$SHELL` (fish on this host). `pkg`, `doas`, `sysrc` etc. work natively; no
  Linux bash is involved in Cline command execution.
- **git is native FreeBSD** (`/usr/local/bin/git`) via the session PATH, so
  Cline's checkpoint/commit features use the host's git identity.
- **Cline's code search uses the ripgrep bundled with the VS Code server**
  (the `@vscode/ripgrep-universal` linux-x64 ELF under the server's
  `node_modules/`), not the system `rg`. `pkg install ripgrep` is optional,
  for interactive terminals.
- **Model traffic goes from the FreeBSD host directly** to whatever provider
  Cline is configured with; egress must be allowed.

## Verify

```sh
~/.vscode-server/bin/<commit>/bin/code-server --list-extensions \
  --extensions-dir ~/.vscode-server/extensions \
  --user-data-dir ~/.vscode-server/data | grep claude-dev
ls -d ~/.vscode-server/extensions/saoudrizwan.claude-dev-*
```

Then from the local VS Code: connect to the remote, confirm the Cline icon in
the side bar, start a session, and have it run a trivial command (`echo ok`).
That first command confirms terminal, git, and PATH all resolve to native
FreeBSD.

## Updating

- **Cline extension updated in the local client:** run `update-cline-remote`
  on the host (installs the newest stable), then reconnect or reload the
  remote window.
- **VS Code client itself updated:** run `update-vscode-server` first (new
  commit placeholder), then `update-cline-remote`; it installs into the
  newest server commit.
- `code-server --install-extension` replaces the old version in place. Stale
  `saoudrizwan.claude-dev-*` directories under `~/.vscode-server/extensions/`
  can be removed manually if disk space matters.

## Troubleshooting

- **Script: "VS Code server too old (need >= 1.101.0)"**: run
  `update-vscode-server` with the current client commit first.
- **No Cline icon in the remote window:** check the extension host log under
  `~/.vscode-server/data/logs/`; confirm
  `saoudrizwan.claude-dev` appears in `--list-extensions`; make sure the
  server version satisfies `engines.vscode`.
- **Cline cannot reach the model provider:** host egress problem; test with
  `curl -sI https://<provider-host>`.
- **`--install-extension` rejects the VSIX:** the script verifies with
  `unzip -t` before installing; if you pass a browser-downloaded file with
  `--vsix`, make sure the download completed (HTML error pages are the usual
  culprit).
- **Cline commands run in the wrong shell:** Cline uses the default terminal
  profile. If `~/.vscode-server/data/Machine/settings.json` sets a custom
  `terminal.integrated.defaultProfile.linux`, point it at a native FreeBSD
  shell (`/usr/local/bin/fish`, `/usr/local/bin/bash`), never at
  `/compat/linux/...`.

## Caveats

- The script targets **one** server commit: the newest installed, or the one
  passed explicitly. With several server commits installed, install into the
  commit your client actually uses.
- Cline version parity between local and remote is not required (the local
  copy only runs in local windows), but keeping them in sync avoids
  "which one am I talking to" confusion.
- This skill does not touch the `~/.devin-server`, `~/.zed_server`, or
  `~/.opencode` setups or the vscode skill's shims.

