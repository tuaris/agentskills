#!/bin/sh
# opencode-freebsd-selfupdate.sh
#
# Rebuild and (re)install a native FreeBSD OpenCode binary from upstream git
# tags. Works for the v1 line (packages/opencode, e.g. v1.19.0) and the v2
# line (packages/cli, e.g. v2.0.27). No machine-specific assumptions: all
# locations are env-tunable.
#
# Dependencies: git, fetch or curl, unzip, python3, gmake/node-gyp toolchain
# (see SKILL.md), a zig in PATH matching the opentui tag's minimum_zig_version
# (or set ZIG=/path/to/zig), and a native bun (set BUN or have bun in PATH).
#
# FreeBSD-specific patches applied automatically:
#   - build target entries (v1 packages/opencode, v2 packages/cli)
#   - v2: SIGUSR1 listener guard in heap.ts (JSC suspend signal collision)
#   - v2: kqueue watcher backend in watcher.ts
#   - effect stat dev fold (64-bit dev_t, @effect/platform-node-shared)
#   - @opentui/core resolver chunks + @opentui/core-freebsd-x64 platform package
#
# Usage:
#   opencode-freebsd-selfupdate.sh [--version vX.Y.Z] [--dry-run]
#
# Environment knobs:
#   VERSION          opencode git tag (default: newest v2.0.x tag upstream)
#   SRC_DIR          cached clone dir    (default: $XDG_CACHE_HOME/opencode-freebsd or ~/.cache/opencode-freebsd)
#   INSTALL_PREFIX   install root        (default: $HOME/.local/share/opencode-freebsd)
#   LINK             binary symlink      (default: $HOME/bin/opencode; empty = none)
#   BUN              bun binary          (default: first bun in PATH)
#   ZIG              zig binary          (default: first zig in PATH)
#   OPENCODE_REPO    (default: https://github.com/anomalyco/opencode.git)
#   OPENTUI_REPO     (default: https://github.com/anomalyco/opentui.git)
#   SERVICE_NAME     if set, stop/replace/start this rc.d service around the install
#                    (handles wedged/stale processes holding the old binary)
#   SKIP_VERIFY      if set, skip the --version smoke test
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

VERSION_ARG=""
DRY_RUN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION_ARG=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

OPENCODE_REPO=${OPENCODE_REPO:-https://github.com/anomalyco/opencode.git}
OPENTUI_REPO=${OPENTUI_REPO:-https://github.com/anomalyco/opentui.git}
SRC_DIR=${SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-freebsd}
INSTALL_PREFIX=${INSTALL_PREFIX:-$HOME/.local/share/opencode-freebsd}
LINK=${LINK-$HOME/bin/opencode}
BUN=${BUN:-$(command -v bun || true)}
ZIG=${ZIG:-$(command -v zig || true)}
SERVICE_NAME=${SERVICE_NAME:-}

log() { printf '%s\n' "== $*"; }
die() { printf '%s\n' "!! $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need git; need python3
[ -n "$BUN" ] || die "no native bun in PATH; set BUN= (see SKILL.md prerequisites)"
[ -x "$BUN" ] || die "BUN=$BUN is not executable"
[ -n "$ZIG" ] || die "no zig in PATH; install the zig package matching the opentui tag (see SKILL.md) or set ZIG="

if [ -n "$VERSION_ARG" ]; then
    TAG=$VERSION_ARG
else
    TAG=$(git ls-remote --tags "$OPENCODE_REPO" 'v2.0.*' | sed 's#.*refs/tags/##' | grep -v '\^{}' | sort -t. -k2,2n -k3,3n | tail -1)
    [ -n "$TAG" ] || die "could not discover a v2.0.x tag upstream; pass --version"
fi
VER=${TAG#v}
MAJOR=$(printf '%s' "$VER" | cut -d. -f1)
log "target: $OPENCODE_REPO @ $TAG"
[ -n "$DRY_RUN" ] && { log "dry-run: tag resolves ok"; exit 0; }

# --- source trees ----------------------------------------------------------
mkdir -p "$SRC_DIR"
if [ ! -d "$SRC_DIR/opencode/.git" ]; then
    log "cloning opencode"
    git clone --quiet "$OPENCODE_REPO" "$SRC_DIR/opencode"
fi
if [ ! -d "$SRC_DIR/opentui/.git" ]; then
    log "cloning opentui"
    git clone --quiet "$OPENTUI_REPO" "$SRC_DIR/opentui"
fi

log "fetching tags"
git -C "$SRC_DIR/opencode" fetch --quiet --tags --prune origin
git -C "$SRC_DIR/opentui" fetch --quiet --tags --prune origin

WORK="$SRC_DIR/build-$VER"
if [ ! -d "$WORK" ]; then
    git -C "$SRC_DIR/opencode" worktree add --quiet "$WORK" "$TAG" || die "worktree add failed for $TAG"
fi
cd "$WORK"
# worktrees accumulate; prune silently where possible
git -C "$SRC_DIR/opencode" worktree prune >/dev/null 2>&1 || true

# opencode build target patch (v1: packages/opencode; v2: packages/cli)
if [ "$MAJOR" = 1 ]; then
    CLI_PKG=packages/opencode
    PATCH_OC=opencode-build-ts-freebsd.patch
    BUILD_FLAGS="--single"
else
    CLI_PKG=packages/cli
    PATCH_OC=opencode-cli-build-ts-freebsd-v2.patch
    BUILD_FLAGS="--target=opencode-freebsd-x64"
fi

if [ ! -f "$DIR/$PATCH_OC" ]; then
    die "expected skill patch $DIR/$PATCH_OC (keep this script with the skill's scripts/)"
fi
if ! git diff --quiet -- "$CLI_PKG/script/build.ts" 2>/dev/null; then
    log "opencode build script already patched"
elif git apply --check "$DIR/$PATCH_OC" 2>/dev/null; then
    log "applying $PATCH_OC"
    git apply "$DIR/$PATCH_OC"
else
    grep -q "freebsd" "$CLI_PKG/script/build.ts" || die "cannot apply $PATCH_OC and no freebsd target present"
fi

# v2 only: guard Heap.listen's SIGUSR1 handler. JSC uses SIGUSR1 for thread
# suspend on FreeBSD (SIGPWR is Linux-only); the JS listener clobbers it and
# wedges the VM on the first GC (oven-sh/bun#44596, opencode#heap.ts).
if [ "$MAJOR" != 1 ]; then
    HEAP_PATCH=opencode-cli-heap-sigusr1-freebsd.patch
    if grep -q '"freebsd") return' "$CLI_PKG/src/heap.ts" 2>/dev/null; then
        log "heap.ts SIGUSR1 guard already present"
    elif [ -f "$DIR/$HEAP_PATCH" ] && git apply --check "$DIR/$HEAP_PATCH" 2>/dev/null; then
        log "applying $HEAP_PATCH"
        git apply "$DIR/$HEAP_PATCH"
    else
        die "missing/unapplicable $HEAP_PATCH -- v2 binaries will wedge on FreeBSD without it"
    fi

    # watcher.ts lacks a FreeBSD backend case; @parcel/watcher supports kqueue.
    WATCHER_PATCH=opencode-core-watcher-freebsd-kqueue.patch
    if grep -q 'return "kqueue"' packages/core/src/filesystem/watcher.ts 2>/dev/null; then
        log "watcher.ts kqueue backend already present"
    elif [ -f "$DIR/$WATCHER_PATCH" ] && git apply --check "$DIR/$WATCHER_PATCH" 2>/dev/null; then
        log "applying $WATCHER_PATCH"
        git apply "$DIR/$WATCHER_PATCH"
    else
        die "missing/unapplicable $WATCHER_PATCH -- file watching would log a warning on FreeBSD"
    fi
fi

# --- opentui native library --------------------------------------------------
OTUI_VER=$(grep -o '@opentui/core@[0-9][0-9.]*' bun.lock | head -1 | cut -d@ -f3)
[ -n "$OTUI_VER" ] || die "could not determine @opentui/core version from bun.lock"
log "opentui version pinned: $OTUI_VER"

OT_WORK="$SRC_DIR/opentui-v$OTUI_VER"
if [ ! -d "$OT_WORK" ]; then
    git -C "$SRC_DIR/opentui" worktree add --quiet "$OT_WORK" "v$OTUI_VER" || die "worktree add failed for opentui v$OTUI_VER"
fi
git -C "$SRC_DIR/opentui" worktree prune >/dev/null 2>&1 || true

if [ -d "$OT_WORK/packages/native" ]; then
    ZIG_DIR=$OT_WORK/packages/native
    PATCH_OT=opentui-native-build-zig-freebsd-v05.patch
else
    ZIG_DIR=$OT_WORK/packages/core/src/zig
    PATCH_OT=opentui-build-zig-freebsd.patch
fi

MIN_ZIG=$(grep -o 'minimum_zig_version = "[^"]*"' "$ZIG_DIR/build.zig.zon" | cut -d'"' -f2)
ACT_ZIG=$("$ZIG" version)
case "$ACT_ZIG" in
    "$MIN_ZIG") ;;
    *) die "zig version mismatch: opentui $OTUI_VER pins $MIN_ZIG, you have $ACT_ZIG. Install the matching zig package (e.g. pkg install zig015) or set ZIG=/path/to/correct/zig" ;;
esac

if grep -q 'x86_64-freebsd' "$ZIG_DIR/build.zig"; then
    log "opentui build script already has a freebsd target"
elif git -C "$OT_WORK" apply --check "$DIR/$PATCH_OT" 2>/dev/null; then
    log "applying $PATCH_OT"
    git -C "$OT_WORK" apply "$DIR/$PATCH_OT"
else
    die "cannot apply $PATCH_OT to $ZIG_DIR/build.zig"
fi

LIB=$ZIG_DIR/lib/x86_64-freebsd/libopentui.so
if [ ! -f "$LIB" ]; then
    log "building libopentui (zig $ACT_ZIG)"
    [ -f "$ZIG_DIR/scripts/prepare-zig-deps.sh" ] && (cd "$ZIG_DIR" && sh scripts/prepare-zig-deps.sh)
    (cd "$ZIG_DIR" && "$ZIG" build -Doptimize=ReleaseFast)
fi
[ -f "$LIB" ] || die "libopentui.so not produced at $LIB"

# --- node_modules wiring -----------------------------------------------------
cd "$WORK"
log "bun install"
"$BUN" install --os="*" --cpu="*" >/dev/null

python3 "$DIR/patch-opentui-core-resolver.py" .
"$DIR/make-opentui-freebsd-package.sh" . "$LIB" "$OTUI_VER"
# Effect fs: fold 64-bit stat dev on FreeBSD instead of RangeError on >2^53
if [ -f "$DIR/patch-effect-fs-dev-fold.py" ]; then
    python3 "$DIR/patch-effect-fs-dev-fold.py" .
fi

# v2: parcel watcher platform package is required as a literal require()
if grep -q 'parcel/watcher-' "$CLI_PKG/script/build.ts" 2>/dev/null; then
    W_DIR=node_modules/.bun/@parcel+watcher-freebsd-x64@*/node_modules/@parcel/watcher-freebsd-x64
    for src in $W_DIR; do
        if [ -d "$src" ]; then
            mkdir -p node_modules/@parcel "$CLI_PKG/../core/node_modules/@parcel" 2>/dev/null || true
            [ -d node_modules/@parcel/watcher-freebsd-x64 ] || cp -r "$src" node_modules/@parcel/
            [ -d packages/core/node_modules/@parcel/watcher-freebsd-x64 ] 2>/dev/null || \
                { mkdir -p packages/core/node_modules/@parcel && cp -r "$src" packages/core/node_modules/@parcel/; }
        fi
    done
fi

# --- build -------------------------------------------------------------------
log "compiling opencode $VER"
(cd "$CLI_PKG" && OPENCODE_VERSION="$VER" PATH="$(dirname "$BUN"):$PATH" "$BUN" run script/build.ts $BUILD_FLAGS --skip-install)

if [ "$MAJOR" = 1 ]; then
    OUT=$WORK/$CLI_PKG/dist/opencode-freebsd-x64/bin/opencode
else
    OUT=$WORK/$CLI_PKG/dist/cli-freebsd-x64/bin/opencode
fi
[ -x "$OUT" ] || die "build output missing: $OUT"

[ -n "${SKIP_VERIFY:-}" ] || { log "smoke test"; "$OUT" --version; }

# --- install -----------------------------------------------------------------
# Swap atomically: a running binary keeps "text file busy" on plain cp, and a
# wedge-era process ignores SIGTERM. Copy aside, stop the service if managed,
# kill any leftover processes holding the old binary, then swap and start.
mkdir -p "$INSTALL_PREFIX/$VER/bin" ${LINK:+$(dirname "$LINK")}
cp "$OUT" "$INSTALL_PREFIX/$VER/bin/opencode.new"
chmod 755 "$INSTALL_PREFIX/$VER/bin/opencode.new"

if [ -n "$SERVICE_NAME" ]; then
    log "stopping service $SERVICE_NAME"
    service "$SERVICE_NAME" stop 2>/dev/null || doas service "$SERVICE_NAME" stop 2>/dev/null || true
    running=$(pgrep -f "$INSTALL_PREFIX/$VER/bin/opencode" 2>/dev/null || true)
    if [ -n "$running" ]; then
        log "killing leftover processes holding $INSTALL_PREFIX/$VER/bin/opencode: $running"
        kill $running 2>/dev/null || doas kill $running 2>/dev/null || true
        sleep 1
        kill -9 $running 2>/dev/null || doas kill -9 $running 2>/dev/null || true
    fi
fi

mv "$INSTALL_PREFIX/$VER/bin/opencode.new" "$INSTALL_PREFIX/$VER/bin/opencode"
if [ -n "$LINK" ]; then
    ln -sf "$INSTALL_PREFIX/$VER/bin/opencode" "$LINK"
    log "installed: $INSTALL_PREFIX/$VER/bin/opencode ($LINK updated)"
else
    log "installed: $INSTALL_PREFIX/$VER/bin/opencode"
fi

if [ -n "$SERVICE_NAME" ]; then
    log "starting service $SERVICE_NAME"
    rm -f "/var/run/${SERVICE_NAME}.pid" 2>/dev/null || doas rm -f "/var/run/${SERVICE_NAME}.pid" 2>/dev/null || true
    service "$SERVICE_NAME" start || doas service "$SERVICE_NAME" start
fi

log "done: $OUT -> $VER"
