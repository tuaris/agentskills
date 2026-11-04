#!/bin/sh
# Create a @opentui/core-freebsd-<arch> platform package inside a repo's
# node_modules, mirroring the layout opentui's own publish tooling produces
# for linux/darwin/win32.
#
# Usage:
#   make-opentui-freebsd-package.sh <repo> <path-to-libopentui.so> <opentui-core-version> [arch]
#
# Example:
#   make-opentui-freebsd-package.sh ~/Documents/Code/cline-cli \
#       ~/.cache/cline-freebsd/opentui-v0.4.3/packages/core/src/zig/lib/x86_64-freebsd/libopentui.so \
#       0.4.3 x64
#
# Run AFTER `bun install` and BEFORE the bundling/compile step, and re-run
# after any fresh install (installs can prune unknown packages).
set -eu

repo=$1
sofile=$2
version=$3
arch=${4:-x64}
name="core-freebsd-${arch}"

pkg_dir="$repo/node_modules/@opentui/${name}"
mkdir -p "$pkg_dir"
cp "$sofile" "$pkg_dir/libopentui.so"
chmod +x "$pkg_dir/libopentui.so"

cat > "$pkg_dir/index.bun.js" <<'EOF'
const module = await import("./libopentui.so", { with: { type: "file" } })

export default module.default
EOF

cat > "$pkg_dir/index.js" <<'EOF'
import { fileURLToPath } from "node:url"

export default fileURLToPath(new URL("./libopentui.so", import.meta.url))
EOF

cat > "$pkg_dir/index.d.ts" <<'EOF'
declare const path: string
export default path
EOF

cat > "$pkg_dir/package.json" <<EOF
{
  "name": "@opentui/${name}",
  "version": "$version",
  "description": "Prebuilt freebsd-${arch} binaries for @opentui/core",
  "type": "module",
  "main": "index.js",
  "module": "index.js",
  "types": "index.d.ts",
  "license": "MIT",
  "exports": {
    ".": {
      "bun": "./index.bun.js",
      "import": "./index.js",
      "types": "./index.d.ts"
    }
  },
  "os": ["freebsd"],
  "cpu": ["$arch"]
}
EOF

echo "created $pkg_dir with $(basename "$sofile")"
