#!/bin/bash
# Exercise the actual Swift helper and host OpenSSH config/proxy parsers.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASE="$(mktemp -d "${TMPDIR:-/tmp}/ltm-device-access.XXXXXX")"
trap 'rm -rf "$CASE"' EXIT
swiftc -module-cache-path "$CASE/modules" "$ROOT/tools/device-access/main.swift" -o "$CASE/access"
ID=7DCECEB7-1B4C-4F12-9F9D-3B4F93F5BA45
OTHER=4DCECEB7-1B4C-4F12-9F9D-3B4F93F5BA45
HOST=lighttouch-7dceceb7-1b4c-4f12-9f9d-3b4f93f5ba45
PROXY="$CASE/inetcat's %tool"
cat > "$PROXY" <<'SH'
#!/bin/sh
printf '%s\n' "$USBMUXD_SOCKET_ADDRESS" "$@" > "$ACCESS_CAPTURE"
exit 1
SH
chmod +x "$PROXY"
export ACCESS_CAPTURE="$CASE/capture"
export USBMUXD_SOCKET_ADDRESS=127.0.0.1:9999
"$CASE/access" config --instance "$ID" --usbmux 127.0.0.1:27017 --inetcat "$PROXY" --state "$CASE/known hosts" > "$CASE/config"
/usr/bin/ssh -G -F "$CASE/config" "$HOST" > "$CASE/resolved" 2>/dev/null
rg -q '^strictHostKeyChecking ask$|^stricthostkeychecking ask$' "$CASE/resolved"
rg -q "hostkeyalias $HOST" "$CASE/resolved"
rg -q 'userknownhostsfile .*known hosts/7dceceb7-1b4c-4f12-9f9d-3b4f93f5ba45/known_hosts' "$CASE/resolved"
# Proxy exits immediately; verify actual SSH invoked the correctly quoted tool
# with its immutable endpoint, despite an unrelated parent endpoint.
if "$CASE/access" ssh --instance "$ID" --usbmux 127.0.0.1:27017 --inetcat "$PROXY" --state "$CASE/known hosts" > "$CASE/out" 2> "$CASE/err"; then exit 1; fi
[ "$(sed -n '1p' "$CASE/capture")" = 127.0.0.1:27017 ]
[ "$(sed -n '2p' "$CASE/capture")" = -l ]
[ "$(sed -n '3p' "$CASE/capture")" = 22 ]
[ "$USBMUXD_SOCKET_ADDRESS" = 127.0.0.1:9999 ]
"$CASE/access" config --instance "$OTHER" --usbmux 127.0.0.1:27018 --inetcat "$PROXY" --state "$CASE/known hosts" > "$CASE/other"
rg -q 'Host lighttouch-4dceceb7-1b4c-4f12-9f9d-3b4f93f5ba45' "$CASE/other"
[ "$("$CASE/access" gdb --instance "$ID" --gdb 127.0.0.1:1234)" = 'target remote 127.0.0.1:1234' ]
if "$CASE/access" gdb --instance "$ID" --gdb 0.0.0.0:1234 2>/dev/null; then exit 1; fi
if "$CASE/access" config --instance "$ID" --usbmux 127.0.0.1:0 --inetcat "$PROXY" 2>/dev/null; then exit 1; fi
if "$CASE/access" config --instance "$ID" --usbmux 127.0.0.1:22 --inetcat "$PROXY" --state relative 2>/dev/null; then exit 1; fi
printf '%s\n' 'PASS: OpenSSH config, quoted inetcat invocation, immutable endpoint, per-instance identity, GDB command, invalid endpoint/path rejection'
