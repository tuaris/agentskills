#!/bin/sh
#
# uname shim for VS Code Remote-SSH and the Agents window on FreeBSD
#
# VS Code rejects any host whose `uname -s` is not Linux or whose `uname -m` is
# not x86_64 (FreeBSD prints amd64). Two callers need the Linux answer:
#   * the Remote-SSH bootstrap, which pipes its script into a bare `sh`
#   * the Agents window probe, which runs `uname -s` and `uname -m` as separate
#     SSH exec commands, so the parent is `<login shell> -c uname -s|-m`
# For those callers answer with the Linux uname, which runs natively through
# the Linuxulator. Every other caller gets the real FreeBSD uname.
#
# Install as ~/.local/share/vscode-shim/uname (mode 755) and put that directory
# first in PATH for non-interactive SSH sessions.

parent_cmd=$(ps -o command= -p "${PPID}" 2>/dev/null)

case "${parent_cmd}" in
    sh|*" -c uname -s"|*" -c uname -m"|*" -c uname -sm")
        [ -x /compat/linux/usr/bin/uname ] && exec /compat/linux/usr/bin/uname "$@"
        ;;
esac

exec /usr/bin/uname "$@"
