#!/bin/bash
# Produce a pinned minimal developer payload with source and license notices.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?usage: fetch.sh NEW-PAYLOAD-DIRECTORY}"
[ ! -e "$DEST" ] || { echo 'destination exists' >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
OUT="$(mktemp -d "$(dirname "$DEST")/.developer-tools.XXXXXX")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ltm-ssh-source.XXXXXX")"
trap 'rm -rf "$TMP" "$OUT"' EXIT
PIN=2f818780e5c808b09c3497f1745dde1bdce8e372
fetch() {
    local archive=$1 expected=$2
    curl -fLsS "https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/$PIN/resources/jailbreak/$archive.tar.gz" -o "$TMP/$archive.tar.gz"
    [ "$(shasum -a256 "$TMP/$archive.tar.gz" | cut -d' ' -f1)" = "$expected" ] || { echo "hash mismatch: $archive" >&2; exit 1; }
}
fetch openssh 96d7ecd8b71cfafe3e722cebc5a635b0484544fa1d453cbda98c35a4f091b293
fetch openssl 7b1c997fb9b320d7de401130e6fd37884807d5dcb6ceeca2b391c94b6a4e4d32
# Only these standard BSD/OpenSSL files are taken from the historical archives.
# No freeze bootstrap, GPL binaries of unknown origin, keys, or guest patches.
tar -xzf "$TMP/openssh.tar.gz" -C "$OUT" ./usr/sbin/sshd ./usr/libexec/sftp-server
tar -xzf "$TMP/openssl.tar.gz" -C "$OUT" ./usr/lib/libcrypto.0.9.8.dylib
"$HERE/build-shell.sh" "$TMP/shell"
mkdir -p "$OUT/bin" "$OUT/Sources" "$OUT/Licenses"
cp "$TMP/shell/bash" "$OUT/bin/bash"
cp -R "$TMP/shell/Sources/" "$OUT/Sources/"
cp -R "$TMP/shell/Licenses/" "$OUT/Licenses/"
cp "$HERE/licenses/OpenSSH-6.7p1-LICENCE.txt" "$HERE/licenses/OpenSSL-0.9.8zg-LICENSE.txt" "$OUT/Licenses/"
cat > "$TMP/manifest.swift" <<'SWIFT'
import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let targets = ["usr/sbin/sshd", "usr/libexec/sftp-server", "bin/bash", "usr/lib/libcrypto.0.9.8.dylib"]
let expected = ["usr/sbin/sshd": "737a9b0decfe7008641b38f3be18c2bb9006f258f2fb81d3598f52f510b8357b", "usr/libexec/sftp-server": "c6ea137ba834febc9b69848f02a68b529a3eaa88a11768f6682e159c05db0906", "usr/lib/libcrypto.0.9.8.dylib": "bb7cff246d604171a4179cd2fb1a1d97f06ac2e534342b7039ad40aed8bb30de", "bin/bash": "ef8ec95c81d8b48a088d5603bd4a652505b9f641ebafd9ba93e261074a4d971c"]
var hashes: [String: String] = [:]
for target in targets {
    let data = try Data(contentsOf: root.appendingPathComponent(target))
    hashes[target] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard hashes[target] == expected[target] else {
        FileHandle.standardError.write(Data("unqualified developer payload: \(target)\n".utf8))
        exit(1)
    }
}
let manifest: [String: Any] = ["source": "Legacy-iOS-Kit/2f818780e5c808b09c3497f1745dde1bdce8e372+GNU/bash-4.0.40/minimal-v1", "files": hashes]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("developer-tools.json"))
SWIFT
swift -module-cache-path "$TMP/modules" "$TMP/manifest.swift" "$OUT"
cp "$HERE/README.md" "$OUT/Sources/provenance.md"
# Publish only a fully qualified payload and its corresponding source/notices.
mv "$OUT" "$DEST"
