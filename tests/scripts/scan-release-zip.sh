#!/bin/bash
# tools/release/scan-release-zip.py over small zips: clean passes; a home path, an email it's asked for, a private key,
# a .DS_Store, and one inside a compressed NAND chunk fail; a code signature's name and sshd's bare key header don't.
#     tests/scripts/scan-release-zip.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$SRC/tools/release/scan-release-zip.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-scan-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
failed=0
# expect WANT WHAT SETUP [ARGS]: a fresh app, SETUP run in it, and the scanner's exit status.
expect() {
    local want=$1 what=$2 setup=$3
    shift 3
    rm -rf "$T/A.app" "$T/a.zip"
    mkdir -p "$T/A.app/Contents"
    printf 'plain\n' > "$T/A.app/Contents/ok"
    (cd "$T/A.app/Contents" && eval "$setup")
    (cd "$T" && ditto -c -k --keepParent A.app a.zip)
    python3 "$SCAN" "$T/a.zip" "$@" > /dev/null 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then echo "ok   $what"; else echo "FAIL $what: exit $got, not $want"; failed=1; fi
}
expect 0 "a clean app passes" ":"
expect 1 "the home folder" 'printf "%s/x" "$HOME" > leak'
expect 1 "a word asked for" 'printf "me@example.test" > leak' --also me@example.test
expect 1 "a private key" 'printf -- "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAwJ7wJ7wJ7wJ7wJ7wJ7wJ7wJ7wJ7wJ7w\n" > key'
expect 0 "sshd's bare key header" 'printf -- "-----BEGIN RSA PRIVATE KEY-----\n\0" > sshd'
expect 1 "a key's file name" 'printf x > AuthKey_ABCDEFGHIJ.p8'
expect 1 ".DS_Store" 'printf x > .DS_Store'
expect 1 "inside a NAND chunk" 'python3 -I -c "import os,zlib;open(\"000001.z\",\"wb\").write(zlib.compress(os.environ[\"HOME\"].encode()))"'
expect 1 "an unreadable chunk" 'printf nope > 000001.z'
expect 0 "a signature's identity" 'printf "Developer ID Application: me@example.test (X)\0" > bin' --also me@example.test
python3 "$SCAN" "$T/missing.zip" > /dev/null 2>&1
[[ $? == 2 ]] && echo "ok   no zip is exit 2" || { echo "FAIL no zip"; failed=1; }
exit $failed
