#!/bin/sh
#
# build-cline-remote-helper - Build and stage a NATIVE FreeBSD Cline CLI/Hub
# helper for Cline Desktop's SSH remote mode (skill: setup-freebsd-cline)
#
# Why native: the helper Cline Desktop normally uploads is a Linux glibc
# binary that runs under FreeBSD's Linuxulator. The Linuxulator's path
# redirection between the native tree and /compat/linux causes problems for
# some file reads/writes. The Cline CLI and Hub are open source (Apache-2.0,
# github.com/cline/cline, apps/cli + apps/cline-hub) and are compiled with
# Bun, which publishes official FreeBSD builds, so the helper can be built
# natively on the host - the same pattern as setup-freebsd-zed-remote.
#
# Version handling (both styles supported):
#   Zed-style pin:    build-cline-remote-helper.sh 3.0.74
#   Devin-style auto: build-cline-remote-helper.sh
#       Auto-detects the version from the helper Cline Desktop has staged in
#       ~/.cline/remote/ (it uploads one on connect), falling back to the
#       newest cli-v* release tag on GitHub if none is staged.
#   Cline CLI releases are tagged cli-v<version> in github.com/cline/cline.
#
# Usage:
#   build-cline-remote-helper.sh [-f] [VERSION]
#     -f, --force   Rebuild even if this version is already staged.
#     VERSION       CLI version to build (default: auto-detect, see above).
#
# Requirements: git, curl, bun 1.4+ (native), ~3 GB free disk for the
# source tree + node_modules. CLINE_SRC_DIR overrides the source location
# (default ~/Documents/Code/cline-cli) - use a separate dataset if the root
# filesystem is tight.
#
# The build is the repo's own pipeline (apps/cli/script/build.ts --single),
# with three local-only patches to the build tree (idempotent, re-applied on
# each fresh checkout):
#   1. freebsd added to the compile target matrix (bun-freebsd-x64)
#   2. bun install runs with --ignore-scripts: grpc-tools (an SDK dev
#      dependency) downloads a gRPC binary that does not exist for FreeBSD,
#      and no postinstall output is needed by the CLI/Hub build
#   3. the hub webview uses @vitejs/plugin-react (babel) instead of
#      @vitejs/plugin-react-swc: @swc/core publishes no FreeBSD bindings
# The repo's own smoke tests run natively at the end: the binary must report
# the exact version and answer a hub start/status/stop cycle in an isolated
# HOME, followed by a live hub ensure/stop using the app's exact launch.
#
# After staging, the native binary replaces the app's Linux helper at
# ~/.cline/remote/cline-x86_64-unknown-linux-gnu (the name the app derives
# from the probed platform; the previous helper is kept as
# cline-x86_64-unknown-linux-gnu.linux-elf). Note: when Cline Desktop itself
# updates, it re-uploads the official Linux helper - re-run this script
# (no arguments) to rebuild for the new version and stage the native one.
#

set -eu

REPO="https://github.com/cline/cline"
SRC="${CLINE_SRC_DIR:-$HOME/Documents/Code/cline-cli}"
REMOTE_DIR="$HOME/.cline/remote"
ACTIVE="$REMOTE_DIR/cline-x86_64-unknown-linux-gnu"
BUILD_MARKER="$SRC/.native-built-version"
DEPS_MARKER="$SRC/.native-deps-version"
VERSION=""
FORCE=0

fail() {
    echo "  FAIL: $*" >&2
    exit 1
}

ok() {
    echo "  ok: $*"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *)
            [ -z "${VERSION}" ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }
            case "$1" in
                [0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
                *) echo "ERROR: VERSION must look like 3.0.74 (got: $1)" >&2; exit 2 ;;
            esac ;;
    esac
    shift
done

for tool in git curl bun; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: ${tool}" >&2
        exit 1
    }
done
echo "Using bun $(bun --version) on $(uname -s) $(uname -m)"

# --- 1. Resolve the target version ------------------------------------------
echo "Version:"
if [ -z "${VERSION}" ] && [ -x "${ACTIVE}" ]; then
    STAGED_VERSION=$("${ACTIVE}" --version 2>/dev/null | head -1)
    if [ -n "${STAGED_VERSION}" ]; then
        VERSION="${STAGED_VERSION}"
        echo "  auto-detected ${VERSION} from the staged helper"
    fi
fi
if [ -z "${VERSION}" ]; then
    echo "  no staged helper; falling back to newest cli-v* tag on GitHub"
    VERSION=$(git ls-remote --tags "${REPO}" 2>/dev/null \
        | sed -n 's|.*refs/tags/cli-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [ -n "${VERSION}" ] || { echo "ERROR: could not resolve a version" >&2; exit 1; }
    echo "  using newest release tag: ${VERSION}"
fi
TAG="cli-v${VERSION}"
echo "  building ${TAG} natively into ${ACTIVE}"

# --- 2. Already staged? -------------------------------------------------------
if [ "${FORCE}" -eq 0 ] && [ -x "${ACTIVE}" ] && [ -f "${BUILD_MARKER}" ]; then
    if [ "$(cat "${BUILD_MARKER}")" = "${VERSION}" ] \
        && [ "$("${ACTIVE}" --version 2>/dev/null | head -1)" = "${VERSION}" ] \
        && file "${ACTIVE}" | grep -q FreeBSD; then
        ok "native helper ${VERSION} already staged at ${ACTIVE} (use -f to rebuild)"
        exit 0
    fi
fi

# --- 3. Source tree ------------------------------------------------------------
echo "Source tree:"
if [ -d "${SRC}/.git" ] && git -C "${SRC}" remote get-url origin 2>/dev/null | grep -q "cline/cline"; then
    CURRENT_TAG=$(git -C "${SRC}" describe --tags --exact-match 2>/dev/null || true)
    if [ "${CURRENT_TAG}" = "${TAG}" ]; then
        ok "existing checkout is at ${TAG}"
    else
        echo "  fetching ${TAG} into existing tree (was: ${CURRENT_TAG:-unknown}) ..."
        git -C "${SRC}" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}"
        git -C "${SRC}" checkout -f -q "refs/tags/${TAG}"
        ok "checked out ${TAG}"
    fi
else
    rm -rf "${SRC}"
    mkdir -p "$(dirname "${SRC}")"
    git clone --depth 1 --branch "${TAG}" "${REPO}" "${SRC}"
    ok "cloned ${TAG}"
fi
CHECKOUT_VERSION=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "${SRC}/apps/cli/package.json" | head -1)
if [ "${CHECKOUT_VERSION}" != "${VERSION}" ]; then
    fail "checkout reports version ${CHECKOUT_VERSION}, expected ${VERSION}"
fi
ok "apps/cli version is ${CHECKOUT_VERSION}"

# Local-only build patches (idempotent; a fresh checkout re-patches).
if ! grep -q 'os: "freebsd"' "${SRC}/apps/cli/script/build.ts"; then
    sed -i.bak 's|{ os: "win32", arch: "arm64" },|{ os: "win32", arch: "arm64" },\n\t{ os: "freebsd", arch: "x64" },|' \
        "${SRC}/apps/cli/script/build.ts" \
        || fail "could not patch the build matrix"
    ok "patched build matrix: added freebsd target"
fi
WEBVIEW="${SRC}/apps/cline-hub/src/webview"
if grep -q 'plugin-react-swc' "${WEBVIEW}/vite.config.ts" 2>/dev/null; then
    (
        cd "${WEBVIEW}"
        bun add -d "@vitejs/plugin-react@^4.3.0" >/dev/null 2>&1
        sed -i.bak 's|@vitejs/plugin-react-swc|@vitejs/plugin-react|' vite.config.ts
    ) || fail "could not patch the webview build"
    ok "patched webview build: babel react plugin (no @swc/core)"
fi

# --- 4. Dependencies ------------------------------------------------------------
echo "Dependencies:"
if [ -d "${SRC}/node_modules" ] && [ "$(cat "${DEPS_MARKER}" 2>/dev/null)" = "${VERSION}" ]; then
    ok "node_modules present for ${VERSION}"
else
    echo "  bun install (postinstall scripts skipped) ..."
    rm -rf "${SRC}/node_modules"
    if ! (cd "${SRC}" && bun install --ignore-scripts 2>&1 | tail -4); then
        echo "  install failed; clearing bun cache and retrying once ..."
        rm -rf "${SRC}/node_modules" "${HOME}/.bun/install/cache"
        (cd "${SRC}" && bun install --ignore-scripts 2>&1 | tail -4) \
            || fail "bun install failed"
    fi
    echo "${VERSION}" > "${DEPS_MARKER}"
    ok "dependencies installed"
fi

# --- 5. Build (the repo's own pipeline, host target) ----------------------------
echo "Build:"
# build.ts --single compiles for the host (bun-freebsd-x64 after the patch)
# and runs its native smoke tests: --version must match, and a hub
# start/status/stop cycle must pass in an isolated HOME.
if ! (cd "${SRC}/apps/cli" && bun script/build.ts --single 2>&1 | tail -15); then
    fail "build failed (see output above)"
fi
BINARY="${SRC}/apps/cli/dist/cli-freebsd-x64/bin/cline"
[ -x "${BINARY}" ] || fail "expected binary not found: ${BINARY}"
file "${BINARY}" | grep -q FreeBSD || fail "binary is not a native FreeBSD ELF: $(file "${BINARY}")"
BUILT_VERSION=$("${BINARY}" --version 2>/dev/null | head -1)
[ "${BUILT_VERSION}" = "${VERSION}" ] || fail "binary reports ${BUILT_VERSION}, expected ${VERSION}"
ok "native binary built and smoke-tested: ${BUILT_VERSION}"

# --- 6. Stage it where Cline Desktop expects ------------------------------------
echo "Staging:"
mkdir -p "${REMOTE_DIR}"
if [ -e "${ACTIVE}" ] && file "${ACTIVE}" | grep -qv FreeBSD; then
    cp -p "${ACTIVE}" "${ACTIVE}.linux-elf"
    ok "previous Linux helper kept as ${ACTIVE##*/}.linux-elf"
fi
install -m 755 "${BINARY}" "${ACTIVE}"
echo "${VERSION}" > "${BUILD_MARKER}"
ok "staged native helper at ${ACTIVE}"

# --- 7. Live verification (the app's exact launch, native) ----------------------
echo "Live hub check:"
DISC="${REMOTE_DIR}/native-check.$$"
mkdir -p "${REMOTE_DIR}"
if /bin/bash -c "env CLINE_NO_AUTO_UPDATE=1 CLINE_HUB_LAUNCHER_CLIENT='setup-verify' CLINE_HUB_LAUNCHER_TRANSPORT=ssh '${ACTIVE}' hub ensure --json --allow-port-fallback --no-connectors --login-shell-path --cwd '${HOME}' --host 127.0.0.1 --port 0 --pathname /hub --discovery-path '${DISC}'" > "${DISC}.json" 2>/dev/null; then
    HUB_URL=$(sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' "${DISC}.json" | head -1)
    if [ -n "${HUB_URL}" ]; then
        ok "hub is up: ${HUB_URL}"
    else
        echo "  FAIL: hub ensure returned no url: $(cat "${DISC}.json")" >&2
        LIVEDOWN=1
    fi
else
    echo "  FAIL: hub ensure failed with the app's exact launch command" >&2
    LIVEDOWN=1
fi
# Always stop, so a verification failure never leaves a hub behind.
"${ACTIVE}" hub stop --discovery-path "${DISC}" >/dev/null 2>&1
rm -rf "${DISC}" "${DISC}.json" "${DISC}".instance.lock*
[ "${LIVEDOWN:-0}" -eq 0 ] || exit 1
ok "hub stopped"

echo ""
echo "Native Cline helper ${VERSION} is staged and verified."
echo "Connect from Cline Desktop as usual; the app will use this binary."
echo "If Cline Desktop updates and re-uploads its Linux helper, re-run"
echo "this script (no arguments) to restore the native build."
[ "${FAILURES:-0}" -eq 0 ]