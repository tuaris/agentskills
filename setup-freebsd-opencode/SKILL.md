---
name: setup-freebsd-opencode
description: Build and install OpenCode (the terminal AI coding agent, anomalyco/opencode) on FreeBSD. Primary path is a fully native binary built with native Bun; fallback path runs the official Linux binary under the Linuxulator. Use when installing, upgrading, or rebuilding OpenCode on FreeBSD hosts.
---

# OpenCode on FreeBSD

How to run [OpenCode](https://opencode.ai) (repo `anomalyco/opencode`, formerly
`sst/opencode`) on FreeBSD. Two supported routes:

- **Path A (preferred): fully native binary.** OpenCode's runtime is Bun, and
  Bun ships official FreeBSD builds (`bun-freebsd-x64.zip`, added in the 1.3.x
  era by oven-sh/bun PR #29676). We build a native `bun-freebsd-x64` compiled
  binary plus a natively compiled `libopentui.so` (the TUI engine, written in
  Zig). Result: FreeBSD ELF, `/libexec/ld-elf.so.1`, zero Linuxulator syscalls.
- **Path B (fallback): Linuxulator.** Run the official `opencode-linux-x64`
  (glibc) build under `linux64.ko`.

**Verified state (2026-11-11, FreeBSD 15.1-RELEASE):** native binaries for
**1.19.0**, **2.0.27** and **2.2.7** installed side-by-side at
`~/.local/share/opencode-freebsd/<ver>/bin/opencode`, with `~/bin/opencode`
pointing at 2.2.7. The `opencode_serve` boot service runs 2.2.7 with basic
auth (verified on loopback, LAN and via https://opencode.morante.dev). All
local patches are preserved in `scripts/`.

## Two version lines

OpenCode ships two active lines and the client/server must match:

| Line | Git tag | Package | `@opentui/core` | Zig | Consumer |
|---|---|---|---|---|---|
| v1 (CLI stable) | `v1.19.0` | `packages/opencode` | 0.4.5 | 0.15.2 (`pkg zig015`) | CLI 1.x |
| v2 (desktop) | `v2.2.7` | `packages/cli` | 0.8.1 | 0.17.0 (`zig017`, official tarball) | Desktop app 2.x, CLI |

Previous verified v2 combo: `v2.0.27` / `@opentui/core` 0.5.17 / zig 0.16.0.

The v2 desktop builds ship through the `anomalyco/opencode-beta` channel repo
(the Releases page tracks the v1 CLI line; v2.0.x exist as git tags without
GitHub Releases or npm packages).

## Path A (v1.19.0): native build

### Prerequisites

```sh
# toolchain for native npm addons (tree-sitter-bash, tree-sitter-powershell)
doas pkg install -y gmake python3 py311-setuptools npm-node24
npm install -g node-gyp

# zig for opentui's native library. MUST match the opentui tag's
# minimum_zig_version in packages/core/src/zig/build.zig.zon.
# @opentui/core 0.4.5 (used by opencode 1.19.0) requires zig 0.15.2 -> pkg zig015.
doas pkg install -y zig015
```

Native Bun (do not use `bun-linux`; that is the Linuxulator package):

```sh
cd /tmp && fetch https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-freebsd-x64.zip
unzip -oq bun-freebsd-x64.zip
export PATH=/tmp/bun-freebsd-x64:$PATH
bun --version   # 1.4.3; this host has AVX2. On older CPUs use bun-freebsd-x64-baseline.zip
```

For a permanent install, move `bun-freebsd-x64/bun` to `~/.local/bin/bun`.
Note: the ports tree has `lang/bun` but it is frequently marked BROKEN;
grabbing the official zip is more reliable.

### Step 1: build the native OpenTUI library

OpenCode's TUI needs `@opentui/core`, which resolves a native `.so` per
platform. No FreeBSD prebuilt exists, so compile it from source:

```sh
git clone https://github.com/anomalyco/opentui.git
cd opentui
git checkout v0.4.5            # MUST match the @opentui/core version pinned
                               # in opencode's packages/opencode/package.json
git apply /path/to/skill/scripts/opentui-build-zig-freebsd.patch
cd packages/core/src/zig
zig build -Doptimize=ReleaseFast
# artifact: lib/x86_64-freebsd/libopentui.so
```

### Step 2: prepare the OpenCode tree

```sh
git clone https://github.com/anomalyco/opencode.git
cd opencode
git checkout v1.19.0
git apply /path/to/skill/scripts/opencode-build-ts-freebsd.patch  # adds freebsd to allTargets
export PATH=/path/to/bun-freebsd-x64:$PATH
bun install --os="*" --cpu="*"
```

The `--os="*" --cpu="*"` flags matter: `@ff-labs/fff-bun` declares
`os: [linux, win32, darwin]`, so a plain `bun install` silently omits it and
runtime dies with `Cannot find module '@ff-labs/fff-bun'`. (fff is the fuzzy
file finder; its bundled binary stays Linux on FreeBSD — it runs through the
Linuxulator transparently, or is treated as unavailable if the Linuxulator is
not loaded.)

**Gotcha — corrupt/partial bun extractions:** if `bun run` later fails with
`Cannot find module '<x>'` for an ordinary pure-JS dependency (seen with
`@mixmark-io/domino`, which extracted without its `lib/` tree), the bun
install cache has a truncated package. Wipe and reinstall:

```sh
rm -rf node_modules ~/.bun/install/cache
bun install --os="*" --cpu="*"
```

### Step 3: wire in the FreeBSD OpenTUI platform package

```sh
patch-opentui-core-resolver.py .                    # scripts/ in this skill
make-opentui-freebsd-package.sh . \
    /path/to/opentui/packages/core/src/zig/lib/x86_64-freebsd/libopentui.so \
    0.4.5
```

`patch-opentui-core-resolver.py` teaches the installed `@opentui/core` about
FreeBSD (adds `freebsd` to `NATIVE_FILE_NAMES` and a platform-package import
branch in the resolver chunk). `make-opentui-freebsd-package.sh` creates
`node_modules/@opentui/core-freebsd-x64` in the same layout OpenTUI's own
publisher uses for other OSes. Re-run both after every `bun install`.

### Step 4: compile

```sh
cd packages/opencode
OPENCODE_VERSION=1.19.0 bun run script/build.ts --single --skip-install
```

- `OPENCODE_VERSION`: without it the binary stamps itself `0.0.0--<ts>`
  (preview channel derived from a detached HEAD).
- `--skip-install`: keeps the Step 3 patches; the build's own re-install would
  not know about the freebsd package.
- Output: `packages/opencode/dist/opencode-freebsd-x64/bin/opencode`
  (~190 MB, FreeBSD ELF).

### Step 5: install and verify

```sh
mkdir -p ~/.local/share/opencode-freebsd/1.19.0/bin
cp dist/opencode-freebsd-x64/bin/opencode ~/.local/share/opencode-freebsd/1.19.0/bin/
ln -sf ~/.local/share/opencode-freebsd/1.19.0/bin/opencode ~/bin/opencode
```

Verification checklist:

| Check | Command | Expected |
|-------|---------|----------|
| Version | `opencode --version` | `1.19.0` |
| Native ELF | `file ~/.local/share/opencode-freebsd/1.19.0/bin/opencode` | `for FreeBSD ... FreeBSD-style` |
| Runs natively | `procstat binary $(pgrep -f path/to/opencode \| head -1)` | `OPREL` 14xx, no `/compat/linux` mappings |
| TUI | `tmux new-session -d -s oc -x 220 -y 50 'opencode; sleep 60'` then `tmux capture-pane -pt oc` | OpenCode splash + prompt |
| Headless server (v1.x) | `opencode serve --hostname 127.0.0.1 --port 4555 &` then `curl -s 127.0.0.1:4555/global/health` | `{"healthy":true,...}` |
| Headless server (v2.x) | same, then `curl -s -u opencode:$OPENCODE_SERVER_PASSWORD 127.0.0.1:4555/api/info` | `{"version":"<ver>",...}` |

## Path A2 (v2.0.27): native build

Same shape as Path A with these deltas. Verified end-to-end 2026-10-12
(`--version`/`opencode v2.0.27`, TUI in tmux, `/api/info` probe).

1. Prereqs: same, but `doas pkg install -y zig` (0.16.0).
2. opentui `v0.5.17`: native code moved to `packages/native/` with vendored
   zig deps. Apply `scripts/opentui-native-build-zig-freebsd-v05.patch`, then:
   `cd packages/native && sh scripts/prepare-zig-deps.sh && zig build -Doptimize=ReleaseFast`
   → `lib/x86_64-freebsd/libopentui.so`.
   (`zig build test` does not compile out of the box: ghostty module wiring is
   a pre-existing upstream test-setup issue, not FreeBSD.)
3. opencode `v2.0.27`: apply `scripts/opencode-cli-build-ts-freebsd-v2.patch`
   (target now selected via `--target=opencode-freebsd-x64`; v2 has no musl
   variants concept needed — PTY embedding auto-skips FreeBSD).
4. `bun install --os="*" --cpu="*"`, then
   `patch-opentui-core-resolver.py .` (0.5.17 chunk names differ; the patcher
   globs handle it), then `make-opentui-freebsd-package.sh . <so> 0.5.17`.
5. **Extra step (v2):** the build rewrites `watcher-binding.ts` to a literal
   `require("@parcel/watcher-freebsd-x64")`, which isolated installs don't
   link into core's chain. Stage it by hand:
   `cp -r node_modules/.bun/@parcel+watcher-freebsd-x64@2.5.1/node_modules/@parcel/watcher-freebsd-x64 node_modules/@parcel/`
   and the same into `packages/core/node_modules/@parcel/`.
6. Build: `cd packages/cli && OPENCODE_VERSION=2.0.27 bun run script/build.ts
   --target=opencode-freebsd-x64 --skip-install` →
   `dist/cli-freebsd-x64/bin/opencode`. Subsequent rebuilds may add
   `--skip-web-ui` once the web archive is cached.

**Mandatory v2 source patch — SIGUSR1 guard:** apply
`scripts/opencode-cli-heap-sigusr1-freebsd.patch` to `packages/cli/src/heap.ts`.
JSC uses SIGUSR1 for thread suspend on FreeBSD (SIGPWR is Linux-only);
`Heap.listen` registers `process.on("SIGUSR1")` at CLI init, which installs
Bun's JS signal handler over JSC's and wedges the whole process ~60-120s after
startup when the first GC/VMTraps suspend fires (accepted sockets, no replies;
even SIGTERM never completes). Verified with ktrace (thr_kill SIGUSR1 →
kevent EINTR → loop never polls again) and by the patched build surviving.
The `CpuProfile` SIGPROF listener is harmless. Upstream: anomalyco/opencode#54928;
runtime fix pending as oven-sh/bun#44596 (open). The self-update script applies
this patch automatically for v2 lines; until bun ships the fix, guard this on
any future v2 rebuild.

**Two more v2 FreeBSD fixes** (already in the self-update pipeline and needed
for any manual rebuild):

- `scripts/patch-effect-fs-dev-fold.py` — post-install patcher for
  `@effect/platform-node-shared`'s `NodeFileSystem`: `stat({bigint:true})`
  fields are hard-checked against `Number.MAX_SAFE_INTEGER`, but FreeBSD
  dev_t is 64-bit and ZFS datasets get dev values above 2^53, so
  `FileSystem.stat` throws `RangeError: dev exceeds the safe integer range`
  and directory browsing 500s (observed on `/api/fs/list`). The patcher folds
  dev mod 2^32-5 instead of throwing. Upstream: Effect-TS/effect#9111.
- `scripts/opencode-core-watcher-freebsd-kqueue.patch` — `watcher.ts`
  getBackend() had no FreeBSD case, logging `watcher backend not supported
  platform=freebsd`; adds the `kqueue` backend that @parcel/watcher provides
  for FreeBSD. Verified: `watcher started ... backend=kqueue` in the service
  log.

v2 run-time differences that matter operationally:

- **`serve` is authenticated by default** (prints a random password unless
  `OPENCODE_SERVER_PASSWORD` is set). Set a stable password for any server
  that clients save — the rc script's `opencode_serve_password` knob does this.
- The health/info probe is **`GET /api/info`** (v1's `/global/health` is gone).
- New `opencode service` command group (managed background service +
  registration files in `$XDG_STATE_HOME/opencode/`); used by the desktop's
  Pairing and "Add SSH server" flows.
- `@opencode-ai/pty` has no FreeBSD subpackage; embedding is skipped and the
  terminal/PTY capability may be limited until a native pty binary is built
  (`OPENCODE_PTY_BIN` env can inject a locally built one).

### v2.2.x deltas (verified 2026-11-11, v2.2.7)

Same pipeline as Path A2; the self-update script handles all of it. Deltas
that matter for manual rebuilds:

1. **bun ^1.4.4** required (1.4.3 fails the build's version check). Official
   `bun-freebsd-x64.zip` from the bun-v1.4.4 release; keep the old binary as
   `~/.local/bin/bun-<oldver>.bak`.
2. **zig 0.17.0** for opentui 0.8.1 (`minimum_zig_version` in
   `packages/native/build.zig.zon`). No pkg at the time: official tarball to
   `/opt/zig-x86_64-freebsd-0.17.0`, symlink `/usr/local/bin/zig017`, run the
   script with `ZIG=/usr/local/bin/zig017`.
3. **Target selection** moved from `--target=opencode-freebsd-x64` argv to
   `OPENCODE_TARGET=freebsd-x64` env (no `opencode-` prefix). The script
   greps build.ts and picks the right form per tag.
4. **Parcel watcher** literal-require rewrite moved from
   `packages/cli/script/build.ts` to
   `packages/core/src/filesystem/watcher-binding.ts`; the staging step is
   unchanged (the script checks both locations).
5. **opentui 0.8.1** still builds from `packages/native` with
   `opentui-native-build-zig-freebsd-v05.patch`. The source resolver moved
   to a `#opentui/runtime-assets` module, but the published npm package
   keeps the `chunk-bun-*.js` / `chunk-node-*.js` / `node-assets.js` layout,
   so `patch-opentui-core-resolver.py` applies unchanged.
6. **PTY embedding** is optional and on by default (`WITH_PTY=1`): the
   opencode-pty daemon is built from source and embedded; see "Persistent
   terminals and native fff" below. `WITH_PTY=0` keeps the old behavior.
7. **Disk space:** the all-platform `bun install` is multi-GB. The script
   exports `BUN_INSTALL_CACHE_DIR` and `TMPDIR` under `$SRC_DIR` so a small
   root filesystem cannot ENOSPC mid-install. Check `df -h /` first anyway.
8. bun install warns about upstream `patches/*.patch` entries whose
   dependencies were removed or upgraded (e.g. `@ai-sdk/mistral`,
   `gcp-metadata`); harmless, unrelated to our patches.

## Persistent terminals and native fff (v2.2.x)

Borrowed from FreeBSD ports misc/opencode (samm@FreeBSD.org) and verified
on 2026-11-11 with v2.2.7. The self-update script builds and embeds two
native extras by default:

- **opencode-pty** (`WITH_PTY=1`): the persistent terminal daemon (Rust +
  ghostty VT, built with zig 0.16 via `PT_ZIG`, default `zig016`). Embedded
  through `OPENCODE_PTY_BIN`; the CLI build's platform gate is patched to
  accept freebsd. Ghostty is fetched as a pinned tarball (the revision in
  `packages/process-daemon/ghostty-revision`), patched for zig 0.16, and
  its zig dependency cache is warmed once per revision under `$SRC_DIR`.
- **fff** (`WITH_FFF=1`): the fuzzy finder as a native `libfff_c.so`
  (cargo, `--package fff-c`), wired into `@ff-labs/fff-bun` by
  `setup-fff-freebsd.py`. No Linuxulator needed. fff's release profile uses
  fat LTO with one codegen unit: the first build is slow (~25 min on a
  Xeon E5-2620 v4), cached afterwards in `$SRC_DIR/cargo-target`.

Both need cargo; without it they are skipped with a warning and the binary
works as before. Post-build checks grep the executable for `libghostty`
and `crates/fff-c/src` to prove embedding.

**Daemon protocol compatibility:** the tag's `process-daemon` source can be
ahead of the tag's JS client (v2.2.7 ships daemon protocol 8 with a
protocol-7 client; upstream embeds prebuilt daemons on other platforms).
The script detects the mismatch and builds the newest daemon revision whose
`PROTOCOL_VERSION` matches the client (`git archive` into
`$SRC_DIR/pty-src-<ver>`). A mismatched daemon is rejected at runtime with
"opencode-pty protocol mismatch".

**Restart persistence (rc service):** the pty daemon stops as soon as its
owner disconnects unless a handoff was prepared (upstream design; the
desktop/CLI managed flows do this). `opencode_serve.rc` now does the same:

- stop: POST `/api/experimental/persistent-pty/handoff` (with an Origin
  header; one retry) and save the ticket to
  `/var/run/opencode_serve.pty-handoff` (0600, ~120s expiry).
- start: consume the ticket and export `OPENCODE_PTY_HANDOFF` so the new
  server reclaims the waiting daemon and its terminals.

The hook resolves python3/curl with `/usr/local/bin` fallbacks because
service(8) runs with a base-only PATH. Handoff is best-effort: if it fails
(the endpoint showed transient 301s during some startup windows), the
restart still works and terminals start fresh. Verified: a terminal with
scrollback survives `service opencode_serve restart`; qwen4-max-preview
run, TUI and the external endpoint stayed green after the rebuild.

## Model catalog refresh (v2.2.x)

- The CLI/server fetch the **models.opencode.ai v2 catalog** with a 5-minute
  TTL, a KV cache and a bundled snapshot fallback; `opencode models` lists
  the merged result. Provider endpoints are not queried for model lists at
  runtime.
- Models the endpoint serves but models.dev lacks (e.g. `qwen4-max-preview`
  on the Alibaba Token Plan endpoint) are added as custom entries under
  `provider.<id>.models` in `~/.config/opencode/opencode.jsonc`: name,
  capabilities, `compatibility.reasoningField`, thinking `variants`.
  Verified: `opencode models | grep qwen4` and
  `opencode run --model alibaba/qwen4-max-preview#none "..."` (variant ids:
  `none`, `high`, `max`).
- **Headless credential storage:** `opencode auth login` with the `key`
  method requires a TTY. Without one, call the server API directly:
  `opencode api integration.connect.key --param integrationID=<id>
  --data '{"key":"...","label":"..."}'` (source the key from the service env
  file at runtime; never echo it). `opencode auth list` then shows the
  integration as `stored`. Without stored credentials `opencode run` fails
  with `<PROVIDER>_API_KEY is not set` even when the boot service's env file
  has the key: the CLI background service does not read that env file.

## Path B: Linuxulator (quick install, no build)

Verified 2026-10-12 on FreeBSD 15.1-RELEASE-p2 with linux_base-rl9: the full
TUI works this way.

1. Load the Linuxulator (if not already): `doas kldload linux64` (+`linux_load="YES"`, `linux64_load="YES"` in `/boot/loader.conf`) and `doas pkg install -y linux_base-rl9`.
2. Download the **glibc** tarball — the `-musl` variant aborts under the
   Linuxulator even with the musl loader absent; the glibc variant against
   rl9's glibc 2.34 works:

   ```sh
   mkdir -p ~/.local/share/opencode-linux && cd ~/.local/share/opencode-linux
   fetch https://github.com/anomalyco/opencode/releases/download/v1.19.0/opencode-linux-x64.tar.gz
   tar xzf opencode-linux-x64.tar.gz
   ln -sf ~/.local/share/opencode-linux/opencode ~/bin/opencode
   ```

   On CPUs without AVX2 use `opencode-linux-x64-baseline.tar.gz`
   (check `grep -o AVX2 /var/run/dmesg.boot`).
3. The official installer also works if run under the Linuxulator shell, which
   spoofs `uname -s` as Linux: `/compat/linux/bin/bash -c 'curl -fsSL https://opencode.ai/install | bash'` (lands in `~/.opencode/bin`).

## FreeBSD port (misc/opencode)

An official port exists: `misc/opencode`, maintained by samm@FreeBSD.org
(added 2026-10-19; v2.2.5 as of 2026-11-11, upstream already at v2.2.7).
It builds the same native `bun --compile` binary from source and installs
`/usr/local/bin/opencode` plus `/usr/local/lib/opencode/watcher.node`.
Packages are on official `latest` (14/15/16, amd64 + aarch64); not on
quarterly until the next branch, and not in the estate's PortsPlus repo.

What the port builds beyond this skill's pipeline (fff and opencode-pty
were borrowed into it on 2026-11-11, see below):

- **@parcel/watcher** kqueue addon compiled from source with node-gyp
  (we stage the prebuilt freebsd package from npm instead).
- Web UI WASM fallbacks (lightningcss/rolldown) and aarch64 support.
- Offline bun/zig caches warmed at fetch time (poudriere-friendly).
- hier(7) system config dir `/usr/local/etc/opencode` (upstream PR #58347).

Patch overlap: build.ts freebsd target, opentui zig targets, resolver
wiring (`setup-opentui-freebsd.py` matches our resolver patcher + platform
package script), watcher-binding literal require. Gaps and differences,
verified 2026-11-11 against the port's files/ and pristine v2.2.5/v2.2.7:

1. **No SIGUSR1 heap guard.** Upstream `heap.ts` still registers the JS
   SIGUSR1 listener on FreeBSD (the JSC suspend collision, Path A2). The
   port builds against `lang/bun` (source build, samm-git WebKit fork with
   FreeBSD fixes); whether that avoids the collision is UNVERIFIED. Test
   a port binary for the 60-120s post-startup hang before trusting it.
2. **No effect dev-fold patch.** The ZFS dev_t RangeError fix has no port
   equivalent; directory browsing on ZFS may 500. The port's "fix chdir
   on ZFS" commit is the hier(7) config-dir patch, not this.
3. **Watcher strategy differs.** The port found Bun 1.4.x segfaults/hangs
   when parcel's kqueue subscription delivers events through N-API
   thread-safe functions, and Bun's fs.watch misses missing entries on
   FreeBSD. It uses the addon snapshot API (writeSnapshot/getEventsSince,
   250ms tick) for directories and a 100ms JS poller for file/entry
   watches. Our kqueue-backend patch uses the subscription path: stable
   in production so far, but treat watcher crashes as this known Bun
   issue and consider the snapshot approach if they appear.

Coexistence: the port installs `/usr/local/bin/opencode`; this skill
installs `~/bin/opencode` -> `~/.local/share/opencode-freebsd/<ver>`.
PATH order decides interactive use; `opencode_serve.rc` and the CLI
background service pin explicit paths. Do not mix managers on one host:
never run `opencode upgrade` against a pkg-managed binary, and a pkg
install does not touch the versioned installs. The port ships no rc
script; `opencode_serve.rc` works with either binary.

**Recommendation (2026-11-11):** keep the self-update pipeline as primary
(immediate upstream tags, all FreeBSD fixes carried). Re-evaluate the port
once it matches our version and gaps 1-2 are resolved upstream or in the
port. Estate adoption: merge upstream into deluxe (last merge 2026-10-12
predates the port), then plus overlay + poudriere; `lang/bun` is a heavy
source build (LLVM, pinned rust-nightly, WebKit prebuilt). Alternative:
borrow the pty/fff build steps into this pipeline for persistent
terminals sooner.

## Run as a remote server (boot service)

OpenCode's Desktop app (and `opencode attach`) connect to a server started with
`opencode serve`. `scripts/opencode_serve.rc` is an rc.subr script that runs it at
boot as a daemon(8)-wrapped service:

```sh
doas cp /path/to/skill/scripts/opencode_serve.rc /usr/local/etc/rc.d/opencode_serve
doas chmod +x /usr/local/etc/rc.d/opencode_serve
doas sysrc opencode_serve_enable=YES
doas service opencode_serve start
curl -s 127.0.0.1:4555/global/health   # {"healthy":true,...}
```

It runs the native binary (`~<user>/bin/opencode`) **as an unprivileged user**
(`opencode_serve_user`, default `admin`; a boot service must not run the agent
as root), listens on `127.0.0.1:4555` by
default, and logs to `/var/log/opencode_serve/opencode_serve.log`.

Client setup:

- **SSH tunnel (recommended):** from the workstation,
  `ssh -N -L 4555:127.0.0.1:4555 <user>@<freebsd-host>`, then Desktop app
  **Add server → `http://127.0.0.1:4555`**. No firewall change, no LAN
  exposure.
- **Direct on LAN:** `doas sysrc opencode_serve_hostname=0.0.0.0
  opencode_serve_password=<secret>` then restart. The script exports
  `OPENCODE_SERVER_PASSWORD`, which makes the server require HTTP basic auth
  (username `opencode`; verified 401 without, 200 with, on the native build).
  Still plain HTTP — prefer the tunnel on untrusted wire. Client URL:
  `http://<freebsd-host>:4555`. `--mdns` is also available via
  `opencode_serve_flags` if auto-discovery is wanted.
- A terminal client can attach to the same server instead of the desktop app:
  `opencode attach http://127.0.0.1:4555`; sessions are shared.

The FreeBSD box is the execution host: the agent's shell and file tools operate
on the FreeBSD host, not the client workstation (same model as the Zed remote
server in `setup-freebsd-zed-remote`).

## Files in this skill

| File | Purpose |
|---|---|
| `opencode-freebsd-selfupdate.sh` | Full native rebuild+install pipeline for v1 and v2 tags |
| `opencode_serve.rc` | rc.d daemon for `opencode serve` (env-file secrets, password knob) |
| `opencode-build-ts-freebsd.patch` | build.ts freebsd target — v1 (`packages/opencode`) |
| `opencode-cli-build-ts-freebsd-v2.patch` | build.ts freebsd target — v2 (`packages/cli`) |
| `opencode-cli-heap-sigusr1-freebsd.patch` | v2: skip SIGUSR1 JS listener (JSC suspend-signal collision) |
| `opencode-core-watcher-freebsd-kqueue.patch` | v2: kqueue watcher backend on FreeBSD |
| `opentui-build-zig-freebsd.patch` | opentui 0.4.x: freebsd zig targets (v1 line) |
| `opentui-native-build-zig-freebsd-v05.patch` | opentui 0.5.x: freebsd zig targets (v2 line) |
| `patch-opentui-core-resolver.py` | Post-install resolver patch: teach `@opentui/core` about FreeBSD |
| `make-opentui-freebsd-package.sh` | Stage `@opentui/core-freebsd-x64` with our `libopentui.so` |
| `patch-effect-fs-dev-fold.py` | Post-install: fold 64-bit stat dev (Effect RangeError fix) |
| `opencode-pty-build-rs-freebsd.patch` | opencode-pty build.rs: accept vendored ghostty tree (from misc/opencode) |
| `opencode-pty-script-freebsd.patch` | CLI build: embed opencode-pty on freebsd (from misc/opencode) |
| `ghostty-zig-0.16-std.patch` | ghostty: trimRight/trimLeft renames for zig 0.16 (from misc/opencode) |
| `setup-fff-freebsd.py` | Wire native libfff_c.so into @ff-labs/fff-bun (from misc/opencode) |

## Self-update (both lines)

`scripts/opencode-freebsd-selfupdate.sh` automates the whole native pipeline
(clone/refresh caches in `$XDG_CACHE_HOME/opencode-freebsd`, worktree off the
target tag, read the pinned `@opentui/core` from `bun.lock`, apply the right
patch files, build `libopentui.so`, wire node_modules, compile, smoke-test,
install to `~/.local/share/opencode-freebsd/<ver>/` and repoint
`~/bin/opencode`). Verified end-to-end 2026-10-12 for `--version v2.0.27`
and `--version v1.19.0`, and 2026-11-11 for v2.2.7 (default tag discovery).

```sh
# prerequisites: native bun in PATH (or BUN=), python3, git, the node-gyp
# toolchain from the Path A prereqs, and a zig matching the opentui tag:
BUN=~/.local/bin/bun ZIG=/usr/local/bin/zig017 \
  /path/to/skill/scripts/opencode-freebsd-selfupdate.sh        # newest v2.x tag
BUN=~/.local/bin/bun ZIG=/usr/local/bin/zig0152 \
  /path/to/skill/scripts/opencode-freebsd-selfupdate.sh --version v1.19.0
```

- Suggested zig layout: toolchains under `/opt/zig-x86_64-freebsd-<ver>/` with
  `/usr/local/bin/zig0152` and `/usr/local/bin/zig016` symlinks (pkg
  `zig`/`zig015` both claim `/usr/local/bin/zig` and clobber each other, so do
  not rely on the unversioned path).
- Tag discovery globs `v2.*` with `sort -V`; tag fetches use `--force` because
  upstream occasionally rewrites tags (a rejected update aborts `set -e`).
- `WITH_PTY`/`WITH_FFF` (default 1) build and embed the opencode-pty daemon
  and native fff; they need cargo and are skipped with a warning without it.
  `PT_ZIG` selects the zig 0.16 binary for the ghostty VT build.
- Set `SERVICE_NAME=opencode_serve` and the script also handles daemons
  holding the old binary: stops the service, kills leftover processes (the
  text lock defeats plain cp), swaps the binary atomically, and starts it
  again. `--dry-run` only resolves the upstream tag.
- The script re-runs cleanly: patches are applied only when absent, existing
  `libopentui.so` and worktrees are reused.
- Known flaky step on first install in a fresh clone: the tree-sitter
  node-gyp builds can trip the lockfile-pinned node-gyp 12. Rebuild the failed
  addon by hand once (`cd node_modules/.bun/tree-sitter-*/.../tree-sitter-* &&
  node-gyp rebuild` with the global node-gyp 13) and re-run the script; bun
  install then completes.

## Maintenance / upgrade notes

- **Version bumps:** for a new OpenCode release, re-check the pinned
  `@opentui/core` and `@ff-labs/fff-bun` versions in
  `packages/opencode/package.json`. If `@opentui/core` changed, rebuild
  `libopentui.so` from the matching opentui tag (and note its zig version pin
  — 0.4.5 wants zig 0.15.2, 0.5.x/0.6.x want zig 0.16, 0.8.1 wants zig 0.17.0) and regenerate the
  platform package. The two source patches (`scripts/*.patch`) are small and
  usually re-apply cleanly; the chunk patcher is idempotent and re-checks its
  anchors.
- **Rebuild rule:** like the Zed remote server, rebuild before reconnecting a
  newer client channel; the TUI itself nags `/update to install vX` when stale.
- **Upstream candidates** (would delete most of this skill's custom steps):
  1. opentui PR: FreeBSD entries in `SUPPORTED_TARGETS` +
     `packages/core/src/node-asset-target.ts` + platform package publishing.
  2. opencode PR: `freebsd` entry in `allTargets` once opentui ships FreeBSD.
  3. Bun-on-FreeBSD port / `fff-bun` native FreeBSD build (Rust, so just a
     cargo target) to make the fuzzy finder native too.
  Status 2026-11-11: `lang/bun` and `misc/opencode` are in the ports tree
  (see above); candidates 1-2 are still unmerged upstream.
- **fff fuzzy finder:** built natively by default (`WITH_FFF=1`, needs
  cargo). With `WITH_FFF=0` or no cargo, the bundled Linux binary is used
  and relies on the Linuxulator; without it the feature degrades gracefully
  rather than breaking the TUI.
