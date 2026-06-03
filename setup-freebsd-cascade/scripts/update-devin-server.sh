#!/bin/sh
#
# update-devin-server - Download and install the matching Devin remote server
#
# Run this on the FreeBSD host after upgrading the Devin IDE client (formerly
# Windsurf). FreeBSD is not a natively supported remote platform, so the IDE
# cannot auto-install the server; this script installs the Linux REH build that
# matches the client's embedded commit so it runs under the Linux ABI layer.
#
# How it works:
#   * When you click "Connect" from the Devin client, the remote bootstrap
#     creates an empty   ~/.devin-server/bin/<commit>/   directory and then
#     fails with "freebsd needs manual installation of remote extension host".
#   * This script detects that <commit>, asks the CDN manifest for the exact
#     download URL + checksum + version, installs it, then you reconnect.
#
# Note: the legacy https://windsurf-stable.codeium.com/api/update/... endpoint
# is NOT used. After the Windsurf -> Devin rebrand that channel still serves the
# old Windsurf build, which will never match a Devin client. The per-commit CDN
# manifest is the source of truth.
#
# Usage:
#   update-devin-server [-f] [COMMIT]
#     -f, --force   Reinstall even if the server is already present.
#     COMMIT        Target commit hash. If omitted, it is auto-detected from the
#                   empty directory left by a failed connection attempt. You can
#                   also find it in the Devin client under Help > About.
#

set -eu

SERVER_DATA_DIR="${HOME}/.devin-server"
SERVER_BIN_DIR="${SERVER_DATA_DIR}/bin"
SERVER_APP_NAME="devin-server"

PLATFORM="linux"
ARCH="x64"
QUALITY="stable"
CDN="https://windsurf-stable.codeiumdata.com"

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

# Auto-detect the target commit. A failed connection attempt leaves an empty
# placeholder directory (no server binary yet) - that is the install target. If
# none is pending, fall back to the already-installed commit so that -f can
# reinstall it and a plain run reports "already installed" instead of failing.
if [ -z "${COMMIT}" ] && [ -d "${SERVER_BIN_DIR}" ]; then
    PENDING=""
    INSTALLED=""
    for d in $(ls -1t "${SERVER_BIN_DIR}" 2>/dev/null); do
        [ -d "${SERVER_BIN_DIR}/${d}" ] || continue
        if [ -x "${SERVER_BIN_DIR}/${d}/bin/${SERVER_APP_NAME}" ]; then
            [ -z "${INSTALLED}" ] && INSTALLED="${d}"
        else
            [ -z "${PENDING}" ] && PENDING="${d}"
        fi
    done
    if [ -n "${PENDING}" ]; then
        COMMIT="${PENDING}"
        echo "Auto-detected target commit (pending install): ${COMMIT}"
    elif [ -n "${INSTALLED}" ] && [ "${FORCE}" -eq 1 ]; then
        COMMIT="${INSTALLED}"
        echo "Auto-detected installed commit for reinstall: ${COMMIT}"
    elif [ -n "${INSTALLED}" ]; then
        echo "Devin server already installed: ${SERVER_BIN_DIR}/${INSTALLED}"
        echo "Nothing to do. Use -f to force a reinstall, or pass a commit."
        exit 0
    fi
fi

if [ -z "${COMMIT}" ]; then
    echo "ERROR: could not determine the target commit." >&2
    echo "" >&2
    echo "Click Connect from the Devin client once (it will create" >&2
    echo "  ${SERVER_BIN_DIR}/<commit>/ )" >&2
    echo "then re-run this script, or pass the commit explicitly:" >&2
    echo "  $0 <commit>" >&2
    echo "The commit is shown in the Devin client under Help > About." >&2
    exit 1
fi

MANIFEST_URL="${CDN}/${PLATFORM}-reh-${ARCH}/${QUALITY}/manifest-${COMMIT}.json"

echo "Fetching manifest for ${COMMIT} ..."
MANIFEST_JSON=$(curl -sf "${MANIFEST_URL}") || {
    echo "ERROR: failed to fetch manifest: ${MANIFEST_URL}" >&2
    echo "Check that the commit is correct and that you have network access." >&2
    exit 1
}

DISTRO_WINDSURF_VERSION=$(echo "${MANIFEST_JSON}" | jq -r '.windsurfVersion')
PRODUCT_VERSION=$(echo "${MANIFEST_JSON}" | jq -r '.productVersion')
DOWNLOAD_URL=$(echo "${MANIFEST_JSON}" | jq -r '.url')
EXPECTED_SHA256=$(echo "${MANIFEST_JSON}" | jq -r '.sha256hash')

if [ -z "${DOWNLOAD_URL}" ] || [ "${DOWNLOAD_URL}" = "null" ]; then
    echo "ERROR: manifest did not contain a download URL." >&2
    exit 1
fi

echo "  Product version: ${PRODUCT_VERSION}"
echo "  Build version:   ${DISTRO_WINDSURF_VERSION}"
echo "  Commit:          ${COMMIT}"
echo "  Download:        ${DOWNLOAD_URL}"

INSTALL_DIR="${SERVER_BIN_DIR}/${COMMIT}"

if [ -x "${INSTALL_DIR}/bin/${SERVER_APP_NAME}" ] && [ "${FORCE}" -ne 1 ]; then
    echo ""
    echo "Already installed at ${INSTALL_DIR}"
    echo "Use -f to force a reinstall."
    exit 0
fi

mkdir -p "${INSTALL_DIR}"

echo ""
echo "Downloading $(basename "${DOWNLOAD_URL}") ..."
TARBALL="${INSTALL_DIR}/devin-server.tar.gz"
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
    echo "WARNING: manifest had no checksum; skipping verification."
fi

echo "Extracting into ${INSTALL_DIR} ..."
tar -xzf "${TARBALL}" --strip-components=1 -C "${INSTALL_DIR}"
rm -f "${TARBALL}"

SERVER_SCRIPT="${INSTALL_DIR}/bin/${SERVER_APP_NAME}"
if [ ! -x "${SERVER_SCRIPT}" ]; then
    echo "ERROR: server binary missing after extraction: ${SERVER_SCRIPT}" >&2
    exit 1
fi

echo ""
echo "Verifying installation..."
"${SERVER_SCRIPT}" --version || true

# The bundled language server name can vary; locate it under extensions/*/bin.
LANG_SERVER=$(ls "${INSTALL_DIR}"/extensions/*/bin/language_server_linux_x64 2>/dev/null | head -n 1 || true)
if [ -n "${LANG_SERVER}" ]; then
    "${LANG_SERVER}" --version >/dev/null 2>&1 && echo "  language server OK" || echo "  language server present"
fi

echo ""
echo "Devin server ${PRODUCT_VERSION} (build ${DISTRO_WINDSURF_VERSION}, ${COMMIT})"
echo "installed successfully at ${INSTALL_DIR}."
echo "You can now reconnect from the Devin client."
