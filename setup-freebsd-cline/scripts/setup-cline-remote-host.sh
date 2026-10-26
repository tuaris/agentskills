#!/bin/sh
#
# setup-cline-remote-host - Prepare, verify, and repair a FreeBSD host for
# Cline Desktop's SSH remote mode (skill: setup-freebsd-cline)
#
# Cline Desktop talks to a remote host this way:
#   1. probe:  sh -c 'printf "\0CLINE_REMOTE_INSPECT_V1\0%s\0%s\0%s\0"
#      "$(uname -s)" "$(uname -m)" "$HOME"'  - it only accepts Linux or
#      Darwin as the system (FreeBSD's amd64 arch is accepted as-is)
#   2. upload: a self-contained Linux glibc helper (cline-<triple>, needs at
#      most GLIBC_2.17) to ~/.cline/remote/, cached per Cline version
#   3. start:  the helper is launched through /bin/bash; it runs a Cline Hub
#      on the host's loopback, which the app tunnels with ssh -L
#
# On FreeBSD this needs: the Linuxulator (linux64 + linux_base-rl9) to run
# the helper, a uname shim that answers the probe pattern as Linux, and a
# /bin/bash symlink (the native bash port at /usr/local/bin/bash).
#
# This script is idempotent and doubles as the update tool: after updating
# Cline Desktop, re-run it (add --refresh-helper to force the helper to be
# re-uploaded on the next connect).
#
# Usage:
#   setup-cline-remote-host [--refresh-helper] [--host HOST] [--user USER]
#     --refresh-helper  Remove staged helpers in ~/.cline/remote (re-uploaded
#                       on the next Cline Desktop connect).
#     --host HOST       Probe target host (default: 127.0.0.1, i.e. self-ssh)
#     --user USER       Probe target user (default: current user)
#
# Requires: ssh, perl, doas (for kldload / the /bin/bash symlink).
#

set -eu

MARKER=CLINE_REMOTE_INSPECT_V1
SHIM_DIR="${HOME}/.local/share/vscode-shim"
SHIM="${SHIM_DIR}/uname"
CLINE_REMOTE="${HOME}/.cline/remote"
PROBE_HOST="127.0.0.1"
PROBE_USER="$(id -un)"
REFRESH_HELPER=0
FAILURES=0

fail() {
    echo "  FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

ok() {
    echo "  ok: $*"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --refresh-helper) REFRESH_HELPER=1 ;;
        --host)
            [ $# -ge 2 ] || { echo "ERROR: --host requires an argument" >&2; exit 2; }
            PROBE_HOST="$2"; shift ;;
        --user)
            [ $# -ge 2 ] || { echo "ERROR: --user requires an argument" >&2; exit 2; }
            PROBE_USER="$2"; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

for tool in ssh perl; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found: ${tool}" >&2
        exit 1
    }
done

# --- 1. Linuxulator ---------------------------------------------------------
echo "Linuxulator:"
if kldstat 2>/dev/null | grep -qw linux64; then
    ok "linux64 module loaded"
else
    echo "  linux64 not loaded; trying 'doas kldload linux64' ..."
    if LOAD_OUT=$(doas kldload linux64 2>&1); then
        ok "linux64 loaded"
    elif printf '%s' "${LOAD_OUT}" | grep -qi 'already loaded'; then
        ok "linux64 already loaded"
    else
        fail "could not load linux64: ${LOAD_OUT} (need root: doas kldload linux64)"
    fi
fi
if [ -x /compat/linux/usr/bin/uname ]; then
    ok "linux userland present (/compat/linux/usr/bin/uname)"
else
    fail "linux userland missing; install it: doas pkg install -y linux_base-rl9 && doas service linux restart"
fi
LINUX_ENABLE=$(sysrc -n linux_enable 2>/dev/null || true)
if [ "${LINUX_ENABLE}" != "YES" ]; then
    echo "  note: linux_enable is not YES; the module will not survive a reboot"
    echo "        (fix: doas sysrc linux_enable=\"YES\")"
fi

# --- 2. /bin/bash (the app launches the helper through it) ------------------
echo "/bin/bash:"
if [ -e /bin/bash ]; then
    if [ -L /bin/bash ]; then
        ok "/bin/bash -> $(readlink /bin/bash)"
    elif [ -x /bin/bash ]; then
        ok "/bin/bash exists (regular file, executable)"
    else
        fail "/bin/bash exists but is not executable"
    fi
elif [ -x /usr/local/bin/bash ]; then
    echo "  /bin/bash missing; creating symlink to /usr/local/bin/bash ..."
    if doas ln -s /usr/local/bin/bash /bin/bash 2>/dev/null; then
        ok "/bin/bash -> /usr/local/bin/bash"
    else
        fail "could not create /bin/bash symlink (need doas)"
    fi
else
    fail "no /bin/bash and no /usr/local/bin/bash; install the bash port: doas pkg install -y bash"
fi

# --- 3. uname shim ----------------------------------------------------------
# The shim answers the Cline probe (and the VS Code / Agents / Zed / Devin
# probes) with the Linux uname; every other caller gets the real FreeBSD
# uname. It is the extended version from the setup-freebsd-vscode skill.
echo "uname shim:"
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
# For those callers answer with the Linux uname, which runs natively through
# the Linuxulator. Every other caller gets the real FreeBSD uname.
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
        [ -x /compat/linux/usr/bin/uname ] && exec /compat/linux/usr/bin/uname "$@"
        ;;
esac

exec /usr/bin/uname "$@"
SHIM
    chmod 755 "${SHIM}"
}

if [ -f "${SHIM}" ] && grep -q "${MARKER}" "${SHIM}"; then
    ok "${SHIM} present with the ${MARKER} pattern"
elif [ -f "${SHIM}" ]; then
    echo "  ${SHIM} present but missing the ${MARKER} pattern; updating ..."
    cp -p "${SHIM}" "${SHIM}.bak-$(date +%Y%m%d)" 2>/dev/null || true
    install_shim
    ok "shim updated (previous copy kept as ${SHIM}.bak-*)"
else
    echo "  ${SHIM} missing; installing ..."
    install_shim
    ok "shim installed"
fi

# PATH hook for non-interactive SSH sessions.
if [ "$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7)" = "/usr/local/bin/fish" ] || [ "${SHELL:-}" = "/usr/local/bin/fish" ]; then
    FISH_HOOK="${HOME}/.config/fish/conf.d/10-vscode-shim.fish"
    if [ -f "${FISH_HOOK}" ] && grep -q "vscode-shim" "${FISH_HOOK}"; then
        ok "fish PATH hook present (${FISH_HOOK})"
    elif [ -f "${FISH_HOOK}" ]; then
        fail "fish PATH hook does not reference the shim dir: ${FISH_HOOK}"
    else
        echo "  fish PATH hook missing; creating ${FISH_HOOK} ..."
        mkdir -p "$(dirname "${FISH_HOOK}")"
        echo "fish_add_path --path --prepend \$HOME/.local/share/vscode-shim" > "${FISH_HOOK}"
        ok "fish PATH hook created"
    fi
else
    echo "  note: login shell is not fish; make sure ${SHIM_DIR} is first in"
    echo "        PATH for non-interactive SSH (e.g. export PATH in the shell rc)"
fi

# --- 4. Live probe (exactly what Cline Desktop sends) ------------------------
echo "remote probe (${PROBE_USER}@${PROBE_HOST}):"
PROBE_SCRIPT="printf \"\\000${MARKER}\\000%s\\000%s\\000%s\\000\" \"\$(uname -s)\" \"\$(uname -m)\" \"\$HOME\""
PAYLOAD=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
    "${PROBE_USER}@${PROBE_HOST}" "sh -c '${PROBE_SCRIPT}'" 2>/dev/null | perl -pe 's/\x00/|/g' || true)
RESULT=$(printf '%s' "${PAYLOAD}" | perl -ne "if (/^\|${MARKER}\|([^|]*)\|([^|]*)\|([^|]*)\|\z/) { print \"\$1/\$2\" }")
case "${RESULT}" in
    Linux/x86_64|Linux/amd64|Linux/x64)
        ok "probe reports ${RESULT}" ;;
    "")
        fail "probe returned no parseable payload (raw: ${PAYLOAD:-<empty>})"
        echo "       check key-based auth: ssh ${PROBE_USER}@${PROBE_HOST}" >&2
        ;;
    *)
        fail "probe reports ${RESULT}; Cline needs Linux/x86_64"
        echo "       the shim is not answering the probe pattern; check it is first in PATH" >&2
        ;;
esac

# --- 5. Staged helper ---------------------------------------------------------
echo "staged helper (${CLINE_REMOTE}):"
if [ -d "${CLINE_REMOTE}" ] && ls "${CLINE_REMOTE}"/cline-* >/dev/null 2>&1; then
    for f in "${CLINE_REMOTE}"/cline-*; do
        MAGIC=$(head -c 4 "${f}" | od -An -tx1 | tr -d ' \n')
        if [ "${MAGIC}" = "7f454c46" ] && [ -x "${f}" ]; then
            ok "$(basename "${f}") is an executable ELF"
        else
            fail "$(basename "${f}") is not an executable ELF (MAGIC=${MAGIC}); remove it and reconnect to re-upload"
        fi
    done
    if [ "${REFRESH_HELPER}" -eq 1 ]; then
        echo "  --refresh-helper: removing staged helpers (re-uploaded on next connect) ..."
        rm -f "${CLINE_REMOTE}"/cline-*
        ok "staged helpers removed"
    fi
else
    echo "  none staged yet (uploaded automatically on first connect)"
    if [ "${REFRESH_HELPER}" -eq 1 ]; then
        echo "  --refresh-helper: nothing to remove"
    fi
fi

# --- Summary ------------------------------------------------------------------
echo ""
if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed. Add the host in Cline Desktop (Settings -> Remote)"
    echo "and pick it from the environment selector."
    exit 0
else
    echo "${FAILURES} check(s) failed; fix the items above and re-run." >&2
    exit 1
fi
