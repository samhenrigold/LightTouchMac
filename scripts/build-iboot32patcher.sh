#!/bin/bash
# Build iBoot32Patcher (arm64, macOS 14) from the pinned archive in build-support/dependencies.json's
# "tools" group, which dependency-sources.py fetched into SRC-DIR, with build-support/patches/
# iBoot32Patcher-ltm.patch applied (aligned xrefs and ABI-checked RSA bypass; smoke #48/#50).
# OUT-DIR ends up with the binary, the upstream LICENSE (GPL-3.0), the patch, SOURCE.txt and build.json
# (commit, license, sha256s). LTM_ARCH (default arm64) names the slices, e.g. "arm64 x86_64" for the
# universal app (build-release.py --universal). Called by
# build-package-native.sh and build-release.py --stage native; package.sh ships OUT-DIR's LICENSE, patch and SOURCE.txt.
#
#     build-iboot32patcher.sh SRC-DIR OUT-DIR
set -euo pipefail
SRC_DIR="${1:?usage: build-iboot32patcher.sh src-dir out-dir}"
OUT="${2:?usage: build-iboot32patcher.sh src-dir out-dir}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ARCH_FLAGS=""
for arch in ${LTM_ARCH:-arm64}; do ARCH_FLAGS="$ARCH_FLAGS-arch $arch "; done
read -r ARCHIVE COMMIT LICENSE URL < <(python3 - "$HERE/build-support/dependencies.json" <<'PY'
import json, sys
p = next(p for p in json.load(open(sys.argv[1]))['packages'] if p['name'] == 'iBoot32Patcher')
print(p['archive'], p['version'], p['license'], p['url'])
PY
)
[ -f "$SRC_DIR/$ARCHIVE" ] || { echo "missing $SRC_DIR/$ARCHIVE; run dependency-sources.py fetch --group tools" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$SRC_DIR/$ARCHIVE" -C "$OUT" --strip-components=1
PATCH="$HERE/build-support/patches/iBoot32Patcher-ltm.patch"
(cd "$OUT" && patch -p1 --quiet < "$PATCH")
cp "$PATCH" "$OUT/"
(cd "$OUT" && make CC=/usr/bin/clang CFLAGS="-O2 $ARCH_FLAGS-mmacosx-version-min=14.0 -Wno-multichar -Wno-int-conversion" > "$OUT/make.log" 2>&1)
python3 "$HERE/scripts/check-macho.py" --no-weak-imports --minos 14.0 "$OUT/iBoot32Patcher"
printf '%s\n' "iBoot32Patcher $COMMIT: $URL" "License: $LICENSE (LICENSE alongside)" \
    "Modified: $(basename "$PATCH") (alongside) applied to that source." \
    "Built by scripts/build-iboot32patcher.sh: make CC=clang CFLAGS='-O2 $ARCH_FLAGS-mmacosx-version-min=14.0'" \
    "firmwarekit runs it as a separate process for the iPad's real-iBoot boot chain (--rsa --debug -b boot-args)." \
    > "$OUT/SOURCE.txt"
python3 - "$OUT" "$COMMIT" "$LICENSE" "$SRC_DIR/$ARCHIVE" "$PATCH" <<'PY'
import hashlib, json, pathlib, sys
out, commit, license, archive, patch = sys.argv[1:]
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
pathlib.Path(out, 'build.json').write_text(json.dumps({
    'commit': commit, 'license': license, 'archive_sha256': sha(archive), 'patch_sha256': sha(patch),
    'binary': str(pathlib.Path(out, 'iBoot32Patcher')), 'sha256': sha(pathlib.Path(out, 'iBoot32Patcher')),
}, indent=2, sort_keys=True) + '\n')
PY
echo "built $OUT/iBoot32Patcher ($COMMIT, $LICENSE)"
