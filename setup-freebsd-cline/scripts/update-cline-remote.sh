#!/bin/sh
#
# update-cline-remote - Install or update the Cline extension on the VS Code
# remote server installed by setup-freebsd-vscode (skill: setup-freebsd-cline)
#
# Cline (marketplace ID saoudrizwan.claude-dev, display name "Cline") is a
# pure-JS VS Code extension that runs in the remote extension host. This
# script:
#   * detects the target ~/.vscode-server/bin/<commit>/ (newest installed,
#     or one passed explicitly)
#   * verifies the server version satisfies Cline's engines.vscode (^1.101.0)
#   * resolves the newest stable Cline version from Open VSX (Cline is open
#     source and publishes to both the VS Code Marketplace and Open VSX; the
#     marketplace's direct VSIX endpoint 404s from this network while Open
#     VSX offers plain API and file URLs)
#   * downloads the VSIX, checks zip integrity, and installs it with the
#     server's own code-server --install-extension (which registers it in
#     extensions.json)
#
# Usage:
#   update-cline-remote [-f] [--version VER] [--vsix FILE] [COMMIT]
#     -f, --force      Reinstall even if the version is already installed.
#     --version VER    Install a specific Cline version instead of newest.
#     --vsix FILE      Install from a local VSIX file instead of downloading.
#     COMMIT           Target server commit. If omitted, the newest installed
#                      commit is used (several may coexist; use the one your
#                      VS Code client actually connects with).
#
# Requires: curl, jq, unzip, flock.
#

set -eu

SERVER_DATA_DIR="${HOME}/.vscode-server"
SERVER_BIN_DIR="${SERVER_DATA_DIR}/bin"
EXTENSIONS_DIR="${SERVER_DATA_DIR}/extensions"
USER_DATA_DIR="${SERVER_DATA_DIR}/data"

EXTENSION_ID="saoudrizwan.claude-dev"
PUBLISHER="saoudrizwan"
NAME="claude-dev"
MIN_SERVER_VERSION="1.101.0"
OVSX_API="https://open-vsx.org/api/${PUBLISHER}/${NAME}"

FORCE=0
VERSION=""
VSIX_FILE=""
COMMIT=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        --version)
            [ $# -ge 2 ] || { echo "ERROR: --version requires an argument" >&2; exit 2; }
            VERSION="$2"; shift ;;
        --vsix)
            [ $# -ge 2 ] || { echo "ERROR: --vsix requires an argument" >&2; exit 2; }
            VSIX_FILE="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *)         COMMIT="$1" ;;
    esac
    shift
done

for tool in curl jq unzip flock; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: ${tool}" >&2
        exit 1
    }
done

# Serialize concurrent runs; the code-server CLI wedges when invoked while
# another instance of it is mid-install.
LOCK_FILE="${SERVER_DATA_DIR}/.update-cline-remote.lock"
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "ERROR: another update-cline-remote is still running" >&2; exit 1; }

is_installed_server() {
    [ -x "${SERVER_BIN_DIR}/$1/bin/code-server" ]
}

# Determine the target server commit. A directory without a server binary is
# a placeholder from a failed connection; with no installed server at all,
# tell the user to run update-vscode-server first.
if [ -z "${COMMIT}" ]; then
    NEWEST=""
    NEWEST_VER=""
    for d in "${SERVER_BIN_DIR}"/*; do
        [ -d "${d}" ] || continue
        c=$(basename "${d}")
        is_installed_server "${c}" || continue
        ver=$(jq -r '.version // empty' "${d}/product.json" 2>/dev/null || true)
        [ -n "${ver}" ] || continue
        if [ -z "${NEWEST}" ] || [ "$(printf '%s\n%s' "${NEWEST_VER}" "${ver}" | sort -V | tail -1)" = "${ver}" ]; then
            NEWEST="${c}"
            NEWEST_VER="${ver}"
        fi
    done
    if [ -z "${NEWEST}" ]; then
        echo "ERROR: no installed VS Code server found under ${SERVER_BIN_DIR}." >&2
        echo "Install one first (see the setup-freebsd-vscode skill):" >&2
        echo "  update-vscode-server" >&2
        exit 1
    fi
    COMMIT="${NEWEST}"
fi

SERVER_DIR="${SERVER_BIN_DIR}/${COMMIT}"
SERVER_CLI="${SERVER_DIR}/bin/code-server"
if ! is_installed_server "${COMMIT}"; then
    echo "ERROR: ${COMMIT} has no server binary (${SERVER_CLI} missing)." >&2
    echo "That commit is a placeholder from a failed connection. Install it" >&2
    echo "first with update-vscode-server, or pass an installed commit." >&2
    exit 1
fi

SERVER_VERSION=$(jq -r '.version // empty' "${SERVER_DIR}/product.json" 2>/dev/null || true)
if [ -z "${SERVER_VERSION}" ]; then
    echo "ERROR: could not read the server version from ${SERVER_DIR}/product.json." >&2
    exit 1
fi

# Cline's engines.vscode is ^1.101.0; require at least that.
if [ "$(printf '%s\n%s' "${MIN_SERVER_VERSION}" "${SERVER_VERSION}" | sort -V | head -1)" != "${MIN_SERVER_VERSION}" ]; then
    echo "ERROR: VS Code server ${SERVER_VERSION} (${COMMIT}) is too old; Cline needs >= ${MIN_SERVER_VERSION}." >&2
    echo "Run update-vscode-server with the current client commit first." >&2
    exit 1
fi

echo "Target server:  ${SERVER_VERSION} (${COMMIT})"

installed_version() {
    jq -r '.[] | select(.identifier.id == "saoudrizwan.claude-dev") | .version' \
        "${EXTENSIONS_DIR}/extensions.json" 2>/dev/null | sort -V | tail -1
}

if [ -n "${VSIX_FILE}" ]; then
    [ -f "${VSIX_FILE}" ] || { echo "ERROR: VSIX file not found: ${VSIX_FILE}" >&2; exit 1; }
    VSIX="${VSIX_FILE}"
    [ -n "${VERSION}" ] || VERSION="local"
    echo "Using local VSIX: ${VSIX}"
elif [ -z "${VERSION}" ]; then
    echo "Resolving newest stable Cline from Open VSX ..."
    OVSX_JSON=$(curl -sf --retry 3 --connect-timeout 10 "${OVSX_API}") || {
        echo "ERROR: could not reach Open VSX: ${OVSX_API}" >&2
        echo "Download the VSIX in a browser and re-run with: $0 --vsix <file>" >&2
        exit 1
    }
    VERSION=$(echo "${OVSX_JSON}" | jq -r '.version // empty')
    if [ -z "${VERSION}" ] || [ "${VERSION}" = "null" ]; then
        echo "ERROR: Open VSX response did not contain a version." >&2
        exit 1
    fi
    echo "  Newest stable: ${VERSION}"
fi

CURRENT=$(installed_version)
if [ "${CURRENT}" = "${VERSION}" ] && [ "${FORCE}" -ne 1 ]; then
    echo "Cline ${VERSION} is already installed (latest). Nothing to do."
    echo "Use -f to force a reinstall."
    exit 0
fi
if [ -n "${CURRENT}" ] && [ "${CURRENT}" != "${VERSION}" ]; then
    echo "  Installed:     ${CURRENT}"
fi

TMPDIR_CLINE=$(mktemp -d "${TMPDIR:-/tmp}/cline-update.XXXXXX")
trap 'rm -rf "${TMPDIR_CLINE}"' EXIT INT TERM

if [ -z "${VSIX_FILE}" ]; then
    VSIX="${TMPDIR_CLINE}/saoudrizwan.claude-dev-${VERSION}.vsix"
    URL="https://open-vsx.org/api/${PUBLISHER}/${NAME}/${VERSION}/file/saoudrizwan.claude-dev-${VERSION}.vsix"
    echo ""
    echo "Downloading ${VERSION} ..."
    echo "  ${URL}"
    curl -L -f --retry 3 --connect-timeout 10 -o "${VSIX}" "${URL}" || {
        echo "ERROR: download failed" >&2
        exit 1
    }
    # Guard against HTML error pages saved with a .vsix extension.
    MAGIC=$(head -c 2 "${VSIX}" | od -An -tx1 | tr -d ' \n')
    [ "${MAGIC}" = "504b" ] || {
        echo "ERROR: downloaded file is not a zip archive (HTML error page?)" >&2
        exit 1
    }
    echo "Checking archive integrity ..."
    unzip -tq "${VSIX}" >/dev/null || { echo "ERROR: VSIX archive is corrupt" >&2; exit 1; }
fi

mkdir -p "${EXTENSIONS_DIR}"

# Uninstall (no --force): code-server exits 0 but silently refuses downgrade
# installs, and --force hangs while another server instance runs, so a
# downgrade is done as uninstall + fresh install. Upgrades install directly.
NEED_UNINSTALL=0
if [ -n "${CURRENT}" ] && [ "${CURRENT}" != "${VERSION}" ]; then
    if [ "${VERSION}" = "local" ]; then
        NEED_UNINSTALL=1
    elif [ "$(printf '%s\n%s' "${CURRENT}" "${VERSION}" | sort -V | tail -1)" = "${CURRENT}" ]; then
        NEED_UNINSTALL=1
    fi
fi

if [ "${NEED_UNINSTALL}" -eq 1 ]; then
    echo ""
    echo "Uninstalling ${CURRENT} before installing ${VERSION} ..."
    "${SERVER_CLI}" --uninstall-extension "${EXTENSION_ID}" \
        --extensions-dir "${EXTENSIONS_DIR}" \
        --user-data-dir "${USER_DATA_DIR}" || {
        echo "WARNING: uninstall of ${CURRENT} failed; continuing with install" >&2
    }
    # Uninstall leaves the extension directory behind; remove it so stale
    # files cannot shadow the new install.
    rm -rf "${EXTENSIONS_DIR}/saoudrizwan.claude-dev-${CURRENT}"
fi

echo ""
echo "Installing ${VERSION} into ${EXTENSIONS_DIR} ..."
"${SERVER_CLI}" --install-extension "${VSIX}" \
    --extensions-dir "${EXTENSIONS_DIR}" \
    --user-data-dir "${USER_DATA_DIR}"

echo ""
echo "Verifying ..."
INSTALLED=$(installed_version)
if [ -z "${INSTALLED}" ]; then
    echo "ERROR: extension not found after install" >&2
    exit 1
fi
if [ "${VERSION}" != "local" ] && [ "${INSTALLED}" != "${VERSION}" ]; then
    echo "ERROR: requested ${VERSION} but ${INSTALLED} is installed" >&2
    echo "(code-server can refuse silently; re-run with -f)" >&2
    exit 1
fi
echo "Cline ${INSTALLED} installed at ${EXTENSIONS_DIR}/saoudrizwan.claude-dev-${INSTALLED}"
"${SERVER_CLI}" --list-extensions \
    --extensions-dir "${EXTENSIONS_DIR}" \
    --user-data-dir "${USER_DATA_DIR}" | grep -i claude-dev || true
echo ""
echo "Done. Reconnect from VS Code (or reload the remote window)."

