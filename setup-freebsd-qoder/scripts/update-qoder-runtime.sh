#!/bin/sh
#
# update-qoder-runtime - pre-seed, update, or repair the Qoder remote runtime
#
# Qoder Desktop normally AUTO-INSTALLS its remote runtime on first connect once
# the host is prepared by setup-freebsd-qoder-remote. This helper does the same
# install ahead of time (instant first connect, or to repair a broken install),
# using the exact manifest, checksums, and install logic the client itself uses.
#
# The runtime is a set of Linux ELF binaries (Node.js + host + worker) that run
# under the FreeBSD Linuxulator. It installs into:
#   ~/.qoder/remote/protocol-v1/{cache,installs,current}
#
# The manifest is keyed by the client's runtime version AND commit (there is no
# "latest" endpoint). The defaults below match Qoder Desktop 0.5.7; override them
# for a different client build. The last-used pair is remembered in
# ~/.qoder/remote/protocol-v1/.runtime-manifest-state so a plain re-run reuses it.
#
# Usage:
#   update-qoder-runtime [-f] [--version V] [--commit C]
#     -f, --force     Reinstall even if the matching runtime is already present.
#     --version V     Runtime version (e.g. 0.5.7).
#     --commit C      Runtime commit hash (from the client build).
#
# Requires: curl, jq, and the shims from setup-freebsd-qoder-remote.

set -eu

BASE_DIR="${HOME}/.qoder/remote/protocol-v1"
CACHE_DIR="${BASE_DIR}/cache"
STATE_FILE="${BASE_DIR}/.runtime-manifest-state"
MANIFEST_BASE="https://download.qoder.com/qoder-app/releases/remote-runtime"
CONFIG_DIR=".qoder"

# Defaults match Qoder Desktop 0.5.7. Override for other builds.
DEFAULT_VERSION="0.5.7"
DEFAULT_COMMIT="73fe8d7343fbbbc3fb5ec665489082f6e4db0128"

FORCE=0
VERSION=""
COMMIT=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force)  FORCE=1 ;;
        --version)   VERSION="$2"; shift ;;
        --commit)    COMMIT="$2"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq is required (doas pkg install -y jq)" >&2; exit 1; }

# Resolve version + commit: explicit args > remembered state > baked defaults.
if [ -z "${VERSION}" ] || [ -z "${COMMIT}" ]; then
    if [ -f "${STATE_FILE}" ]; then
        read -r S_VERSION S_COMMIT < "${STATE_FILE}" || true
        [ -n "${VERSION}" ] || VERSION="${S_VERSION:-}"
        [ -n "${COMMIT}" ]  || COMMIT="${S_COMMIT:-}"
    fi
fi
[ -n "${VERSION}" ] || VERSION="${DEFAULT_VERSION}"
[ -n "${COMMIT}" ]  || COMMIT="${DEFAULT_COMMIT}"

# Target triple from the host architecture (the runtime is always Linux/glibc).
case "$(uname -m)" in
    x86_64|amd64)  ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
TARGET="linux-${ARCH}-gnu"

MANIFEST_URL="${MANIFEST_BASE}/${VERSION}/${COMMIT}/manifest.json"
echo "Fetching manifest: ${VERSION} / ${COMMIT} (${TARGET})"
MANIFEST_JSON="$(curl -fsSL --connect-timeout 15 "${MANIFEST_URL}")" || {
    echo "ERROR: failed to fetch manifest: ${MANIFEST_URL}" >&2
    echo "Check the version/commit pair and network access." >&2
    exit 1
}

# Pull the component URLs, checksums, and sizes for this target.
HOST_URL="$(printf '%s' "${MANIFEST_JSON}"   | jq -r ".targets[\"${TARGET}\"].components.host.url")"
HOST_SHA="$(printf '%s' "${MANIFEST_JSON}"   | jq -r ".targets[\"${TARGET}\"].components.host.sha256")"
HOST_SIZE="$(printf '%s' "${MANIFEST_JSON}"  | jq -r ".targets[\"${TARGET}\"].components.host.size")"
WORKER_URL="$(printf '%s' "${MANIFEST_JSON}" | jq -r ".targets[\"${TARGET}\"].components.worker.url")"
WORKER_SHA="$(printf '%s' "${MANIFEST_JSON}" | jq -r ".targets[\"${TARGET}\"].components.worker.sha256")"
WORKER_SIZE="$(printf '%s' "${MANIFEST_JSON}"| jq -r ".targets[\"${TARGET}\"].components.worker.size")"
NODE_URL="$(printf '%s' "${MANIFEST_JSON}"   | jq -r ".targets[\"${TARGET}\"].components.node.url")"
NODE_SHA="$(printf '%s' "${MANIFEST_JSON}"   | jq -r ".targets[\"${TARGET}\"].components.node.sha256")"
NODE_SIZE="$(printf '%s' "${MANIFEST_JSON}"  | jq -r ".targets[\"${TARGET}\"].components.node.size")"
WORKER_VERSION="$(printf '%s' "${MANIFEST_JSON}" | jq -r ".targets[\"${TARGET}\"].workerVersion")"

if [ -z "${HOST_URL}" ] || [ "${HOST_URL}" = "null" ]; then
    echo "ERROR: manifest has no ${TARGET} target." >&2; exit 1
fi

echo "  Host:   ${HOST_SHA}"
echo "  Worker: ${WORKER_SHA} (${WORKER_VERSION})"
echo "  Node:   ${NODE_SHA}"

# Already installed? Compare the active install's version + host checksum.
if [ "${FORCE}" -ne 1 ] && [ -f "${BASE_DIR}/current/.runtime-version" ] \
    && [ -f "${BASE_DIR}/current/.components" ]; then
    CUR_VERSION="$(cat "${BASE_DIR}/current/.runtime-version" 2>/dev/null || true)"
    CUR_HOST_SHA="$(sed -n '1p' "${BASE_DIR}/current/.components" 2>/dev/null || true)"
    if [ "${CUR_VERSION}" = "${VERSION}" ] && [ "${CUR_HOST_SHA}" = "${HOST_SHA}" ]; then
        echo ""
        echo "Runtime ${VERSION} already installed at ${BASE_DIR}/current"
        echo "Use -f to force a reinstall."
        exit 0
    fi
fi

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# download_component <url> <sha> <size>: fetch into the cache, verify, keep.
download_component() {
    d_url="$1"; d_sha="$2"; d_size="$3"
    archive="${CACHE_DIR}/${d_sha}.tar.gz"
    if [ -f "${archive}" ] \
        && [ "$(wc -c < "${archive}" | tr -d ' ')" = "${d_size}" ] \
        && [ "$(sha256_file "${archive}")" = "${d_sha}" ]; then
        echo "  cached: $(basename "${archive}")"
        return 0
    fi
    echo "  downloading: $(basename "${d_url}")"
    partial="${archive}.partial.$$"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 540 --output "${partial}" "${d_url}" || {
        rm -f "${partial}"; echo "ERROR: download failed: ${d_url}" >&2; return 1; }
    [ "$(wc -c < "${partial}" | tr -d ' ')" = "${d_size}" ] || {
        rm -f "${partial}"; echo "ERROR: size mismatch: ${d_url}" >&2; return 1; }
    [ "$(sha256_file "${partial}")" = "${d_sha}" ] || {
        rm -f "${partial}"; echo "ERROR: checksum mismatch: ${d_url}" >&2; return 1; }
    mv "${partial}" "${archive}"
}

mkdir -p "${CACHE_DIR}"
echo "Downloading components..."
download_component "${HOST_URL}"   "${HOST_SHA}"   "${HOST_SIZE}"
download_component "${WORKER_URL}" "${WORKER_SHA}" "${WORKER_SIZE}"
download_component "${NODE_URL}"   "${NODE_SHA}"   "${NODE_SIZE}"

# Run Qoder's own install script (verbatim): it verifies checksums, extracts,
# smoke-tests host + worker, atomically swaps `current`, and rolls back on a
# failed health check. Args: version target host_sha worker_sha node_sha
# system_node context_sha config_dir. Bundled node is used (system_node="-"),
# and there is no context component (context_sha="-").
INSTALL_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/qoder-install.XXXXXX")"
trap 'rm -f "${INSTALL_SCRIPT}"' EXIT INT TERM
cat > "${INSTALL_SCRIPT}" <<'QODER_INSTALL_SCRIPT'
set -eu
version=$1
target=$2
host_sha=$3
worker_sha=$4
node_sha=$5
system_node=$6
context_sha=$7
config_dir=$8
base="$HOME/$config_dir/remote/protocol-v1"
lock="$base/locks/install.lock"
version_dir="$base/installs/$version"
install="$version_dir/$target.$(date +%s).$$"
staging="$base/installs/.$version-$target.partial.$$"
step_log="$staging.log"
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
replace_link() {
  case "$(uname -s)" in
    Darwin) mv -hf "$1" "$2" ;;
    *) mv -Tf "$1" "$2" ;;
  esac
}
umask 077
mkdir -p "$base/locks" "$version_dir"
if ! mkdir "$lock" 2>/dev/null; then
  lock_age=$(( $(date +%s) - $(file_mtime "$lock") ))
  if test "$lock_age" -gt 600; then rm -rf "$lock"; mkdir "$lock"; else echo "runtime install is locked" >&2; exit 30; fi
fi
# rmdir 只删空目录：安装成功后 version_dir 已包含 install，只有失败留下的空版本目录墓碑会被清掉。
trap 'rm -rf "$staging"; rm -f "$step_log"; rm -rf "$lock"; rmdir "$version_dir" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$staging"
# run_step <步骤标签> <退出码> <命令...>：失败时同时上报稳定步骤标签和远端真实 stderr 尾部，便于定位具体失败位置。
run_step() {
  step_id=$1
  step_code=$2
  shift 2
  if "$@" >/dev/null 2>"$step_log"; then return 0; fi
  echo "runtime install step failed: $step_id" >&2
  tail -n 20 "$step_log" >&2 || true
  exit "$step_code"
}
component_shas="$host_sha $worker_sha"
if test "$context_sha" != "-"; then component_shas="$component_shas $context_sha"; fi
for sha in $component_shas; do
  archive="$base/cache/$sha.tar.gz"
  test -f "$archive" || { echo "runtime component is missing" >&2; exit 32; }
  test "$(sha256_file "$archive")" = "$sha" || { echo "runtime checksum mismatch" >&2; exit 31; }
  run_step extract-archive 33 tar -xzf "$archive" -C "$staging"
done
if test "$node_sha" != "-"; then
  archive="$base/cache/$node_sha.tar.gz"
  test -f "$archive" || { echo "runtime node component is missing" >&2; exit 32; }
  test "$(sha256_file "$archive")" = "$node_sha" || { echo "runtime checksum mismatch" >&2; exit 31; }
  run_step extract-archive 33 tar -xzf "$archive" -C "$staging"
else
  test -x "$system_node" || { echo "compatible system node disappeared" >&2; exit 37; }
  mkdir -p "$staging/bin"
  ln -s "$system_node" "$staging/bin/node"
fi
test -x "$staging/bin/qoder-runtime-host" || { echo "runtime host is missing" >&2; exit 32; }
test -x "$staging/bin/qoder-worker-runtime" || { echo "runtime worker is missing" >&2; exit 32; }
test -x "$staging/bin/node" || { echo "runtime node is missing" >&2; exit 32; }
printf '%s\n' "$version" > "$staging/.runtime-version"
printf '%s\n%s\n%s\n%s\n' "$host_sha" "$worker_sha" "$node_sha" "$context_sha" > "$staging/.components"
run_step host-smoke 38 "$staging/bin/qoder-runtime-host" --version
run_step worker-smoke 39 "$staging/bin/qoder-worker-runtime" --version
mv "$staging" "$install"
previous_target=""
if test -L "$base/current"; then previous_target=$(readlink "$base/current" || true); fi
ln -s "$install" "$base/current.next.$$"
replace_link "$base/current.next.$$" "$base/current"
activation_healthy=true
if ! "$base/current/bin/qoder-runtime-host" --version >/dev/null 2>"$step_log" \
  || ! "$base/current/bin/qoder-worker-runtime" --version >/dev/null 2>>"$step_log"; then
  activation_healthy=false
fi
if test "$activation_healthy" != true; then
  rm -f "$base/current"
  if test -n "$previous_target"; then ln -s "$previous_target" "$base/current"; fi
  echo "runtime install step failed: activation-health" >&2
  echo "runtime health check failed and previous version was restored" >&2
  tail -n 20 "$step_log" >&2 || true
  exit 34
fi
rm -f "$base/previous"
if test -n "$previous_target" && test -d "$previous_target"; then ln -s "$previous_target" "$base/previous"; fi
for candidate in "$base"/installs/*/*; do
  test -d "$candidate" || continue
  case "$candidate" in "$install"|"$previous_target") ;; *) rm -rf -- "$candidate" ;; esac
done
for cached in "$base"/cache/*.tar.gz; do
  test -f "$cached" || continue
  cached_sha=$(basename "$cached" .tar.gz)
  keep=false
  for referenced_install in "$install" "$previous_target"; do
    if test -f "$referenced_install/.components" && grep -qx "$cached_sha" "$referenced_install/.components"; then
      keep=true
    fi
  done
  test "$keep" = true || rm -f "$cached"
done
rm -f "$step_log"
# 顺带清掉历史安装失败留下的空版本目录；rmdir 遇到非空目录会失败并被忽略。
for stale_version in "$base"/installs/*; do
  test -d "$stale_version" || continue
  rmdir "$stale_version" 2>/dev/null || true
done
rm -rf "$lock"
trap - EXIT INT TERM
QODER_INSTALL_SCRIPT

echo "Installing runtime (extract + smoke test + atomic swap)..."
sh -s -- "${VERSION}" "${TARGET}" "${HOST_SHA}" "${WORKER_SHA}" "${NODE_SHA}" "-" "-" "${CONFIG_DIR}" \
    < "${INSTALL_SCRIPT}" || {
    echo "ERROR: runtime install failed (see step output above)." >&2
    exit 1
}

# Remember the pair for the next run.
printf '%s %s\n' "${VERSION}" "${COMMIT}" > "${STATE_FILE}"

echo ""
echo "Verifying..."
"${BASE_DIR}/current/bin/qoder-runtime-host" --version
echo ""
echo "Qoder remote runtime ${VERSION} (${WORKER_VERSION}) installed at ${BASE_DIR}/current"
echo "Connect from Qoder Desktop; it will detect the runtime and skip the download."