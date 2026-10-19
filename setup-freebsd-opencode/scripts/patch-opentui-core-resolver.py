#!/usr/bin/env python3
"""Teach the npm-shipped @opentui/core resolver about FreeBSD.

The published @opentui/core package (e.g. 0.4.5) has no FreeBSD platform
package, so two things fail:
  1. getNativeAssetDescriptor() throws because "freebsd" is missing from
     NATIVE_FILE_NAMES.
  2. resolveNativeLibraryPath() (in the bun chunk) has no freebsd branch to
     import a platform package.

This script patches the installed package in place inside the opencode
monorepo. It locates the .bun isolated-install copy of @opentui/core under
OPENCODE_REPO/node_modules/.bun and patches:
  - chunk-bun-*.js      (bun runtime chunk)
  - chunk-node-*.js     (node runtime chunk)
  - node-assets.js      (shared asset module)

Usage:
    patch-opentui-core-resolver.py /path/to/opencode-repo

Run it AFTER `bun install` and BEFORE `bun run script/build.ts`.
Re-run it after every bun install, because installs replace the chunks.
"""
import glob
import os
import sys

repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
core_glob = os.path.join(repo, "node_modules", ".bun", "@opentui+core@*", "node_modules", "@opentui", "core")
candidates = sorted(glob.glob(core_glob))
if not candidates:
    sys.exit(f"@opentui/core not found under {core_glob} -- run `bun install` first")
core = candidates[-1]
print(f"patching @opentui/core at {core}")

# 1. NATIVE_FILE_NAMES: darwin/linux/win32 -> + freebsd
name_patched = 0
for name in glob.glob(os.path.join(core, "chunk-bun-*.js")) + \
            glob.glob(os.path.join(core, "chunk-node-*.js")) + \
            [os.path.join(core, "node-assets.js")]:
    if not os.path.exists(name):
        continue
    src = open(name).read()
    if 'freebsd: "libopentui.so"' in src:
        print(f"  {os.path.basename(name)}: NATIVE_FILE_NAMES already patched")
        name_patched += 1
        continue
    old = '  win32: "opentui.dll"\n};'
    new = '  win32: "opentui.dll",\n  freebsd: "libopentui.so"\n};'
    if src.count(old) != 1:
        continue  # not every chunk carries this table; skip those that don't
    src = src.replace(old, new, 1)
    open(name, "w").write(src)
    name_patched += 1
    print(f"  {os.path.basename(name)}: added freebsd to NATIVE_FILE_NAMES")
assert name_patched > 0, "no NATIVE_FILE_NAMES table found in any @opentui/core chunk"

# 2. resolveNativeLibraryPath(): add a freebsd platform-package branch in the bun chunk
import_block = '''  if (process.platform === "freebsd") {
    if (process.arch === "x64") {
      return (await import("@opentui/core-freebsd-x64")).default;
    }
    if (process.arch === "arm64") {
      return (await import("@opentui/core-freebsd-arm64")).default;
    }
  }
'''
for name in glob.glob(os.path.join(core, "chunk-bun-*.js")):
    src = open(name).read()
    if 'core-freebsd-x64' in src:
        print(f"  {os.path.basename(name)}: freebsd import branch already present")
        continue
    old = '  throw new Error(`OpenTUI is not supported'
    if old not in src:
        continue
    src = src.replace(old, import_block + old, 1)
    open(name, "w").write(src)
    print(f"  {os.path.basename(name)}: added freebsd import branch")

print("done")
