#!/bin/bash
# scripts/ship's logic that needs no Apple service: the next free tag, the notes check, the Xcode pin (the running build
# against build-support/sources.json's, both ways, and --pin-xcode), the notary config (environment, file, mode,
# partial keys), filling the IPSW cache (a local clone, a wrong copy refused, a download checked), pruning old
# archives and work directories (a failed run's too), the argument checks it makes before any work (and the deprecated
# scripts/release's hand-over), and `ltm-build release`'s catalog, Amore id and appcast checks (a real Ed25519 signature, a tampered DMG).
# Prints ok/FAIL per check; exits 1 on any FAIL.
#     tests/scripts/ship.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-ship-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
source "$SRC/scripts/ship"
HELPER=("$SRC/scripts/ltm-build" release)

# tags
check "a free date is the bare tag" '[[ "$(next_tag v1.0-2026.10.21)" == v1.0-2026.10.21 ]]'
check "a taken date gets b" '[[ "$(next_tag v1.0-2026.10.21 v1.0-2026.10.21)" == v1.0-2026.10.21b ]]'
check "b taken gets c" '[[ "$(next_tag v1.0-2026.10.21 v1.0-2026.10.21b v1.0-2026.10.21)" == v1.0-2026.10.21c ]]'
check "another date's tag doesn't count" '[[ "$(next_tag v1.0-2026.10.21 v1.0-2026.10.20)" == v1.0-2026.10.21 ]]'

# notes
printf '## What'\''s new\n- Cover Flow shows album art.\n' > "$T/notes.md"
printf ' \n\t\n' > "$T/blank.md"
printf '## What'\''s new\n- TODO: the headline\n' > "$T/todo.md"
check "good notes pass" '[[ -z "$(notes_problem "$T/notes.md")" ]]'
check "missing notes fail" '[[ "$(notes_problem "$T/nope.md")" == "no notes at"* ]]'
check "blank notes fail" '[[ "$(notes_problem "$T/blank.md")" == *"are empty" ]]'
check "template text fails" '[[ "$(notes_problem "$T/todo.md")" == *"template text (line 2:"* ]]'

# notary config, each in a clean environment
touch "$T/key.p8"
nc() { env -i HOME="$T/home" PATH="$PATH" LTM_NOTARY_CONFIG="$T/notary.env" "$@" bash -c \
    'source "$1"; notary_config || exit 1; echo "$NOTARY_FROM|${NOTARY[*]}|${LTM_SIGN_IDENTITY:-}"' _ "$SRC/scripts/ship"; }
mkdir -p "$T/home"
check "nothing configured is refused (no keychain profile)" '[[ "$(nc)" == "no App Store Connect API key"* ]]'
check "the environment's key" '[[ "$(nc LTM_NOTARY_KEY="$T/key.p8" LTM_NOTARY_KEY_ID=K LTM_NOTARY_ISSUER=I)" == "the environment|--key $T/key.p8 --key-id K --issuer I|" ]]'
check "a partial key is refused" '[[ "$(nc LTM_NOTARY_KEY_ID=K)" == *"go together"* ]]'
check "a missing .p8 is refused" '[[ "$(nc LTM_NOTARY_KEY="$T/none.p8" LTM_NOTARY_KEY_ID=K LTM_NOTARY_ISSUER=I)" == *"no readable file" ]]'
cp "$T/key.p8" "$T/home/key.p8"
printf 'export LTM_NOTARY_KEY="~/key.p8"\nLTM_NOTARY_KEY_ID=FILEKEY\n# a comment\nLTM_NOTARY_ISSUER='\''FILEISS'\''\nLTM_SIGN_IDENTITY=Developer ID Application: X (T)\n' > "$T/notary.env"
chmod 644 "$T/notary.env"
check "a config file others can read is refused" '[[ "$(nc)" == *"must be mode 600"* ]]'
chmod 600 "$T/notary.env"
check "the config file's key, quotes and ~ undone" '[[ "$(nc)" == "$T/notary.env|--key $T/home/key.p8 --key-id FILEKEY --issuer FILEISS|Developer ID Application: X (T)" ]]'
check "the environment wins over the file" '[[ "$(nc LTM_NOTARY_KEY_ID=ENVKEY)" == *"--key-id ENVKEY --issuer FILEISS"* ]]'
printf 'LTM_NOTARY_KEY=$HOME/key.p8\nLTM_NOTARY_KEY_ID=K\nLTM_NOTARY_ISSUER=I\n' > "$T/notary.env"
check "a config path from \$HOME" '[[ "$(nc)" == *"|--key $T/home/key.p8 --key-id K "* ]]'

# the Xcode pin
printf '{"xcode": {"build": "27A266a", "comment": "x"}, "q": {"build_dir": "b"}}\n' > "$T/sources.json"
check "the pinned Xcode passes" '[[ -z "$(xcode_problem "$T/sources.json" "$(printf "Xcode 27.0\nBuild version 27A266a")")" ]]'
check "another Xcode is refused, saying how to pin it" \
    '[[ "$(xcode_problem "$T/sources.json" "$(printf "Xcode 27.1\nBuild version 27B5")")" == "Xcode 27B5 is not the pinned 27A266a:"*"scripts/ship --pin-xcode"* ]]'
check "no Xcode is refused" '[[ "$(xcode_problem "$T/sources.json" "")" == "Xcode (none) is not the pinned 27A266a:"* ]]'
check "a sources.json without a pin is refused" '[[ "$(xcode_problem "$T/notes.md" "Build version 27A266a")" == *"pins no Xcode build" ]]'
mkdir -p "$T/xcode/bin" "$T/repo/scripts" "$T/repo/build-support"
printf '#!/bin/sh\nprintf "Xcode 27.9\\nBuild version 27Z9\\n"\n' > "$T/xcode/bin/xcodebuild"
chmod +x "$T/xcode/bin/xcodebuild"
check "ship refuses another Xcode before any work" \
    'out="$(PATH="$T/xcode/bin:$PATH" "$SRC/scripts/ship" --notes "$T/notes.md" 2>&1)"; [[ $? == 2 && "$out" == "FAIL preflight: Xcode 27Z9 is not the pinned "* ]]'
cp "$SRC/scripts/ship" "$T/repo/scripts/" && cp "$T/sources.json" "$T/repo/build-support/"
check "--pin-xcode records the selected Xcode's build and nothing else" \
    'PATH="$T/xcode/bin:$PATH" "$T/repo/scripts/ship" --pin-xcode >/dev/null && [[ "$(cat "$T/repo/build-support/sources.json")" == "{\"xcode\": {\"build\": \"27Z9\", \"comment\": \"x\"}, \"q\": {\"build_dir\": \"b\"}}" ]]'

# IPSWs
BUILT_IN=n72ap-7E18
mkdir -p "$T/ipsw/a/b" "$T/cache" "$T/srv"
printf 'right ipsw' > "$T/ipsw/a/b/real.ipsw"
printf 'wrong ipsw' > "$T/ipsw/a/decoy.ipsw"
SHA="$(shasum -a 1 "$T/ipsw/a/b/real.ipsw" | cut -d' ' -f1)"
check "a local copy with the SHA-1 is cloned in" 'LTM_IPSW_DIRS="$T/nowhere:$T/ipsw" fill_ipsw "$T/cache" x-1 "$SHA" 10 >/dev/null && cmp -s "$T/cache/$SHA.ipsw" "$T/ipsw/a/b/real.ipsw"'
check "one in the cache is left alone" '[[ "$(LTM_IPSW_DIRS=/none fill_ipsw "$T/cache" x-1 "$SHA" 10)" == "x-1: in the cache" ]]'
rm "$T/cache/$SHA.ipsw"
mv "$T/ipsw/a/b/real.ipsw" "$T/srv/real.ipsw"
check "a same-size copy with another SHA-1 is refused, and so is a bad download" \
    '! LTM_IPSW_DIRS="$T/ipsw" fill_ipsw "$T/cache" x-1 "$SHA" 10 "file://$T/ipsw/a/decoy.ipsw" >/dev/null && [[ -z "$(ls "$T/cache")" ]]'
check "a download with the SHA-1 is taken, after a dead URL" \
    'LTM_IPSW_DIRS="$T/ipsw" fill_ipsw "$T/cache" x-1 "$SHA" 10 "file://$T/none.ipsw" "file://$T/srv/real.ipsw" >/dev/null && cmp -s "$T/cache/$SHA.ipsw" "$T/srv/real.ipsw"'
rm "$T/cache/$SHA.ipsw"
check "LTM_BUILT_IN_IPSW counts for the built-in iPod" 'LTM_BUILT_IN_IPSW="$T/srv/real.ipsw" LTM_IPSW_DIRS=/none fill_ipsw "$T/cache" n72ap-7E18 "$SHA" 10 >/dev/null'
check "the catalog's line for the built-in iPod" \
    '"${HELPER[@]}" catalog "$SRC/LightTouchMac/Resources/firmware-catalog.json" n72ap-7E18 | grep -qE "^n72ap-7E18 [0-9a-f]{40} [0-9]+ https://"'

# pruning
mkdir -p "$T/rel"
for n in 1 2 3; do mkdir -p "$T/rel/release-$n.xcarchive" "$T/rel/release-$n-export"; touch -t 20260101000$n "$T/rel/release-$n.xcarchive"; done
check "a dry prune removes nothing" 'prune_releases "$T/rel" 2 1 | grep -q "remove $T/rel/release-1.xcarchive" && [[ -d "$T/rel/release-1-export" ]]'
check "a prune keeps the newest two" 'prune_releases "$T/rel" 2 0 >/dev/null && [[ ! -e "$T/rel/release-1.xcarchive" && ! -e "$T/rel/release-1-export" && -d "$T/rel/release-2.xcarchive" && -d "$T/rel/release-3.xcarchive" ]]'
# work directories, by the time in their names (the oldest touched last, as a strip would)
for n in 1 2 3; do
    w="$T/work/ship-abcdef01-2026010$n-120000"
    mkdir -p "$w/dd/Build" "$w/boot.xcresult" && touch "$w/ship.log" "$w/static.log" "$w/app.json" "$w/submit.zip"
done
touch "$T/work/ship-abcdef01-20260101-120000"
whole() { [[ -d "$1/dd" && -f "$1/submit.zip" ]]; }
stripped() { [[ "$(ls "$1")" == "$(printf 'app.json\nship.log\nstatic.log')" ]]; }
check "a dry work prune names the oldest and removes nothing" \
    '[[ "$(prune_work "$T/work" 2 1)" == "strip  $T/work/ship-abcdef01-20260101-120000 "*"(dry run: not removed)" ]] && whole "$T/work/ship-abcdef01-20260101-120000"'
check "a work prune keeps the newest whole and the rest's logs and JSON" \
    'prune_work "$T/work" 2 0 >/dev/null && stripped "$T/work/ship-abcdef01-20260101-120000" && whole "$T/work/ship-abcdef01-20260102-120000" && whole "$T/work/ship-abcdef01-20260103-120000"'
check "a stripped work directory isn't named again" '[[ -z "$(prune_work "$T/work" 2 0)" ]]'

# arguments, refused before any work (exit 2)
mkdir -p "$T/X.xcarchive"
# (no notary config of this Mac's: an argument let through would reach the export of an empty archive, exit 1)
refused() { out="$(LTM_NOTARY_CONFIG="${LTM_NOTARY_CONFIG:-/none}" "$@" 2>&1)"; [[ $? == 2 && "$out" == FAIL* ]]; }
check "ship needs --notes" 'refused "$SRC/scripts/ship"'
check "ship refuses empty notes" 'refused "$SRC/scripts/ship" --notes "$T/blank.md"'
check "ship refuses a missing archive" 'refused "$SRC/scripts/ship" --notes "$T/notes.md" --archive "$T/none.xcarchive"'
check "ship refuses a skipped prepare matrix outside a dry run" 'LTM_RELEASE_SKIP_PREPARE=1 refused "$SRC/scripts/ship" --notes "$T/notes.md"'
check "ship refuses a partial key" 'LTM_NOTARY_KEY_ID=K refused "$SRC/scripts/ship" --notes "$T/notes.md" --dry-run'
check "ship refuses no key" 'refused "$SRC/scripts/ship" --notes "$T/notes.md" --dry-run'
check "the deprecated release hands its archive and notes to ship" \
    '[[ "$("$SRC/scripts/release" "$T/X.xcarchive" --amore --notes "$T/todo.md" --publish 2>&1)" == *"running scripts/ship --archive $T/X.xcarchive --notes $T/todo.md"*"FAIL preflight: the notes at $T/todo.md still have template text"* ]]'
check "the Amore upload asks for no JSON (amore refuses --skip-notarization with it)" '! grep -E "amore release .*--draft" -A1 "$SRC/scripts/ship" | grep -q -- "--format json"'
check "the deprecated release still needs an archive" 'refused "$SRC/scripts/release" --amore'

# a run that fails prunes the work directories too (a dry run only names them): $T/repo, pushed, then changed
git init -q --bare "$T/repo-origin.git"
gq() { git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gq init -q -b main && gq add -A && gq commit -q -m ship && gq remote add origin "$T/repo-origin.git" && gq push -q origin main
touch "$T/repo/changed"
for n in 1 2 3; do w="$T/rel2/ship-abcdef01-2026010$n-120000"; mkdir -p "$w/dd" && touch "$w/ship.log" "$w/app.json"; done
failed_ship() {
    out="$(PATH="$T/xcode/bin:$PATH" LTM_RELEASE_DIR="$T/rel2" LTM_NOTARY_CONFIG=/none LTM_NOTARY_KEY="$T/key.p8" \
        LTM_NOTARY_KEY_ID=K LTM_NOTARY_ISSUER=I "$T/repo/scripts/ship" --notes "$T/notes.md" "$@" 2>&1)"
    [[ $? == 2 && "$(tail -1 <<<"$out")" == "FAIL preflight: the tree has changes (git status) "* ]]
}
check "a failed dry run names a work directory past the newest three and keeps it" \
    'failed_ship --dry-run && [[ "$out" == *"strip  $T/rel2/ship-abcdef01-20260101-120000 to its logs and JSON (dry run: not removed)"* && -d "$T/rel2/ship-abcdef01-20260101-120000/dd" ]]'
check "a failed run strips it, keeping its logs and JSON" \
    'failed_ship && [[ ! -e "$T/rel2/ship-abcdef01-20260101-120000/dd" && -f "$T/rel2/ship-abcdef01-20260101-120000/ship.log" && -f "$T/rel2/ship-abcdef01-20260101-120000/app.json" && -d "$T/rel2/ship-abcdef01-20260103-120000/dd" ]]'

# the Amore release's id: the upload's answer first, else this app's cached details
printf 'Uploading…\n{"release":{"bundleVersion":1601,"id":"AAAAAAAA-0000-0000-0000-000000000001","downloadURL":"https://cdn/x.dmg"}}\n' > "$T/upload.json"
printf '{"bundleIdentifier":"other.app","releases":[{"bundleVersion":1601,"id":"BAD","downloadURL":"https://cdn/bad.dmg"}]}' > "$T/other.json"
printf '{"bundleIdentifier":"gold.samhenri.LightTouchMac","releases":[{"bundleVersion":1600,"id":"OLD","downloadURL":"u"},{"bundleVersion":1601,"id":"CACHED","downloadURL":"https://cdn/c.dmg"}]}' > "$T/details.json"
check "the id from the upload's answer" '[[ "$("${HELPER[@]}" amore-id 1601 gold.samhenri.LightTouchMac "$T/upload.json" "$T/details.json")" == "AAAAAAAA-0000-0000-0000-000000000001 https://cdn/x.dmg" ]]'
check "else from this app's cache, not another app's" '[[ "$("${HELPER[@]}" amore-id 1601 gold.samhenri.LightTouchMac "$T/blank.md" "$T/other.json" "$T/details.json")" == "CACHED https://cdn/c.dmg" ]]'

# the appcast: notes as HTML and an edSignature made here
printf 'disk image' > "$T/cdn.dmg"
cat > "$T/sign.swift" << 'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
print(key.publicKey.rawRepresentation.base64EncodedString(), try! key.signature(for: data).base64EncodedString())
EOF
read -r PUB SIG < <(swift "$T/sign.swift" "$T/cdn.dmg")
appcast() {
    printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1601</sparkle:version><description>%s</description><enclosure url="https://cdn/x.dmg" sparkle:edSignature="%s" length="10"/></item></channel></rss>' "$1" "$SIG" > "$T/appcast.xml"
}
appcast '&lt;h2&gt;What’s new&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;Cover Flow shows album art.&lt;/li&gt;&lt;/ul&gt;'
check "an appcast item with the notes and a valid signature" '"${HELPER[@]}" appcast "$T/appcast.xml" 1601 "$PUB" "$T/cdn.dmg" "$T/notes.md" >/dev/null'
check "another build has no item" '! "${HELPER[@]}" appcast "$T/appcast.xml" 1602 "$PUB" "$T/cdn.dmg" "$T/notes.md" 2>/dev/null'
printf 'disk imagE' > "$T/tampered.dmg"
check "a DMG the signature isn't for fails" '! "${HELPER[@]}" appcast "$T/appcast.xml" 1601 "$PUB" "$T/tampered.dmg" "$T/notes.md" 2>/dev/null'
appcast ''
check "an empty description fails" '! "${HELPER[@]}" appcast "$T/appcast.xml" 1601 "$PUB" "$T/cdn.dmg" "$T/notes.md" 2>/dev/null'
exit $failed
