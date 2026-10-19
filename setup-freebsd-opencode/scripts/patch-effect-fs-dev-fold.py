#!/usr/bin/env python3
"""Fold 64-bit stat dev values instead of throwing, in @effect/platform-node-shared.

Effect's NodeFileSystem calls node fs stat with { bigint: true } and converts
fields via bigintToNumber(), which hard-throws RangeError when a field exceeds
Number.MAX_SAFE_INTEGER:

    dev: bigintToNumber(stat.dev, "dev"),

FreeBSD's dev_t is 64-bit, and ZFS datasets routinely receive dev values above
2^53 (as do Linux musl/large-system hosts in principle). Every effect-based
FileSystem.stat on such a directory then fails, which turns into HTTP 500 on
GET /api/fs/list in opencode v2 and breaks directory browsing anywhere in the
app.

This script rewrites the stat conversion in all installed copies of
@effect/platform-node-shared under REPO/node_modules/.bun so out-of-range dev
(and rdev) values are folded into a 32-bit prime modulus instead of throwing.
Dataset identity is preserved with high probability (distinct mod), and the
values are presentation-only for the majority of callers.

Run it AFTER `bun install` in the opencode repo/worktree, BEFORE building.
Idempotent; safe to re-run after fresh installs.

Usage:
    patch-effect-fs-dev-fold.py /path/to/opencode-repo
"""
import glob
import os
import sys

repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()

HELPER = '''const DEVICE_MOD = BigInt(4294967291)  // 2^32 - 5 (Mersenne prime)
const deviceToNumber = (value) => {
  const number = Number(value)
  return Number.isSafeInteger(number) ? number : Number(BigInt.asUintN(64, BigInt(value)) % DEVICE_MOD)
}

'''

old = 'const bigintToNumber = (value, field) => {'
# only `dev` hard-throws here; rdev/ino/blocks already degrade via Option.
targets = [
    ('dev: bigintToNumber(stat.dev, "dev"),', 'dev: deviceToNumber(stat.dev),'),
]

patched_any = False
for name in glob.glob(os.path.join(
    repo, "node_modules", ".bun", "@effect+platform-node-shared@*",
    "node_modules", "@effect", "platform-node-shared", "dist", "NodeFileSystem.js",
)):
    src = open(name).read()
    if "deviceToNumber" in src:
        print(f"{name}: already patched")
        patched_any = True
        continue
    if old not in src:
        print(f"{name}: unexpected layout (no bigintToNumber helper) -- skipping")
        continue
    src = src.replace(old, HELPER + old, 1)
    for a, b in targets:
        if a not in src:
            print(f"{name}: missing call site {a.strip()}")
            continue
        src = src.replace(a, b, 1)
    open(name, "w").write(src)
    print(f"{name}: patched")
    patched_any = True

sys.exit(0 if patched_any else f"no @effect/platform-node-shared copy found under {repo} -- run `bun install` first")
