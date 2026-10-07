#!/bin/sh
#
# ldd shim for the VS Code Server prerequisite check on FreeBSD
#
# The VS Code CLI decides between glibc and musl by running `ldd --version`.
# FreeBSD's native ldd does not print a glibc version, so the CLI concludes the
# host is musl and refuses to start ("find /lib/ld-musl-x86_64.so.1 ..."). When
# the caller is the VS Code CLI or server, answer with the Linux ldd from the
# Linuxulator userland. Every other caller gets the real FreeBSD ldd.
#
# Install as ~/.local/share/vscode-shim/ldd (mode 755) next to the uname shim.

parent_cmd=$(ps -o command= -p "${PPID}" 2>/dev/null)

case "${parent_cmd}" in
    *code-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*|*/.vscode-server/*)
        # The Linux ldd is a bash script; run it with the Linux bash directly
        # because its /bin/bash shebang does not exist on the native side.
        exec /compat/linux/usr/bin/bash /compat/linux/usr/bin/ldd "$@"
        ;;
esac

exec /usr/bin/ldd "$@"
