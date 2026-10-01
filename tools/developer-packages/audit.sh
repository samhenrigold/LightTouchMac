#!/bin/bash
# Build-time read-only audit; uses the same leaf implementation as the app/CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAYLOAD="${1:?usage: audit.sh PAYLOAD-DIRECTORY}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ltm-developer-audit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/Audit.swift" <<'SWIFT'
import Foundation
@main enum Audit {
    static func main() {
        do {
            try DeveloperTools.audit(payload: URL(fileURLWithPath: CommandLine.arguments[1]), redistribution: true)
            print("PASS: qualified developer release resources")
        } catch {
            FileHandle.standardError.write(Data("developer-audit: \(error)\n".utf8))
            exit(1)
        }
    }
}
SWIFT
swiftc -module-cache-path "$TMP/modules" "$ROOT/Packages/FirmwareKit/Sources/FirmwareKit/DeveloperTools/DeveloperTools.swift" "$TMP/Audit.swift" -o "$TMP/audit"
"$TMP/audit" "$PAYLOAD"
