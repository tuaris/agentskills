#!/bin/sh
#
# update-vscode-server - Download and install the matching VS Code remote server
#
# Run this on the FreeBSD host after upgrading the VS Code client. Remote-SSH
# cannot auto-install a server on FreeBSD, so this script installs the Linux
# REH build that matches the client's commit; it runs under the Linux ABI layer.
#
# How it works:
#   * Connect from VS Code once. The bootstrap leaves an empty placeholder
#       ~/.vscode-server/bin/<commit>/
#     or
#       ~/.vscode-server/cli/servers/Stable-<commit>/
#     and then fails.
#   * This script detects that <commit>, asks the VS Code update API for the
#     exact download URL, version and SHA-256, installs the server, applies the
#     remote settings and extension host patch, then you reconnect.
#
# Usage:
#   update-vscode-server [-f] [COMMIT]
#     -f, --force   Reinstall even if the server is already present.
#     COMMIT        Target commit hash. If omitted, it is auto-detected from the
#                   placeholder directory left by a failed connection attempt.
#                   It is also shown in the client under Help > About.
#
# Requires: curl, jq, perl, tar.
#

set -eu

SERVER_DATA_DIR="${HOME}/.vscode-server"
SERVER_BIN_DIR="${SERVER_DATA_DIR}/bin"
CLI_SERVERS_DIR="${SERVER_DATA_DIR}/cli/servers"
SERVER_APP_NAME="code-server"

PLATFORM="linux"
ARCH="x64"
QUALITY="stable"
API="https://update.code.visualstudio.com"

FORCE=0
COMMIT=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *)          COMMIT="$1" ;;
    esac
    shift
done

for tool in curl jq perl tar; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: ${tool}" >&2
        exit 1
    }
done

is_installed() {
    [ -x "${SERVER_BIN_DIR}/$1/bin/${SERVER_APP_NAME}" ]
}

# Auto-detect the target commit. A failed connection leaves a placeholder
# without a server binary; that is the install target. With none pending, fall
# back to the newest installed commit so -f can reinstall it and a plain run
# reports "already installed".
if [ -z "${COMMIT}" ]; then
    PENDING=""
    INSTALLED=""
    if [ -d "${SERVER_BIN_DIR}" ]; then
        for d in $(ls -1t "${SERVER_BIN_DIR}" 2>/dev/null); do
            [ -d "${SERVER_BIN_DIR}/${d}" ] || continue
            if is_installed "${d}"; then
                [ -z "${INSTALLED}" ] && INSTALLED="${d}"
            else
                [ -z "${PENDING}" ] && PENDING="${d}"
            fi
        done
    fi
    if [ -z "${PENDING}" ] && [ -d "${CLI_SERVERS_DIR}" ]; then
        for d in $(ls -1t "${CLI_SERVERS_DIR}" 2>/dev/null); do
            case "${d}" in Stable-*) ;; *) continue ;; esac
            c="${d#Stable-}"
            [ -d "${CLI_SERVERS_DIR}/${d}" ] || continue
            if ! is_installed "${c}"; then
                PENDING="${c}"
                break
            fi
        done
    fi
    if [ -n "${PENDING}" ]; then
        COMMIT="${PENDING}"
        echo "Auto-detected target commit (pending install): ${COMMIT}"
    elif [ -n "${INSTALLED}" ] && [ "${FORCE}" -eq 1 ]; then
        COMMIT="${INSTALLED}"
        echo "Auto-detected installed commit for reinstall: ${COMMIT}"
    elif [ -n "${INSTALLED}" ]; then
        echo "VS Code server already installed: ${SERVER_BIN_DIR}/${INSTALLED}"
        echo "Nothing to do. Use -f to force a reinstall, or pass a commit."
        exit 0
    fi
fi

if [ -z "${COMMIT}" ]; then
    echo "ERROR: could not determine the target commit." >&2
    echo "" >&2
    echo "Connect from VS Code once (it will create a placeholder under" >&2
    echo "  ${SERVER_DATA_DIR}/ )" >&2
    echo "then re-run this script, or pass the commit explicitly:" >&2
    echo "  $0 <commit>" >&2
    echo "The commit is shown in VS Code under Help > About." >&2
    exit 1
fi

VERSION_URL="${API}/api/versions/commit:${COMMIT}/server-${PLATFORM}-${ARCH}/${QUALITY}"

echo "Fetching version info for ${COMMIT} ..."
VERSION_JSON=$(curl -sf "${VERSION_URL}") || {
    echo "ERROR: failed to fetch version info: ${VERSION_URL}" >&2
    echo "Check that the commit is correct and that you have network access." >&2
    exit 1
}

PRODUCT_VERSION=$(echo "${VERSION_JSON}" | jq -r '.productVersion')
DOWNLOAD_URL=$(echo "${VERSION_JSON}" | jq -r '.url')
EXPECTED_SHA256=$(echo "${VERSION_JSON}" | jq -r '.sha256hash')

if [ -z "${DOWNLOAD_URL}" ] || [ "${DOWNLOAD_URL}" = "null" ]; then
    echo "ERROR: version info did not contain a download URL." >&2
    exit 1
fi

echo "  Product version: ${PRODUCT_VERSION}"
echo "  Commit:          ${COMMIT}"
echo "  Download:        ${DOWNLOAD_URL}"

INSTALL_DIR="${SERVER_BIN_DIR}/${COMMIT}"

if is_installed "${COMMIT}" && [ "${FORCE}" -ne 1 ]; then
    echo ""
    echo "Already installed at ${INSTALL_DIR}"
    echo "Use -f to force a reinstall."
    exit 0
fi

mkdir -p "${INSTALL_DIR}"

echo ""
echo "Downloading ${PLATFORM}-${ARCH} server ..."
TARBALL="${INSTALL_DIR}/vscode-server.tar.gz"
curl -L -f --retry 3 --connect-timeout 10 -o "${TARBALL}" "${DOWNLOAD_URL}" || {
    echo "ERROR: download failed" >&2
    rm -f "${TARBALL}"
    exit 1
}

if [ -n "${EXPECTED_SHA256}" ] && [ "${EXPECTED_SHA256}" != "null" ]; then
    echo "Verifying SHA-256 checksum..."
    if command -v sha256 >/dev/null 2>&1; then
        ACTUAL_SHA256=$(sha256 -q "${TARBALL}")
    else
        ACTUAL_SHA256=$(sha256sum "${TARBALL}" | awk '{print $1}')
    fi
    if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
        echo "ERROR: checksum mismatch!" >&2
        echo "  Expected: ${EXPECTED_SHA256}" >&2
        echo "  Actual:   ${ACTUAL_SHA256}" >&2
        rm -f "${TARBALL}"
        exit 1
    fi
    echo "  Checksum OK"
else
    echo "WARNING: no checksum in version info; skipping verification."
fi

echo "Extracting into ${INSTALL_DIR} ..."
tar -xzf "${TARBALL}" --strip-components=1 -C "${INSTALL_DIR}"
rm -f "${TARBALL}"

SERVER_SCRIPT="${INSTALL_DIR}/bin/${SERVER_APP_NAME}"
if [ ! -x "${SERVER_SCRIPT}" ]; then
    echo "ERROR: server binary missing after extraction: ${SERVER_SCRIPT}" >&2
    exit 1
fi

# Newer clients look for the server under cli/servers/Stable-<commit>/server.
if [ -d "${CLI_SERVERS_DIR}/Stable-${COMMIT}" ] && [ ! -e "${CLI_SERVERS_DIR}/Stable-${COMMIT}/server" ]; then
    ln -s "${INSTALL_DIR}" "${CLI_SERVERS_DIR}/Stable-${COMMIT}/server"
fi

# Remote telemetry settings: extension hosts exit with code 7 when Copilot
# telemetry requests fail on a filtered network. Never overwrite existing settings.
MACHINE_SETTINGS="${SERVER_DATA_DIR}/data/Machine/settings.json"
if [ ! -f "${MACHINE_SETTINGS}" ]; then
    mkdir -p "${SERVER_DATA_DIR}/data/Machine"
    cat > "${MACHINE_SETTINGS}" <<'EOF'
{
  "telemetry.telemetryLevel": "off",
  "telemetry.enableTelemetry": false,
  "telemetry.enableCrashReporter": false
}
EOF
fi

# Bundled Copilot trips the navigator migration guard
# (PendingMigrationError: navigator is now a global in nodejs); disable it.
for file in \
    "${SERVER_DATA_DIR}/cli/servers/Stable-${COMMIT}/server/out/vs/workbench/api/node/extensionHostProcess.js" \
    "${INSTALL_DIR}/out/vs/workbench/api/node/extensionHostProcess.js"
do
    [ -f "${file}" ] || continue
    if grep -q 'supportGlobalNavigator||Object.defineProperty(globalThis,"navigator"' "${file}"; then
        [ -f "${file}.bak-navigator" ] || cp -p "${file}" "${file}.bak-navigator"
        perl -0pi -e 's/[A-Za-z_][A-Za-z0-9_]*\.supportGlobalNavigator\|\|Object\.defineProperty\(globalThis,"navigator"/false&&Object.defineProperty(globalThis,"navigator"/g' "${file}"
        echo "Patched navigator guard: ${file}"
    fi
done

echo ""
echo "Verifying installation..."
"${SERVER_SCRIPT}" --version || true

echo ""
echo "VS Code server ${PRODUCT_VERSION} (${COMMIT})"
echo "installed successfully at ${INSTALL_DIR}."
echo "You can now reconnect from VS Code."
