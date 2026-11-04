#!/usr/bin/env python3
"""Teach the npm-shipped @opentui/core resolver about FreeBSD.

@opentui/core resolves its native library through per-platform packages
(@opentui/core-<os>-<arch>). No FreeBSD package is published, so the bundled
resolver throws "opentui is not supported on the current platform:
freebsd-x64" as soon as the interactive TUI path loads the package.

This patches the installed package in place so it looks up
@opentui/core-freebsd-<arch> instead. Two installed layouts are covered:

  * 0.4.3 (Cline CLI 3.x): a single index-*.js chunk holds
    resolveNativePackage(), which returns the platform package module; the
    caller reads its .default as the library path.
  * 0.4.5/0.5.x (opencode): chunk-bun-*.js / chunk-node-*.js / node-assets.js
    carry a NATIVE_FILE_NAMES table plus a resolver that returns
    (await import(...)).default directly.

For each *.js file at the package root the script:
  1. adds `freebsd: "libopentui.so"` to a NATIVE_FILE_NAMES table when one
     is present (the Node-side asset descriptor throws on unknown platforms
     before the resolver ever runs), and
  2. inserts a `process.platform === "freebsd"` import branch ahead of the
     "not supported on the current platform" throw, in the same return style
     as the surrounding branches, for the requested arch only.

Usage:
    patch-opentui-core-resolver.py [repo-root] [arch]

Run AFTER `bun install` (or npm install) and BEFORE the bundling/compile
step. Re-run after every install: fresh installs replace the chunks, and
isolated-install stores may prune the staging package this pairs with.
"""

import glob
import os
import re
import sys

repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
arch = sys.argv[2] if len(sys.argv) > 2 else "x64"
pkg_name = f"@opentui/core-freebsd-{arch}"

# Bun's isolated install keeps the real copy under node_modules/.bun;
# node_modules/@opentui/core is then a symlink. A classic install keeps the
# real dir at node_modules/@opentui/core.
candidates = sorted(
    glob.glob(
        os.path.join(
            repo, "node_modules", ".bun", "@opentui+core@*",
            "node_modules", "@opentui", "core",
        )
    )
)
hoisted = os.path.join(repo, "node_modules", "@opentui", "core")
if os.path.isdir(hoisted) and not os.path.islink(hoisted):
    candidates.append(hoisted)
candidates = [c for c in candidates if os.path.isdir(c)]
if not candidates:
    sys.exit(
        f"@opentui/core not found under {repo}/node_modules "
        "(.bun store or hoisted) -- run `bun install` first"
    )
core = candidates[-1]
print(f"patching @opentui/core at {core}")

THROW_RE = re.compile(
    r"^(?P<indent>[ \t]*)throw new Error\(`[^\n]*not supported on the current platform",
    re.MULTILINE,
)

name_patched = 0
name_seen = 0
branch_patched = 0

for name in sorted(glob.glob(os.path.join(core, "*.js"))):
    src = open(name).read()
    changed = False

    if f'freebsd-{arch}' in src:
        print(f"  {os.path.basename(name)}: already patched")
        branch_patched += 1
        if 'win32: "opentui.dll"' in src and 'freebsd: "libopentui.so"' in src:
            name_patched += 1
        continue

    # 1. NATIVE_FILE_NAMES table (present in 0.4.5+; absent in 0.4.3).
    old_names = '  win32: "opentui.dll"\n};'
    if old_names in src:
        name_seen += 1
        new_names = '  win32: "opentui.dll",\n  freebsd: "libopentui.so"\n};'
        src = src.replace(old_names, new_names, 1)
        name_patched += 1
        changed = True
        print(f"  {os.path.basename(name)}: added freebsd to NATIVE_FILE_NAMES")

    # 2. Platform import branch ahead of the not-supported throw. Only touch
    #    files that actually resolve per-platform packages.
    if 'process.platform === "darwin"' in src:
        m = THROW_RE.search(src)
        if m:
            if 'return await import("@opentui/core-' in src:
                ret = f'return await import("{pkg_name}");'
            elif 'return (await import("@opentui/core-' in src:
                ret = f'return (await import("{pkg_name}")).default;'
            elif 'return ((await import("@opentui/core-' in src:
                ret = f'return ((await import("{pkg_name}" as string)) as NativePackageModule).default'
            else:
                sys.exit(
                    f"{name}: resolver found but the return style of its "
                    "platform branches is unrecognized"
                )
            ind = m.group("indent")
            branch = (
                f'{ind}if (process.platform === "freebsd") {{\n'
                f'{ind}  if (process.arch === "{arch}")\n'
                f'{ind}    {ret}\n'
                f'{ind}}}\n'
            )
            src = src[: m.start()] + branch + src[m.start():]
            branch_patched += 1
            changed = True
            print(f"  {os.path.basename(name)}: added freebsd {arch} import branch")

    if changed:
        open(name, "w").write(src)

if branch_patched == 0:
    sys.exit("no resolver with a 'not supported on the current platform' throw found")
if name_seen > name_patched:
    sys.exit("a NATIVE_FILE_NAMES table was found but could not be patched")

print("done")
