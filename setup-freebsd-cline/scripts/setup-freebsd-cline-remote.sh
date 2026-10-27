#!/bin/sh
#
# setup-freebsd-cline-remote - Prepare a FreeBSD host for Cline Desktop's SSH
# remote mode AND build/stage a native FreeBSD helper (skill: setup-freebsd-cline)
#
# One script, three jobs:
#   1. Host prerequisites: a uname shim that answers Cline's platform probe
#      with Linux/x86_64, its non-interactive-SSH PATH hook, and /bin/bash.
#   2. Native build: check out github.com/cline/cline at the CLI release tag
#      matching the helper Cline Desktop ships, build it with the repo's own
#      Bun pipeline for bun-freebsd-x64, and re-stamp the ELF ABI tag to this
#      host's __FreeBSD_version (Bun's published FreeBSD runtime is built on
#      14.3, so an as-built artifact says "for FreeBSD 14.3" on a 15.1 host).
#   3. Staging (the Zed-skill pattern): replace the helper the app actually
#      executes - ~/.cline/remote/cline-linux-x64-<sha256:16> - with the
#      native binary, atomically, keeping the Linux ELF as *.linux-elf.
#
# Why staging by hash name matters: Cline Desktop resolves the helper on the
# CLIENT (CLINE_REMOTE_HELPER_BINARY, CLINE_REMOTE_HELPER_DIRECTORY, or
# <app exec dir>/remote-helpers/cline-<platform-arch>), then uploads it to the
# remote as cline-<platform>-<arch>-<first 16 hex of the helper's sha256>.
# installHelper() skips the upload when that exact remote path already exists
# and is executable - which is what makes this swap stick. A native binary
# dropped at ~/.cline/remote/cline-x86_64-unknown-linux-gnu (the client-side
# lookup name) is inert: the app never executes that path.
#
# Version handling (both styles):
#   Zed-style pin:    setup-freebsd-cline-remote 3.0.74
#   Devin-style auto: setup-freebsd-cline-remote
#       Reads the version from the helper Cline Desktop staged in
#       ~/.cline/remote/ (connect once first), falling back to the newest
#       cli-v* tag on GitHub if nothing is staged. CLI releases are tagged
#       cli-v<version> in github.com/cline/cline.
#
# Usage:
#   setup-freebsd-cline-remote.sh [-f] [--host HOST] [--user USER]
#                                 [--abi VERSION] [--build-only] [--restore-linux]
#                                 [VERSION]
#     -f, --force        Rebuild even if this version is already staged.
#     --host HOST        Probe target (default: 127.0.0.1, i.e. self-ssh).
#     --user USER        Probe user (default: current user).
#     --abi VERSION      __FreeBSD_version to stamp (default: kern.osreldate).
#     --build-only       Build + stamp only; do not touch ~/.cline/remote.
#     --restore-linux    Put the saved Linux helpers back (*.linux-elf) and exit.
#     VERSION            Exact CLI version to build (default: auto-detect).
#
# Requirements: git, curl, perl, bun 1.4+ (native FreeBSD build), ~3 GB free
# for the source tree + node_modules. CLINE_SRC_DIR overrides the checkout
# location (default ~/Documents/Code/cline-cli). Keep it on a roomy dataset:
# freebsd-dev1's / runs close to full, so do not override it onto / or /tmp.
#
# Idempotent. Re-run it after every Cline Desktop update: the app uploads a
# freshly hashed Linux helper, and this script re-stages the native build
# (rebuilding if the CLI version changed).
#

set -eu

REPO="https://github.com/cline/cline"
SRC="${CLINE_SRC_DIR:-$HOME/Documents/Code/cline-cli}"
REMOTE_DIR="$HOME/.cline/remote"
SHIM_DIR="${HOME}/.local/share/vscode-shim"
SHIM="${SHIM_DIR}/uname"
MARKER=CLINE_REMOTE_INSPECT_V1
BUILD_MARKER="$SRC/.native-built-version"
DEPS_MARKER="$SRC/.native-deps-version"
ABI_MARKER="$SRC/.native-abi-tag"

VERSION=""
FORCE=0
PROBE_HOST="127.0.0.1"
PROBE_USER="$(id -un)"
ABI_TAG="$(sysctl -n kern.osreldate 2>/dev/null || echo 1501000)"
BUILD_ONLY=0
RESTORE_LINUX=0
SKIP_BUILD=0
FAILURES=0

fail() {
    echo "  FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ok() {
    echo "  ok: $*"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        --host)
            [ $# -ge 2 ] || die "--host requires an argument"
            PROBE_HOST="$2"; shift ;;
        --user)
            [ $# -ge 2 ] || die "--user requires an argument"
            PROBE_USER="$2"; shift ;;
        --abi)
            [ $# -ge 2 ] || die "--abi requires an argument"
            ABI_TAG="$2"; shift ;;
        --build-only) BUILD_ONLY=1 ;;
        --restore-linux) RESTORE_LINUX=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            [ -z "${VERSION}" ] || die "unexpected argument: $1"
            case "$1" in
                [0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
                *) die "VERSION must look like 3.0.74 (got: $1)" ;;
            esac ;;
    esac
    shift
done

# Helpers staged by the app are cline-linux-x64-<sha256:16> (plus, in older
# layouts, the client-side lookup name cline-x86_64-unknown-linux-gnu).
# *.linux-elf are this script's backups and must never be staged over.
staged_helpers() {
    {
        find "${REMOTE_DIR}" -maxdepth 1 -type f -name 'cline-linux-x64-*' \
            ! -name '*.linux-elf' ! -name '*.new.*' 2>/dev/null || true
        [ -f "${REMOTE_DIR}/cline-x86_64-unknown-linux-gnu" ] &&
            echo "${REMOTE_DIR}/cline-x86_64-unknown-linux-gnu"
    } | sort -u
}

helper_version() {
    "$1" --version 2>/dev/null | head -1
}

is_linux_elf() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q 'GNU/Linux'
}

is_freebsd_elf() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q 'FreeBSD'
}

abi_of() {
    elfdump -n "$1" 2>/dev/null |
        sed -n 's/^[[:space:]]*FreeBSD \([0-9][0-9]*\) (NT_FREEBSD_ABI_TAG)$/\1/p' |
        head -1
}

# Re-stamp the NT_FREEBSD_ABI_TAG note. Bun's FreeBSD runtime (and therefore
# every `bun build --compile` artifact made with it) is linked on 14.3, so the
# note describes the toolchain, not this host. The kernel and ld-elf.so ignore
# the note; it is build metadata (what `file` prints as "for FreeBSD 14.3").
# Anchoring on the full note header (namesz=8, descsz=4, type=1, "FreeBSD\0")
# avoids the many plain "FreeBSD" strings inside the embedded Bun runtime.
restamp_abi() {
    bin=$1
    want=$2
    CLINE_ABI_TAG_WANT="${want}" perl -0777 -pi -e '
        my $note = "\x08\x00\x00\x00\x04\x00\x00\x00\x01\x00\x00\x00FreeBSD\x00";
        my $i = index($_, $note);
        die "NT_FREEBSD_ABI_TAG note not found in $ARGV\n" if $i < 0;
        substr($_, $i + length($note), 4, pack("V", $ENV{CLINE_ABI_TAG_WANT}));
    ' "${bin}"
}

# Back up the app's Linux helper (once) and atomically replace the path the
# app executes. install(1) can write the new binary; the rename swaps the
# inode, so a helper that is currently running is not truncated (FreeBSD
# refuses write-open on running executables: ETXTBSY).
stage_helper() {
    src=$1
    path=$2
    if is_linux_elf "${path}"; then
        if [ ! -f "${path}.linux-elf" ]; then
            cp -p "${path}" "${path}.linux-elf"
            ok "kept the app's Linux helper as $(basename "${path}").linux-elf"
        fi
    fi
    tmp="${path}.new.$$"
    install -m 755 "${src}" "${tmp}"
    mv -f "${tmp}" "${path}"
}

# ---------------------------------------------------------------------------
# --restore-linux: put the app's own Linux helpers back and stop here.
# ---------------------------------------------------------------------------
if [ "${RESTORE_LINUX}" -eq 1 ]; then
    echo "Restoring the app's Linux helpers:"
    RESTORED=0
    for bak in "${REMOTE_DIR}"/cline-*.linux-elf; do
        [ -f "${bak}" ] || continue
        target="${bak%.linux-elf}"
        tmp="${target}.new.$$"
        install -m 755 "${bak}" "${tmp}"
        mv -f "${tmp}" "${target}"
        ok "restored $(basename "${target}") from $(basename "${bak}")"
        RESTORED=$((RESTORED + 1))
    done
    [ "${RESTORED}" -gt 0 ] || die "no *.linux-elf backups found in ${REMOTE_DIR}"
    echo ""
    echo "Disconnect and reconnect Cline Desktop to start the Linux helper again."
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Host prerequisites
# ---------------------------------------------------------------------------
echo "Host:"
echo "  FreeBSD $(uname -K) ($(uname -m)), ABI stamp target ${ABI_TAG}"

# /bin/bash: the app launches the helper through it. A native ELF also runs
# if present, but the app's command is `bash -c`, so the symlink stays.
if [ -e /bin/bash ]; then
    ok "/bin/bash present"
elif [ -x /usr/local/bin/bash ]; then
    if doas ln -s /usr/local/bin/bash /bin/bash 2>/dev/null; then
        ok "/bin/bash -> /usr/local/bin/bash"
    else
        fail "could not create /bin/bash symlink (needs doas: ln -s /usr/local/bin/bash /bin/bash)"
    fi
else
    fail "no /bin/bash and no /usr/local/bin/bash (doas pkg install -y bash)"
fi

# Linuxulator: no longer needed for the probe or for a native helper, but it
# is what the app's own Linux helper (and VS Code/Zed setups) run on.
if ! kldstat 2>/dev/null | grep -qw linux64; then
    echo "  note: linux64 not loaded; only needed for the app's Linux fallback helper"
fi

install_shim() {
    mkdir -p "${SHIM_DIR}"
    cat > "${SHIM}" <<'SHIM'
#!/bin/sh
#
# uname shim for VS Code Remote-SSH, the Agents window, Zed/Devin probes, and
# Cline Desktop remote inspection on FreeBSD
#
# VS Code rejects any host whose `uname -s` is not Linux or whose `uname -m` is
# not x86_64 (FreeBSD prints amd64). Cline Desktop's remote inspector (probe
# marker CLINE_REMOTE_INSPECT_V1) requires `uname -s` to be Linux; its arch
# mapping accepts FreeBSD's amd64 natively. Callers that need the Linux answer:
#   * the Remote-SSH bootstrap, which pipes its script into a bare `sh`
#   * the Agents window probe, which runs `uname -s` and `uname -m` as separate
#     SSH exec commands, so the parent is `<login shell> -c uname -s|-m`
#   * Zed's remote probe and the Devin setup, which run `uname -sm` and rely on
#     a `Linux x86_64` answer (see ~/.local/bin/uname from setup-freebsd-zed-remote)
#   * Cline Desktop's CLINE_REMOTE_INSPECT_V1 probe, which runs `sh -c` with a
#     printf script embedding $(uname -s) and $(uname -m)
# For those callers answer with the Linux uname (Linuxulator when available,
# otherwise the same static answers). Every other caller gets the real
# FreeBSD uname.
#
# Install as ~/.local/share/vscode-shim/uname (mode 755) and put that directory
# first in PATH for non-interactive SSH sessions.

parent_cmd=$(ps -o command= -p "${PPID}" 2>/dev/null)

# The exact combined form `-sm` is only ever used by those probes.
if [ "$*" = "-sm" ]; then
    parent_cmd=sh
fi

case "${parent_cmd}" in
    sh|*" -c uname -s"|*" -c uname -m"|*" -c uname -sm"|*CLINE_REMOTE_INSPECT_V1*)
        if [ -x /compat/linux/usr/bin/uname ]; then
            exec /compat/linux/usr/bin/uname "$@"
        fi
        case "$*" in
            -s) echo Linux; exit 0 ;;
            -m) echo x86_64; exit 0 ;;
            -sm) echo "Linux x86_64"; exit 0 ;;
        esac
        ;;
esac

exec /usr/bin/uname "$@"
SHIM
    chmod 755 "${SHIM}"
}

if [ -f "${SHIM}" ] && grep -q "${MARKER}" "${SHIM}" \
    && grep -q 'echo Linux; exit 0' "${SHIM}"; then
    ok "uname shim answers ${MARKER} (with the no-Linuxulator fallback)"
else
    [ -f "${SHIM}" ] && cp -p "${SHIM}" "${SHIM}.bak-$(date +%Y%m%d)" 2>/dev/null || true
    install_shim
    ok "uname shim installed at ${SHIM}"
fi

# PATH hook: fish's config.fish is interactive-only and Cline's ssh commands
# are not; conf.d snippets are always sourced.
if [ "$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7)" = "/usr/local/bin/fish" ] \
    || [ "${SHELL:-}" = "/usr/local/bin/fish" ]; then
    FISH_HOOK="${HOME}/.config/fish/conf.d/10-vscode-shim.fish"
    if [ -f "${FISH_HOOK}" ] && grep -q "vscode-shim" "${FISH_HOOK}"; then
        ok "fish PATH hook present"
    else
        mkdir -p "$(dirname "${FISH_HOOK}")"
        echo 'fish_add_path --path --prepend $HOME/.local/share/vscode-shim' > "${FISH_HOOK}"
        ok "fish PATH hook created (${FISH_HOOK})"
    fi
else
    echo "  note: login shell is not fish; ensure ${SHIM_DIR} is first in PATH"
    echo "        for non-interactive SSH sessions"
fi

# The app's exact probe, end to end, over ssh (self-ssh by default).
echo "Probe (${PROBE_USER}@${PROBE_HOST}):"
PROBE_SCRIPT="printf \"\\000${MARKER}\\000%s\\000%s\\000%s\\000\" \"\$(uname -s)\" \"\$(uname -m)\" \"\$HOME\""
PAYLOAD=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
    "${PROBE_USER}@${PROBE_HOST}" "sh -c '${PROBE_SCRIPT}'" 2>/dev/null |
    perl -pe 's/\x00/|/g' || true)
RESULT=$(printf '%s' "${PAYLOAD}" |
    perl -ne "if (/^\|${MARKER}\|([^|]*)\|([^|]*)\|([^|]*)\|\z/) { print \"\$1/\$2\" }")
case "${RESULT}" in
    Linux/x86_64|Linux/amd64|Linux/x64)
        ok "probe reports ${RESULT}" ;;
    "")
        fail "probe returned no parseable payload (raw: ${PAYLOAD:-<empty>})"
        echo "  hint: key auth for ssh ${PROBE_USER}@${PROBE_HOST} (the shim needs no Linuxulator)" >&2 ;;
    *)
        fail "probe reports ${RESULT}; Cline needs Linux/x86_64 (shim not first in PATH?)" ;;
esac

# ---------------------------------------------------------------------------
# 2. Resolve the target version
# ---------------------------------------------------------------------------
echo "Version:"
HELPERS=$(staged_helpers || true)
FIRST_HELPER=$(printf '%s\n' "${HELPERS}" | sed -n '1p')

if [ -z "${VERSION}" ] && [ -n "${FIRST_HELPER}" ]; then
    STAGED_VERSION=$(helper_version "${FIRST_HELPER}" || true)
    if [ -n "${STAGED_VERSION}" ]; then
        VERSION="${STAGED_VERSION}"
        echo "  auto-detected ${VERSION} from $(basename "${FIRST_HELPER}")"
    fi
fi
if [ -z "${VERSION}" ]; then
    echo "  no helper staged; falling back to the newest cli-v* tag on GitHub"
    VERSION=$(git ls-remote --tags "${REPO}" 2>/dev/null |
        sed -n 's|.*refs/tags/cli-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [ -n "${VERSION}" ] || die "could not resolve a CLI version"
    echo "  using newest release tag: ${VERSION}"
    [ -n "${FIRST_HELPER}" ] || echo "  (connect Cline Desktop once to stage its helper, then re-run to swap in the native build)"
fi
TAG="cli-v${VERSION}"

if [ "${BUILD_ONLY}" -eq 0 ] && [ -z "${HELPERS}" ]; then
    echo ""
    echo "No helper in ${REMOTE_DIR} yet."
    echo "Connect Cline Desktop to this host once (it uploads its Linux helper),"
    echo "then re-run this script to replace that helper with the native build."
    [ "${FAILURES}" -eq 0 ] || exit 1
    exit 0
fi

# Already staged and matching (version + ABI on every helper)? Skip the build.
if [ "${FORCE}" -eq 0 ] && [ -n "${HELPERS}" ] \
    && [ "$(cat "${BUILD_MARKER}" 2>/dev/null)" = "${VERSION}" ] \
    && [ "$(cat "${ABI_MARKER}" 2>/dev/null)" = "${ABI_TAG}" ]; then
    ALL_OK=1
    OLDIFS=$IFS
    IFS='
'
    for h in ${HELPERS}; do
        is_freebsd_elf "${h}" || ALL_OK=0
        [ "$(helper_version "${h}")" = "${VERSION}" ] || ALL_OK=0
        [ "$(abi_of "${h}")" = "${ABI_TAG}" ] || ALL_OK=0
    done
    IFS=$OLDIFS
    if [ "${ALL_OK}" -eq 1 ]; then
        ok "native helper ${VERSION} with ABI ${ABI_TAG} already staged (use -f to rebuild)"
        SKIP_BUILD=1
    fi
fi

if [ "${SKIP_BUILD}" -eq 0 ]; then

# ---------------------------------------------------------------------------
# 3. Source tree
# ---------------------------------------------------------------------------
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
    for tool in git curl bun perl; do
        command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
    done
    rm -rf "${SRC}"
    mkdir -p "$(dirname "${SRC}")"
    git clone --depth 1 --branch "${TAG}" "${REPO}" "${SRC}"
    ok "cloned ${TAG}"
fi
CHECKOUT_VERSION=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "${SRC}/apps/cli/package.json" | head -1)
[ "${CHECKOUT_VERSION}" = "${VERSION}" ] ||
    die "checkout reports version ${CHECKOUT_VERSION}, expected ${VERSION}"
ok "apps/cli version is ${CHECKOUT_VERSION}"

# Local-only build patches (idempotent; a fresh checkout re-patches).
if ! grep -q 'os: "freebsd"' "${SRC}/apps/cli/script/build.ts"; then
    sed -i.bak 's|{ os: "win32", arch: "arm64" },|{ os: "win32", arch: "arm64" },\
	{ os: "freebsd", arch: "x64" },|' "${SRC}/apps/cli/script/build.ts" ||
        die "could not patch the build matrix"
    ok "patched build matrix: added the freebsd target"
fi
WEBVIEW="${SRC}/apps/cline-hub/src/webview"
if grep -q 'plugin-react-swc' "${WEBVIEW}/vite.config.ts" 2>/dev/null; then
    (
        cd "${WEBVIEW}"
        bun add -d "@vitejs/plugin-react@^4.3.0" >/dev/null 2>&1
        sed -i.bak 's|@vitejs/plugin-react-swc|@vitejs/plugin-react|' vite.config.ts
    ) || die "could not patch the webview build"
    ok "patched webview build: babel react plugin (no @swc/core on FreeBSD)"
fi

# ---------------------------------------------------------------------------
# 4. Dependencies + build
# ---------------------------------------------------------------------------
echo "Dependencies:"
if [ -d "${SRC}/node_modules" ] && [ "$(cat "${DEPS_MARKER}" 2>/dev/null)" = "${VERSION}" ]; then
    ok "node_modules present for ${VERSION}"
else
    echo "  bun install (postinstall scripts skipped: grpc-tools has no FreeBSD build) ..."
    rm -rf "${SRC}/node_modules"
    if ! (cd "${SRC}" && bun install --ignore-scripts 2>&1 | tail -4); then
        echo "  install failed; clearing the bun cache and retrying once ..."
        rm -rf "${SRC}/node_modules" "${HOME}/.bun/install/cache"
        (cd "${SRC}" && bun install --ignore-scripts 2>&1 | tail -4) ||
            die "bun install failed"
    fi
    echo "${VERSION}" > "${DEPS_MARKER}"
    ok "dependencies installed"
fi

echo "Build:"
echo "  bun $(bun --version), target bun-freebsd-x64, repo pipeline apps/cli/script/build.ts --single"
if ! (cd "${SRC}/apps/cli" && bun script/build.ts --single 2>&1 | tail -15); then
    die "build failed (see output above)"
fi
BINARY="${SRC}/apps/cli/dist/cli-freebsd-x64/bin/cline"
[ -x "${BINARY}" ] || die "expected binary not found: ${BINARY}"
is_freebsd_elf "${BINARY}" || die "build output is not a FreeBSD ELF: $(file "${BINARY}")"
BUILT_VERSION=$(helper_version "${BINARY}")
[ "${BUILT_VERSION}" = "${VERSION}" ] ||
    die "binary reports ${BUILT_VERSION}, expected ${VERSION}"
ok "native binary built and smoke-tested: ${BUILT_VERSION}"
else
    BINARY="${SRC}/apps/cli/dist/cli-freebsd-x64/bin/cline"
    [ -x "${BINARY}" ] || die "no built binary at ${BINARY}; re-run with -f"
    ok "build skipped; using the existing ${BINARY}"
fi

# ---------------------------------------------------------------------------
# 5. Fix the ABI stamp
# ---------------------------------------------------------------------------
# The artifact inherits Bun's FreeBSD skeleton, which is linked on 14.3, so a
# freshly built binary says "for FreeBSD 14.3" on this 15.1 host. Re-stamp the
# note to the host's __FreeBSD_version so the artifact matches the system it
# is built and run on (`file`, elfdump, and any packaging tooling read it).
echo "ABI stamp:"
CURRENT_ABI=$(abi_of "${BINARY}")
if [ "${CURRENT_ABI}" = "${ABI_TAG}" ]; then
    ok "NT_FREEBSD_ABI_TAG already ${ABI_TAG}"
else
    restamp_abi "${BINARY}" "${ABI_TAG}" || die "could not re-stamp the ABI note"
    STAMPED_ABI=$(abi_of "${BINARY}")
    [ "${STAMPED_ABI}" = "${ABI_TAG}" ] ||
        die "ABI re-stamp failed: elfdump reports ${STAMPED_ABI:-none}, wanted ${ABI_TAG}"
    ok "NT_FREEBSD_ABI_TAG ${CURRENT_ABI:-none} -> ${STAMPED_ABI} ($(uname -s) $(uname -K))"
fi
echo "${ABI_TAG}" > "${ABI_MARKER}"
file "${BINARY}" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# 6. Stage over the helper the app actually executes
# ---------------------------------------------------------------------------
STAGED_PATHS=""
if [ "${BUILD_ONLY}" -eq 1 ]; then
    echo "Staging: skipped (--build-only); native binary is ${BINARY}"
else
    echo "Staging (native binary over the app's helper paths):"
    mkdir -p "${REMOTE_DIR}"
    for h in ${HELPERS}; do
        stage_helper "${BINARY}" "${h}"
        ok "$(basename "${h}") -> native ${VERSION}, ABI $(abi_of "${h}")"
        STAGED_PATHS="${STAGED_PATHS}${h}
"
    done
    echo "${VERSION}" > "${BUILD_MARKER}"
fi

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
if [ "${BUILD_ONLY}" -eq 0 ]; then
    echo "Verify:"
    OLDIFS=$IFS
    IFS='
'
    for h in ${STAGED_PATHS}; do
        is_freebsd_elf "${h}" || fail "$(basename "${h}") is not a FreeBSD ELF: $(file "${h}")"
        [ "$(abi_of "${h}")" = "${ABI_TAG}" ] ||
            fail "$(basename "${h}") ABI is $(abi_of "${h}"), expected ${ABI_TAG}"
        [ "$(helper_version "${h}")" = "${VERSION}" ] ||
            fail "$(basename "${h}") reports $(helper_version "${h}"), expected ${VERSION}"
    done
    IFS=$OLDIFS
    if [ "${FAILURES}" -eq 0 ]; then
        ok "staged helpers are native ${VERSION} with ABI ${ABI_TAG}"
    fi

    # The app's exact launch command, run against the staged path.
    FIRST_STAGED=$(printf '%s' "${STAGED_PATHS}" | sed -n '1p')
    echo "Live hub check ($(basename "${FIRST_STAGED}")):"
    DISC="${REMOTE_DIR}/native-check.$$"
    if /bin/bash -c "env CLINE_NO_AUTO_UPDATE=1 CLINE_HUB_LAUNCHER_CLIENT='setup-verify' CLINE_HUB_LAUNCHER_TRANSPORT=ssh '${FIRST_STAGED}' hub ensure --json --allow-port-fallback --no-connectors --login-shell-path --cwd '${HOME}' --host 127.0.0.1 --port 0 --pathname /hub --discovery-path '${DISC}'" > "${DISC}.json" 2>/dev/null; then
        HUB_URL=$(sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' "${DISC}.json" | head -1)
        if [ -n "${HUB_URL}" ]; then
            ok "hub is up: ${HUB_URL}"
        else
            fail "hub ensure returned no url: $(cat "${DISC}.json")"
        fi
    else
        fail "hub ensure failed with the app's exact launch command"
    fi
    "${FIRST_STAGED}" hub stop --discovery-path "${DISC}" >/dev/null 2>&1
    rm -rf "${DISC}" "${DISC}.json" "${DISC}".instance.lock*
    ok "hub stopped"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "${FAILURES}" -ne 0 ]; then
    echo "${FAILURES} check(s) failed; fix the items above and re-run." >&2
    exit 1
fi
if [ "${BUILD_ONLY}" -eq 1 ]; then
    echo "Native Cline helper ${VERSION} built and stamped for ABI ${ABI_TAG}:"
    echo "  ${BINARY}"
    echo "Run again without --build-only to stage it."
    exit 0
fi
echo "Native Cline helper ${VERSION} (ABI ${ABI_TAG}) is staged at:"
printf '%s' "${STAGED_PATHS}" | sed 's/^/  /'
echo ""
echo "Disconnect and reconnect Cline Desktop so it execs the new binary"
echo "(a running hub keeps the old inode). Afterwards:"
echo '  ps -axww -o pid,command | grep cline-linux-x64 | grep -v grep'
echo '  file ~/.cline/remote/cline-linux-x64-*'
echo "The first command should list a helper running with no Linux interpreter,"
echo "and 'file' should say 'for FreeBSD $(uname -r | cut -d- -f1)'."
echo ""
echo "After a Cline Desktop update (it uploads a freshly hashed Linux helper),"
echo "re-run this script to re-stage the native build."
