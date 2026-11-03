#!/bin/sh
#
# update-cline - re-point ~/bin/cline at the native helper currently staged
#
# Cline Desktop names the helper it uploads after the helper's own sha256:
#   ~/.cline/remote/cline-linux-x64-<sha256:16>
# so a local edit to that file survives updates (the app sees the path already
# exists and skips the upload), but the app does NOT change the name when it is
# updated in place. Whenever a *new* helper name appears, a plain
# ~/bin/cline -> ~/.cline/remote/<old name> symlink dangles until it is
# repointed here. ~/bin is on PATH for every login shell, so this is what keeps
# `cline` working the way `~/bin/devin` does.
#
# Resolution order for the link target:
#   1. ~/.cline/remote/cline-linux-x64-<hash>  (the path the app execs, and the
#      one setup-freebsd-cline-remote restages with the native build)
#   2. the highest native version among other staged helpers
# *.linux-elf backups and partially written *.new.* files are never linked.
#
# Deliberately does NOT run `cline update`: the CLI's self-updater would fetch
# an upstream build into the staged path and discard the native FreeBSD
# binary. To move to a new CLI version, run setup-freebsd-cline-remote; it
# rebuilds, restages and re-points this link.
#
# Usage: update-cline [-n|--dry-run] [-h|--help] [-v|--verbose]
#
# Exit: 0 when every entry link points at a native FreeBSD helper and runs;
#       1 when no usable helper was found or a link could not be verified.

set -eu

REMOTE_DIR="${HOME}/.cline/remote"
LINK_DIR="${HOME}/bin"
ENTRY_LINKS="${CLINE_ENTRY_LINKS:-${LINK_DIR}/cline}"
DRY_RUN=0
VERBOSE=0

die() {
    echo "update-cline: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

echo "update-cline: staged helpers in ${REMOTE_DIR}"

# Candidate helpers: the app's hashed staging paths, plus the older
# client-side lookup name. -type f skips dangling symlinks and directories;
# *.linux-elf are the original Linux helpers and are never valid targets.
CANDIDATES=""
for p in "${REMOTE_DIR}"/cline-linux-x64-* "${REMOTE_DIR}"/cline-x86_64-unknown-linux-gnu; do
    [ -f "${p}" ] || continue
    case "${p}" in *.linux-elf|*.new.*) continue ;; esac
    CANDIDATES="${CANDIDATES}${p}
"
done
[ -n "${CANDIDATES}" ] ||
    die "no staged helper found; connect Cline Desktop once, then run setup-freebsd-cline-remote"

# The app's hashed helper is the path it execs and the one the setup script
# restages: prefer it over the client-side lookup name.
TARGET=""
while IFS= read -r p; do
    case "$(basename "${p}")" in
        cline-linux-x64-*) TARGET="${p}"; break ;;
    esac
done <<EOF
$(printf '%s' "${CANDIDATES}" | sort -r)
EOF

if [ -z "${TARGET}" ]; then
    # Only the legacy name staged: take it, but say so.
    TARGET=$(printf '%s' "${CANDIDATES}" | sed -n '1p')
    echo "update-cline: only the legacy helper name is staged: $(basename "${TARGET}")"
fi

is_freebsd_elf() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q 'FreeBSD'
}

if ! is_freebsd_elf "${TARGET}"; then
    echo "update-cline: WARNING: $(basename "${TARGET}") is not a FreeBSD ELF:" >&2
    file "${TARGET}" >&2
    echo "update-cline: run setup-freebsd-cline-remote to build and stage the native helper." >&2
    echo "update-cline: refusing to point the CLI at a Linux helper." >&2
    exit 1
fi

VERSION=$(env CLINE_NO_AUTO_UPDATE=1 "${TARGET}" --version 2>/dev/null) || VERSION="?"
echo "update-cline: target $(basename "${TARGET}") (cline ${VERSION})"

# Re-point every entry link that currently aims into ~/.cline/remote, plus the
# canonical ~/bin/cline (creating it if it does not exist yet).
LINKS=""
for l in ${ENTRY_LINKS}; do
    if [ -L "${l}" ]; then
        case "$(readlink "${l}" 2>/dev/null)" in
            "${REMOTE_DIR}"/*) ;;
            *) continue ;;
        esac
    elif [ ! -e "${l}" ]; then
        : # not present yet: create it below
    else
        continue
    fi
    # Same path may arrive twice (default plus CLINE_ENTRY_LINKS).
    case "${LINKS}" in
        *"${l}
"*) continue ;;
    esac
    LINKS="${LINKS}${l}
"
done
[ -n "${LINKS}" ] || die "no entry link to update (looked for: ${ENTRY_LINKS})"

RC=0
while IFS= read -r l; do
    [ -n "${l}" ] || continue
    old=$(readlink "${l}" 2>/dev/null || echo "(none)")
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "update-cline: would link $(basename "${l}") -> $(basename "${TARGET}") (was: $(basename "${old}"))"
        continue
    fi
    mkdir -p "$(dirname "${l}")"
    ln -sfn "${TARGET}" "${l}"
    # Verify through the link itself, the way a shell would invoke it.
    if got=$(env CLINE_NO_AUTO_UPDATE=1 "${l}" --version 2>/dev/null); then
        echo "update-cline: $(basename "${l}") -> $(basename "${TARGET}") OK (cline ${got})"
    else
        echo "update-cline: $(basename "${l}") FAILED to run after relinking" >&2
        RC=1
    fi
    [ "${VERBOSE}" -eq 1 ] && echo "  was: ${old}"
done <<EOF
${LINKS}
EOF

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "update-cline: dry run; nothing changed"
    exit 0
fi

exit "${RC}"
