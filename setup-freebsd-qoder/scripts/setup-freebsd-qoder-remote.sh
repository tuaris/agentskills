#!/bin/sh
#
# setup-freebsd-qoder-remote - prepare a FreeBSD host for Qoder Desktop remote SSH
#
# Qoder Desktop (the standalone app) has a built-in remote SSH mode that runs a
# Linux "remote runtime" (a bundled Node.js host + worker) on the target host.
# FreeBSD is not a supported platform, so the client's bootstrap rejects it.
# This script makes the host acceptable to that bootstrap WITHOUT touching any
# other IDE/agent setup (Devin, VS Code, Cline, OpenCode, Zed):
#
#   1. Prerequisites: bash, curl, jq, git; the Linuxulator (linux64 + Rocky 9
#      userland) which runs the Linux runtime; a /bin/bash symlink.
#   2. Three small shims in ~/.local/share/vscode-shim (the same directory the
#      VS Code / Cline skills use), each answering only its specific caller and
#      passing every other caller straight through to the real FreeBSD tool:
#        uname   - adds the Qoder bootstrap pattern to the existing shared shim
#        getconf - reports the Linuxulator glibc for Qoder's platform probe
#        mv      - routes the GNU-only `mv -T` to the Linuxulator's GNU mv
#   3. A PATH hook so the shim dir is first for non-interactive SSH sessions.
#   4. A live self-ssh probe that reproduces Qoder's exact platform check.
#
# It does NOT install the runtime itself: Qoder auto-installs it on first
# connect. To pre-seed or repair the runtime, use update-qoder-runtime.
#
# Usage:
#   setup-freebsd-qoder-remote [--host H] [--user U]
#     --host H   SSH host to probe (default: localhost, i.e. self-ssh)
#     --user U   SSH user to probe (default: the current user)
#
# Idempotent: safe to re-run. Backups of any replaced shim are kept as
# <shim>.bak-qoder-<date>. Requires doas for the one-time privileged steps.

set -eu

SHIM_DIR="${HOME}/.local/share/vscode-shim"
PROBE_HOST="localhost"
PROBE_USER="$(id -un)"
STAMP="$(date +%Y%m%d)"

ok()   { printf '  ok: %s\n' "$1"; }
note() { printf '  note: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host) PROBE_HOST="$2"; shift ;;
        --user) PROBE_USER="$2"; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[ "$(uname -s)" = "FreeBSD" ] || fail "this script must run on the FreeBSD host"

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
echo "Prerequisites:"

# Packages the bootstrap and the update helper need. tar / sha256sum are in the
# FreeBSD base system; the rest come from pkg.
MISSING=""
for tool in bash curl jq git; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    note "installing packages:$MISSING"
    doas pkg install -y $MISSING || fail "could not install packages:$MISSING"
fi
command -v tar >/dev/null 2>&1 || fail "tar is missing (base system)"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || fail "sha256sum/shasum is missing"
ok "bash, curl, jq, git, tar, sha256 present"

# Linuxulator: the runtime is a set of Linux ELF binaries (Node.js + host +
# worker), so linux64.ko and the Rocky 9 userland are required.
if ! kldstat 2>/dev/null | grep -qw linux64; then
    note "loading linux64 kernel module"
    doas kldload linux64 || fail "kldload linux64 failed"
    doas sysrc linux_enable="YES" >/dev/null
fi
if [ ! -x /compat/linux/usr/bin/uname ]; then
    note "installing Rocky 9 Linux userland (linux_base-rl9)"
    doas pkg install -y linux_base-rl9 || fail "pkg install linux_base-rl9 failed"
    doas service linux restart >/dev/null 2>&1 || true
fi
[ -x /compat/linux/usr/bin/uname ] || fail "Linuxulator userland missing (/compat/linux)"
[ -x /compat/linux/usr/bin/getconf ] || fail "Linux getconf missing (linux_base-rl9)"
[ -x /compat/linux/usr/bin/mv ] || fail "Linux GNU mv missing (linux_base-rl9)"
ok "Linuxulator ready (linux64 + linux_base-rl9, $(/compat/linux/usr/bin/getconf GNU_LIBC_VERSION))"

# The runtime's terminal falls back to /bin/bash when SHELL is unset; stock
# FreeBSD has no /bin/bash. Same symlink the Cline skill creates.
if [ ! -e /bin/bash ]; then
    if [ -x /usr/local/bin/bash ]; then
        doas ln -s /usr/local/bin/bash /bin/bash || fail "could not create /bin/bash"
        ok "/bin/bash -> /usr/local/bin/bash"
    else
        fail "no /bin/bash and no /usr/local/bin/bash (doas pkg install -y bash)"
    fi
else
    ok "/bin/bash present"
fi

# ---------------------------------------------------------------------------
# 2. Shims (additive; every non-matching caller gets the real FreeBSD tool)
# ---------------------------------------------------------------------------
echo "Shims:"
mkdir -p "${SHIM_DIR}"

backup_if_present() {
    # $1 = target path; keep a dated backup before replacing an existing file
    if [ -f "$1" ]; then
        cp -p "$1" "$1.bak-qoder-${STAMP}" 2>/dev/null || true
    fi
}

# --- uname: superset of the VS Code / Agents / Zed / Devin / Cline patterns,
#     plus the Qoder bootstrap pattern. Qoder runs its preflight/download/install
#     scripts as `sh -s -- <args> .qoder`, so the parent of the `uname` call is
#     that sh. The existing bare `sh` pattern does not match it; add it here.
UNAME_CHANGED=1
if [ -f "${SHIM_DIR}/uname" ] && grep -q 'sh -s -- ' "${SHIM_DIR}/uname" \
    && grep -q 'CLINE_REMOTE_INSPECT_V1' "${SHIM_DIR}/uname"; then
    UNAME_CHANGED=0
fi
if [ "${UNAME_CHANGED}" -eq 1 ]; then
    backup_if_present "${SHIM_DIR}/uname"
    cat > "${SHIM_DIR}/uname" <<'UNAME_SHIM'
#!/bin/sh
#
# uname shim for VS Code Remote-SSH, the Agents window, Zed/Devin probes,
# Cline Desktop remote inspection, and the Qoder Desktop remote bootstrap.
#
# Each IDE rejects a FreeBSD host unless `uname` answers Linux. Only the
# specific probe callers below get the Linux answer (from the Linuxulator
# uname, or a static fallback when it is absent); every other caller gets the
# real FreeBSD uname so builds and terminals are unaffected.
#
# Install as ~/.local/share/vscode-shim/uname (mode 755), first in PATH for
# non-interactive SSH sessions.

parent_cmd=$(ps -o command= -p "${PPID}" 2>/dev/null)

# The exact combined form `-sm` is only ever used by the Zed/Devin probes.
if [ "$*" = "-sm" ]; then
    parent_cmd=sh
fi

case "${parent_cmd}" in
    sh|*" -c uname -s"|*" -c uname -m"|*" -c uname -sm"|*CLINE_REMOTE_INSPECT_V1*|*"sh -s -- "*.qoder*)
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
UNAME_SHIM
    chmod 755 "${SHIM_DIR}/uname"
    ok "uname shim installed (Qoder pattern added, other IDE patterns kept)"
else
    ok "uname shim already answers the Qoder bootstrap"
fi

# --- getconf: Qoder's preflight runs `getconf GNU_LIBC_VERSION` and the runtime
#     host re-checks it at startup. FreeBSD's getconf has no GNU_LIBC_VERSION,
#     so answer from the Linuxulator getconf for Qoder callers only.
if [ -f "${SHIM_DIR}/getconf" ] && grep -q 'GNU_LIBC_VERSION' "${SHIM_DIR}/getconf"; then
    ok "getconf shim already present"
else
    backup_if_present "${SHIM_DIR}/getconf"
    cat > "${SHIM_DIR}/getconf" <<'GETCONF_SHIM'
#!/bin/sh
#
# getconf shim for the Qoder Desktop remote bootstrap and runtime host.
#
# Qoder's preflight (`sh -s -- <args> .qoder`) and its Linux Node runtime
# (runtime-host.cjs / qoder-worker-runtime) run `getconf GNU_LIBC_VERSION` to
# confirm a glibc userland. FreeBSD's native getconf does not know that
# parameter, so for those callers answer from the Linuxulator getconf (Rocky 9
# glibc). Every other caller gets the real FreeBSD getconf.
#
# Install as ~/.local/share/vscode-shim/getconf (mode 755).

parent_cmd=$(ps -o command= -p "${PPID}" 2>/dev/null)

case "${parent_cmd}" in
    *"sh -s -- "*.qoder*|*runtime-host.cjs*|*qoder-worker-runtime*|*".qoder/remote/"*)
        if [ -x /compat/linux/usr/bin/getconf ]; then
            exec /compat/linux/usr/bin/getconf "$@"
        fi
        case "$*" in
            GNU_LIBC_VERSION) echo "glibc 2.34"; exit 0 ;;
        esac
        ;;
esac

exec /usr/bin/getconf "$@"
GETCONF_SHIM
    chmod 755 "${SHIM_DIR}/getconf"
    ok "getconf shim installed"
fi

# --- mv: Qoder's install/rollback scripts use the GNU-only `mv -Tf` for the
#     atomic `current` symlink swap; BSD mv rejects -T. Route any -T call to the
#     Linuxulator's GNU mv. No native FreeBSD caller can legitimately pass -T
#     (it always failed before), so this cannot change existing behavior.
if [ -f "${SHIM_DIR}/mv" ] && grep -q 'no-target-directory' "${SHIM_DIR}/mv"; then
    ok "mv shim already present"
else
    backup_if_present "${SHIM_DIR}/mv"
    cat > "${SHIM_DIR}/mv" <<'MV_SHIM'
#!/bin/sh
#
# mv shim for the Qoder Desktop remote runtime installer.
#
# Qoder's install/rollback scripts replace the `current` symlink with the
# GNU-only `mv -Tf` (treat destination as a file, atomic rename). BSD mv has no
# -T, so route any -T / --no-target-directory invocation to the Linuxulator's
# GNU mv, which operates on the native paths correctly. All other mv calls go
# to the native BSD mv unchanged.
#
# Install as ~/.local/share/vscode-shim/mv (mode 755).

for arg in "$@"; do
    case "$arg" in
        -T|-Tf|-fT|--no-target-directory)
            exec /compat/linux/usr/bin/mv "$@" ;;
    esac
done

exec /bin/mv "$@"
MV_SHIM
    chmod 755 "${SHIM_DIR}/mv"
    ok "mv shim installed"
fi

# ---------------------------------------------------------------------------
# 3. PATH hook (non-interactive SSH must see the shim dir first)
# ---------------------------------------------------------------------------
echo "PATH hook:"
LOGIN_SHELL="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7 || true)"
if [ "${LOGIN_SHELL}" = "/usr/local/bin/fish" ] || [ "${SHELL:-}" = "/usr/local/bin/fish" ]; then
    FISH_HOOK="${HOME}/.config/fish/conf.d/10-vscode-shim.fish"
    if [ -f "${FISH_HOOK}" ] && grep -q "vscode-shim" "${FISH_HOOK}"; then
        ok "fish PATH hook present"
    else
        mkdir -p "$(dirname "${FISH_HOOK}")"
        echo 'fish_add_path --path --prepend $HOME/.local/share/vscode-shim' > "${FISH_HOOK}"
        ok "fish PATH hook created (${FISH_HOOK})"
    fi
else
    note "login shell is not fish; ensure ${SHIM_DIR} is first in PATH for"
    note "non-interactive SSH (e.g. export PATH=\"${SHIM_DIR}:\$PATH\" atop ~/.bashrc)"
fi

# ---------------------------------------------------------------------------
# 4. Live probe: reproduce Qoder's exact platform check over ssh
# ---------------------------------------------------------------------------
echo "Probe (${PROBE_USER}@${PROBE_HOST}):"
PROBE_ID="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PROBE_SCRIPT='os=$(uname -s); mach=$(uname -m); libc=$(getconf GNU_LIBC_VERSION 2>/dev/null || true); printf "os=%s mach=%s libc=%s\n" "$os" "$mach" "$libc"'
RESULT=$(printf '%s\n' "${PROBE_SCRIPT}" |
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
        "${PROBE_USER}@${PROBE_HOST}" "sh -s -- ${PROBE_ID} .qoder" 2>/dev/null || true)
case "${RESULT}" in
    "os=Linux mach=x86_64 libc=glibc "*|"os=Linux mach=amd64 libc=glibc "*)
        ok "probe reports ${RESULT}" ;;
    "")
        fail "probe returned nothing (key auth for ssh ${PROBE_USER}@${PROBE_HOST}?)" ;;
    *)
        fail "probe reports '${RESULT}'; Qoder needs Linux/x86_64/glibc (shim not first in PATH?)" ;;
esac

echo ""
echo "Host is ready for Qoder Desktop remote SSH."
echo "Next: add/connect the host in Qoder Desktop (it auto-installs the runtime)."
echo "Optional: pre-seed the runtime with 'update-qoder-runtime' for an instant first connect."