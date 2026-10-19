#!/bin/sh
# Create the @opentui/core-freebsd-x64 platform package inside the opencode
# monorepo's node_modules, mirroring the layout opentui's own publish tooling
# produces for linux/darwin/win32.
#
# Usage:
#   make-opentui-freebsd-package.sh <opencode-repo> <path-to-libopentui.so> <opentui-core-version>
#
# Example:
#   make-opentui-freebsd-package.sh ~/src/opencode \
#       ~/src/opentui/packages/core/src/zig/lib/x86_64-freebsd/libopentui.so \
#       0.4.5
#
# Run AFTER `bun install` and BEFORE `bun run script/build.ts`, and re-run it
# after any fresh bun install (installs prune unknown packages).
set -eu

repo=$1
sofile=$2
version=$3

pkg_dir="$repo/node_modules/@opentui/core-freebsd-x64"
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
  "name": "@opentui/core-freebsd-x64",
  "version": "$version",
  "description": "Prebuilt freebsd-x64 binaries for @opentui/core",
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
  "cpu": ["x64"]
}
EOF

echo "created $pkg_dir with $(basename "$sofile")"
