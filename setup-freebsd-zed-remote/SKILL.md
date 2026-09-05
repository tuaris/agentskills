---
name: setup-freebsd-zed-remote
description: Sets up a FreeBSD host for Zed remote/SSH development by building a native zed-remote-server binary and bypassing Zed's client-side platform check, since Zed does not publish prebuilt FreeBSD binaries or support FreeBSD as a remote platform out of the box
---

# Setup FreeBSD Host for Zed Remote Development

This skill sets up a FreeBSD 15+ host so the Zed editor (running locally on
macOS/Linux/Windows) can open remote SSH projects on it, by building a
native `zed-remote-server` binary and installing a small client-side
workaround.

## Why This Is Needed

Zed's remote development feature normally downloads a prebuilt
`zed-remote-server` binary matching your client's version and OS. FreeBSD
has neither:

1. **No prebuilt binary.** Zed does not currently publish
   `zed-remote-server` builds for FreeBSD (see
   [zed-industries/zed discussion #25601](https://github.com/zed-industries/zed/discussions/25601)).
   Zed's own `crates/fs/src/fs.rs`, `crates/gpui/src/gpui.rs`, and
   `crates/crashes/*` need small patches to even compile on FreeBSD — this
   skill bundles a working patch (`scripts/freebsd-remote-server.patch`) and
   builds the binary from source, natively on the FreeBSD host itself
   (not cross-compiled).

2. **Client-side platform rejection.** Independent of any binary, Zed's
   local client refuses to connect at all: `parse_platform()` in
   `crates/remote/src/transport.rs` only recognizes `Darwin` and `Linux`
   from `uname -sm`, and bails with *"Prebuilt remote servers are not yet
   available for FreeBSD"* **before** ever checking whether a binary is
   already staged on the remote. This skill installs a `uname` shim on the
   FreeBSD host that reports `Linux x86_64`, which is enough to get past
   this check (FreeBSD is POSIX-compatible enough that the rest of the
   Linux code path just works).

Unlike the separate `setup-freebsd-cascade` skill (for Devin/Windsurf),
which runs a genuine Linux binary under FreeBSD's Linux ABI compatibility
layer, **Zed's remote-server here is a true native FreeBSD build** — no
Linux compat layer is needed or used for it.

## Requirements

- FreeBSD 15.0+ target host, reachable over SSH
- `lang/rust` (or equivalent) installed via `pkg` — a full `rustup` install
  is not required; the system Rust toolchain has worked fine in practice
  even though the Zed source's `rust-toolchain.toml` requests a newer
  pinned version (that pin is silently ignored without `rustup`)
- Build dependencies: `git cmake gmake pkgconf llvm` (for `llvm-objcopy`)
- **Meaningful free disk space off the root filesystem.** A release build
  of `remote_server` needs several GB for the Cargo registry + target dir,
  plus the final ~130MB stripped binary. If root (`/`) is tight (as on
  freebsd-dev1), point the build at a separate dataset — the bundled script
  defaults to `~/Documents/Code/zed-remote-build` for exactly this reason.

## Step 1: Get Your Local Zed Client's Exact Version String

The staged binary's filename must match your client's version **exactly**,
including the build number and commit hash. Find it via:

- Zed's About dialog, or
- On the machine running the Zed client:
  `grep "starting zed version" ~/.local/share/zed/logs/Zed.log | tail -1`

It looks like:
```
1.18.1+stable.352.bebe92f469834a287f5a57ed78e8d51a918b8ada
```

## Step 2: Run the Build Script (on the FreeBSD host)

Copy `scripts/build-zed-remote-server.sh` and
`scripts/freebsd-remote-server.patch` to the FreeBSD host (they must stay in
the same directory as each other), then run:

```sh
./build-zed-remote-server.sh 1.18.1+stable.352.bebe92f469834a287f5a57ed78e8d51a918b8ada
```

This is a single self-contained script. On first run it will:

1. Install a `uname` shim at `~/.local/bin/uname` and wire it ahead of
   `/usr/bin` in `PATH` via a fish `conf.d` snippet (idempotent — skipped on
   later runs if already present).
2. Clone the Zed source at the exact commit from your version string into
   `~/Documents/Code/zed-remote-build/zed` (override the parent dir with the
   `BUILD_ROOT` environment variable).
3. Apply `freebsd-remote-server.patch`.
4. Build `remote_server` in release mode (30–60+ minutes on modest/shared
   hardware — it's a full LTO release build of a large crate graph).
5. Strip debug symbols with `llvm-objcopy` and stage the binary at
   `~/.zed_server/zed-remote-server-stable-<full-version>` (a symlink into
   `BUILD_ROOT`, so root stays untouched).
6. Verify it by running `<staged-binary> version`.

Expect the run to take the better part of an hour the first time (fetching
~100+ git-sourced crate dependencies plus the LTO build itself). Subsequent
runs for a new version reuse the existing checkout and Cargo caches, so
they're faster — the compile itself is still the dominant cost.

> **Tip:** if you already have a manual/experimental checkout with a warm
> Cargo cache elsewhere, set `BUILD_ROOT` to its parent before the first run
> to skip re-fetching the dependency graph from scratch.

## Step 3: Configure the Local Zed Client

Add an SSH connection entry in the local Zed `settings.json` (`ctrl-,` /
`cmd-,`), pointing at the FreeBSD host by whatever alias/hostname your
`~/.ssh/config` already uses:

```json
{
  "ssh_connections": [
    {
      "host": "freebsd-dev1",
      "username": "admin"
    }
  ]
}
```

No special flags (like `upload_binary_over_ssh`) are needed — once the
binary is correctly staged and the `uname` shim is in place, Zed finds and
uses it directly.

## Step 4: Connect

Open the Remote Projects dialog (`ctrl-cmd-shift-o` / `alt-ctrl-shift-o`) and
connect to the host as usual.

## Updating After a Zed Client Upgrade

**Rebuild before you reconnect** — do this immediately after upgrading your
local Zed client, before attempting to connect to the FreeBSD host again:

```sh
./build-zed-remote-server.sh 1.19.0+stable.4xx.<new-commit-sha>
```

This is more than a convenience: because the `uname` shim makes the client
believe the remote is Linux, a version mismatch (staged binary older than
the client) makes Zed try to download and run a genuine **Linux** ELF
`zed-remote-server` on this host. That download will "succeed" but the
binary won't execute — FreeBSD has no Linux ABI compatibility layer enabled
here (unlike the `setup-freebsd-cascade` skill's Devin/Windsurf setup, which
does enable one, for an actual Linux binary). There is no automatic
fallback; you must pre-stage the correct native FreeBSD binary before the
client ever gets a chance to try downloading one.

Old staged versions under `~/.zed_server/` and their backing binaries under
`BUILD_ROOT` (e.g. `~/Documents/Code/zed-remote-build/remote_server-*`) are
not automatically cleaned up; remove stale ones manually if disk space
matters.

## Updating the Patch

If a future Zed version's source has drifted enough that
`freebsd-remote-server.patch` no longer applies cleanly, the build script
will fail at the `git apply --check` step with a clear message. To refresh
the patch:

1. In the checked-out repo (`BUILD_ROOT/zed`), manually re-apply equivalent
   fixes for whatever new compile errors appear — the previous fixes needed
   were:
   - `crates/fs/src/fs.rs`: the FreeBSD `current_path()` used
     `MaybeUninit::<libc::kinfo_file>::uninit()` then field-assigned into it
     directly, which doesn't compile. Fix: `.zeroed()` + assign through
     `(*kif.as_mut_ptr()).field = ...` inside `unsafe`.
   - `crates/gpui/src/gpui.rs`: the `queue` module (needed by
     `gpui_linux`, which `gpui_platform` already wires up for
     `cfg(any(target_os = "linux", target_os = "freebsd"))`) was cfg-gated
     to `windows`/`linux`/wasm only, missing `freebsd`. Add
     `target_os = "freebsd"` to both cfg gates (module declaration and the
     `pub use queue::{...}` re-export).
   - `crates/crashes/*`: `crash-handler`/`minidumper` don't support
     FreeBSD. Restructured into a `lib.rs` dispatcher with a `crashes_full`
     module (the original, unmodified code) for non-FreeBSD, and a
     `crashes_freebsd` no-op stub module matching the same public function
     signatures (`init`, `force_backtrace`, `crash_server`, `set_gpu_info`,
     `set_user_info`, `REQUESTED_MINIDUMP`, and a placeholder `Client`
     type), gated via `cfg(not(target_os = "freebsd"))` /
     `cfg(target_os = "freebsd")`. `crashes/Cargo.toml` gates the
     `crash-handler`/`minidumper`/`async-process`/`system_specs`/`zstd`
     dependencies the same way, and adds `futures` (needed by the stub's
     `Future`-returning `init`).
2. Regenerate the patch from the working tree:
   ```sh
   cd BUILD_ROOT/zed
   git add -A
   git diff --staged > /path/to/this/skill/scripts/freebsd-remote-server.patch
   ```
3. Re-run the build script.

Cross-reference: a fuller, independently-discovered writeup (via
cross-compilation with `cargo-zigbuild` rather than a native build) exists
at
[this gist](https://gist.github.com/G36maid/c2aff8c1561b307f38f9e1b3aff215e1),
linked from discussion #25601. It confirms the same core fixes; its extra
steps (sysroot, `libz-sys` patching, `cargo-zigbuild` linker workarounds)
are cross-compilation-specific and not needed for a native build on the
FreeBSD host itself.

## Known Issues / Caveats

- **Telemetry shows "FreeBSD" where Zed expects a Linux distro.** Zed also
  runs `cat /etc/os-release` on Linux remotes for cosmetic/telemetry
  purposes (`parse_os_version` in `crates/remote/src/transport.rs`).
  FreeBSD ships its own `/etc/os-release` (`NAME=FreeBSD`), so this just
  displays "FreeBSD" somewhere Zed expects a Linux distro name — harmless,
  non-blocking (`Option<String>`, never inspected for control flow).
- **Toolchain pin is silently ignored.** Without `rustup` installed, Cargo
  does not honor `rust-toolchain.toml`'s pinned Rust version; it just uses
  whatever `rustc`/`cargo` are on `PATH` (the `lang/rust` port). This has
  worked so far but is worth knowing if a future Zed version requires a
  genuinely newer language feature.
- **Disk space.** See the Requirements section — always point
  `BUILD_ROOT` at a non-root filesystem on space-constrained hosts.
