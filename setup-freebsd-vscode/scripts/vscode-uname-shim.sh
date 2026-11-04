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
