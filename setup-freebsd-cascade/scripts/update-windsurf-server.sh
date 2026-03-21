#!/bin/sh
#
# update-windsurf-server - Download and install the latest Windsurf remote server
#
# Run this on the FreeBSD host after upgrading the Windsurf IDE client.
# Queries the Windsurf update API to get the latest commit and version,
# then downloads and installs the matching server component.
#

set -eu

UPDATE_API="https://windsurf-stable.codeium.com/api/update/linux-reh-x64/stable/0000000000000000000000000000000000000000"
SERVER_DIR="${HOME}/.windsurf-server/bin"

echo "Querying Windsurf update API..."
UPDATE_JSON=$(curl -sf "${UPDATE_API}") || {
    echo "ERROR: Failed to query update API" >&2
    exit 1
}

DISTRO_COMMIT=$(echo "${UPDATE_JSON}" | jq -r '.version')
DISTRO_WINDSURF_VERSION=$(echo "${UPDATE_JSON}" | jq -r '.windsurfVersion')
PRODUCT_VERSION=$(echo "${UPDATE_JSON}" | jq -r '.productVersion')
DOWNLOAD_URL=$(echo "${UPDATE_JSON}" | jq -r '.url')
EXPECTED_SHA256=$(echo "${UPDATE_JSON}" | jq -r '.sha256hash')

echo "  Windsurf version: ${PRODUCT_VERSION}"
echo "  Build version:    ${DISTRO_WINDSURF_VERSION}"
echo "  Commit:           ${DISTRO_COMMIT}"

INSTALL_DIR="${SERVER_DIR}/${DISTRO_COMMIT}"

if [ -d "${INSTALL_DIR}" ] && [ -x "${INSTALL_DIR}/bin/windsurf-server" ]; then
    echo ""
    echo "Already installed at ${INSTALL_DIR}"
    echo "Use -f to force reinstall."
    if [ "${1:-}" != "-f" ]; then
        exit 0
    fi
    echo "Force reinstall requested, continuing..."
fi

mkdir -p "${INSTALL_DIR}"

echo ""
echo "Downloading windsurf-reh-linux-x64-${DISTRO_WINDSURF_VERSION}.tar.gz ..."
TARBALL="${INSTALL_DIR}/windsurf-server.tar.gz"
curl -L -f -o "${TARBALL}" "${DOWNLOAD_URL}" || {
    echo "ERROR: Download failed" >&2
    rm -f "${TARBALL}"
    exit 1
}

if [ -n "${EXPECTED_SHA256}" ] && [ "${EXPECTED_SHA256}" != "null" ]; then
    echo "Verifying SHA-256 checksum..."
    ACTUAL_SHA256=$(sha256 -q "${TARBALL}" 2>/dev/null || sha256sum "${TARBALL}" | awk '{print $1}')
    if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
        echo "ERROR: Checksum mismatch!" >&2
        echo "  Expected: ${EXPECTED_SHA256}" >&2
        echo "  Actual:   ${ACTUAL_SHA256}" >&2
        rm -f "${TARBALL}"
        exit 1
    fi
    echo "  Checksum OK"
fi

echo "Extracting..."
tar -xzf "${TARBALL}" --strip-components=1 -C "${INSTALL_DIR}"
rm -f "${TARBALL}"

echo ""
echo "Verifying installation..."
"${INSTALL_DIR}/bin/windsurf-server" --version
"${INSTALL_DIR}/extensions/windsurf/bin/language_server_linux_x64" --version

echo ""
echo "Windsurf server ${PRODUCT_VERSION} (${DISTRO_COMMIT}) installed successfully."
