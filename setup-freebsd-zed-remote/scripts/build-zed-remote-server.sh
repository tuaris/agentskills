#!/bin/sh
#
# build-zed-remote-server - Build and install a FreeBSD-native Zed remote-server
#
# Run this ON THE FREEBSD HOST to build (or rebuild) the `remote_server`
# binary so it matches your local Zed client's exact version, then stage it
# where the Zed client expects to find it.
#
# Background:
#   Zed does not publish prebuilt remote-server binaries for FreeBSD, and its
#   client refuses to even attempt a connection to a FreeBSD host (its
#   parse_platform() only recognizes "Darwin" and "Linux" from `uname -sm`,
#   crates/remote/src/transport.rs). This script:
#     1. Installs a `uname` shim (~/.local/bin/uname) that reports
#        "Linux x86_64" for `-sm` so the client's platform check passes,
#        while passing every other invocation through to the real uname
#        untouched.
#     2. Wires that shim ahead of /usr/bin in PATH via a fish conf.d snippet,
#        since fish's usual config.fish is only sourced for interactive
#        sessions and Zed's SSH connections are non-interactive.
#     3. Clones (or updates) the Zed source at the exact commit embedded in
#        your client's version string, applies the FreeBSD compile-fix patch
#        bundled alongside this script, and builds `remote_server` natively.
#     4. Strips debug symbols and stages the binary at
#        ~/.zed_server/zed-remote-server-<channel>-<full-version>, the exact
#        path/filename the client looks for.
#
# IMPORTANT - re-run this BEFORE reconnecting after every Zed client upgrade:
#   Because the uname shim makes the client believe this host is Linux, a
#   version mismatch (staged binary older than the client) will make Zed try
#   to download and run a real Linux ELF binary here, which will fail (this
#   host has no Linux ABI compat layer enabled - the Zed remote-server is a
#   native FreeBSD build instead, unlike the separate Devin/Windsurf FreeBSD
#   setup which does use the Linux compat layer for its own Linux binary).
#   Always rebuild for the new version BEFORE reconnecting.
#
# Usage:
#   build-zed-remote-server.sh [-f] [-c channel] <full-version-string>
#     -f, --force     Rebuild even if already staged for this version.
#     -c, --channel   Release channel (default: stable).
#     <full-version-string>
#                     The value after "Version:" in Zed's About dialog, or the
#                     "starting zed version ..." line in
#                     ~/.local/share/zed/logs/Zed.log (on the LOCAL machine
#                     running the Zed client, not this FreeBSD host), e.g.
#                     1.18.1+stable.352.bebe92f469834a287f5a57ed78e8d51a918b8ada
#
# Environment overrides (all default to locations OFF the root filesystem -
# see note below):
#   BUILD_ROOT      Parent dir for source checkout + build artifacts.
#                    Default: $HOME/Documents/Code/zed-remote-build
#   JOBS             Parallel cargo build jobs. Default: unset (cargo default).
#
# Note on disk space: freebsd-dev1's root filesystem (/) runs close to full.
# This script deliberately keeps the source checkout, Cargo registry/target
# dirs, and TMPDIR all under BUILD_ROOT (a separate ZFS dataset under
# ~/Documents/Code by default) - do not override these onto root-resident
# paths (e.g. /tmp, or bare $HOME if it's not itself a separate dataset) when
# customizing.
#

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH_FILE="${SCRIPT_DIR}/freebsd-remote-server.patch"

BUILD_ROOT="${BUILD_ROOT:-${HOME}/Documents/Code/zed-remote-build}"
REPO_DIR="${BUILD_ROOT}/zed"
CARGO_TARGET_DIR="${BUILD_ROOT}/target"
CARGO_HOME_DIR="${BUILD_ROOT}/.cargo"
TMPDIR_BUILD="${BUILD_ROOT}/tmp"
STAGE_DIR="${HOME}/.zed_server"

CHANNEL="stable"
FORCE=0
FULL_VERSION=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force)   FORCE=1 ;;
        -c|--channel) shift; CHANNEL="$1" ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *)            FULL_VERSION="$1" ;;
    esac
    shift
done

if [ -z "${FULL_VERSION}" ]; then
    echo "ERROR: missing required <full-version-string> argument." >&2
    echo "" >&2
    usage >&2
    exit 1
fi

# The version string looks like 1.18.1+stable.352.bebe92f469834a287f...
# The commit SHA is always the last dot-separated segment.
COMMIT=$(echo "${FULL_VERSION}" | sed 's/.*\.//')
case "${COMMIT}" in
    *[!0-9a-f]*|"")
        echo "ERROR: could not extract a commit SHA from '${FULL_VERSION}'." >&2
        echo "Expected a trailing dot-separated hex commit, e.g. ...352.bebe92f4698..." >&2
        exit 1
        ;;
esac

STAGE_NAME="zed-remote-server-${CHANNEL}-${FULL_VERSION}"
STAGE_PATH="${STAGE_DIR}/${STAGE_NAME}"

echo "Target version : ${FULL_VERSION}"
echo "Channel        : ${CHANNEL}"
echo "Commit         : ${COMMIT}"
echo "Stage path     : ${STAGE_PATH}"
echo ""

if [ -x "${STAGE_PATH}" ] && [ "${FORCE}" -ne 1 ]; then
    echo "Already staged at ${STAGE_PATH}"
    echo "Use -f/--force to rebuild anyway."
    exit 0
fi

if [ ! -f "${PATCH_FILE}" ]; then
    echo "ERROR: patch file not found: ${PATCH_FILE}" >&2
    exit 1
fi

# --- 1. uname shim ---------------------------------------------------------
UNAME_SHIM="${HOME}/.local/bin/uname"
mkdir -p "${HOME}/.local/bin"
if [ ! -x "${UNAME_SHIM}" ] || ! grep -q 'Linux x86_64' "${UNAME_SHIM}" 2>/dev/null; then
    echo "Installing uname shim at ${UNAME_SHIM} ..."
    cat > "${UNAME_SHIM}" <<'EOF'
#!/bin/sh
# Makes Zed's client-side parse_platform() (crates/remote/src/transport.rs)
# treat this FreeBSD host as Linux, since it hard-rejects any other
# `uname -sm` output before ever checking for a staged remote-server binary.
# Every other invocation passes through to the real uname untouched.
if [ "$1" = "-sm" ]; then
    echo "Linux x86_64"
else
    exec /usr/bin/uname "$@"
fi
EOF
    chmod +x "${UNAME_SHIM}"
else
    echo "uname shim already installed at ${UNAME_SHIM}"
fi

# --- 2. PATH wiring for non-interactive fish sessions -----------------------
FISH_CONF_DIR="${HOME}/.config/fish/conf.d"
FISH_CONF_FILE="${FISH_CONF_DIR}/00-local-bin-path.fish"
if [ ! -f "${FISH_CONF_FILE}" ]; then
    echo "Installing fish PATH snippet at ${FISH_CONF_FILE} ..."
    mkdir -p "${FISH_CONF_DIR}"
    cat > "${FISH_CONF_FILE}" <<'EOF'
# Ensures ~/.local/bin (and its uname shim) wins over /usr/bin for every fish
# invocation, including the non-interactive ones Zed uses over SSH - unlike
# config.fish, files under conf.d/ are sourced unconditionally.
if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end
EOF
else
    echo "fish PATH snippet already installed at ${FISH_CONF_FILE}"
fi

# --- 3. Dependency check -----------------------------------------------------
missing=""
for bin in git cargo rustc cmake gmake pkgconf llvm-objcopy; do
    command -v "${bin}" >/dev/null 2>&1 || missing="${missing} ${bin}"
done
if [ -n "${missing}" ]; then
    echo "ERROR: missing required tool(s):${missing}" >&2
    echo "Install via pkg, e.g.: pkg install git cmake gmake pkgconf rust llvm" >&2
    exit 1
fi

echo ""
echo "Using: $(rustc --version)"
echo "       $(cargo --version)"
echo "(rust-toolchain.toml in the Zed source may request a newer pinned"
echo " version; without rustup installed, cargo/rustc silently fall back to"
echo " the system toolchain above instead. This has worked in practice, but"
echo " if the build fails with odd language-feature errors, that mismatch is"
echo " the first thing to suspect.)"
echo ""

# --- 4. Fetch source at the exact commit ------------------------------------
mkdir -p "${BUILD_ROOT}" "${CARGO_TARGET_DIR}" "${CARGO_HOME_DIR}" "${TMPDIR_BUILD}"

if [ -d "${REPO_DIR}/.git" ]; then
    echo "Updating existing checkout at ${REPO_DIR} ..."
    cd "${REPO_DIR}"
    git checkout -q -- . 2>/dev/null || true
    git clean -fdq
    git fetch --depth 1 origin "${COMMIT}"
    git checkout -q FETCH_HEAD
else
    echo "Cloning Zed source into ${REPO_DIR} ..."
    mkdir -p "${REPO_DIR}"
    cd "${REPO_DIR}"
    git init -q
    git remote add origin https://github.com/zed-industries/zed.git
    git fetch --depth 1 origin "${COMMIT}"
    git checkout -q FETCH_HEAD
fi

echo "Checked out: $(git log -1 --oneline)"

# --- 5. Apply the FreeBSD patch ----------------------------------------------
echo ""
echo "Applying FreeBSD patch ..."
if ! git apply --check "${PATCH_FILE}" 2>/dev/null; then
    echo "ERROR: patch does not apply cleanly against this commit." >&2
    echo "Zed's source has likely changed in ways that need a refreshed patch." >&2
    echo "See the 'Updating the patch' section in this skill's SKILL.md." >&2
    exit 1
fi
git apply "${PATCH_FILE}"

# --- 6. Build -----------------------------------------------------------------
echo ""
echo "Building remote_server (this can take 30-60+ minutes on modest/shared"
echo "hardware - it's a full release build with LTO) ..."

CARGO_BUILD_JOBS_ARGS=""
[ -n "${JOBS:-}" ] && CARGO_BUILD_JOBS_ARGS="--jobs ${JOBS}"

env \
    TMPDIR="${TMPDIR_BUILD}" \
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR}" \
    CARGO_HOME="${CARGO_HOME_DIR}" \
    cargo build --release --package remote_server ${CARGO_BUILD_JOBS_ARGS}

BUILT_BIN="${CARGO_TARGET_DIR}/release/remote_server"
if [ ! -x "${BUILT_BIN}" ]; then
    echo "ERROR: build did not produce ${BUILT_BIN}" >&2
    exit 1
fi

# --- 7. Strip + stage ---------------------------------------------------------
echo ""
echo "Stripping debug symbols ..."
STRIPPED_BIN="${BUILD_ROOT}/remote_server-${FULL_VERSION}"
rm -f "${STRIPPED_BIN}"
llvm-objcopy --strip-debug "${BUILT_BIN}" "${STRIPPED_BIN}"
chmod +x "${STRIPPED_BIN}"

mkdir -p "${STAGE_DIR}"
ln -sf "${STRIPPED_BIN}" "${STAGE_PATH}"

echo ""
echo "Verifying ..."
"${STAGE_PATH}" version
file "${STAGE_PATH}" 2>/dev/null || true

echo ""
echo "Staged at: ${STAGE_PATH}"
echo "Reconnect from your local Zed client now."
