#!/bin/bash
# scripts/clean's keep/remove decisions on a made-up Mac: two repositories with origins, managed worktrees in every
# state, scratch, DerivedData and vendor directories. Prints ok/FAIL per check; exits 1 on any FAIL.
#     tests/scripts/clean.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-clean-test.XXXXXX")"
HOLDER=""
trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
old() { find "$@" -exec touch -h -t 202001010000 {} +; }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# qemu-ios, with an origin, a landed managed worktree and the pinned checkout
git init -q --bare "$T/qemu-origin.git"
g clone -q "$T/qemu-origin.git" "$T/qemu" 2>/dev/null
g -C "$T/qemu" commit -q --allow-empty -m one && g -C "$T/qemu" push -q origin HEAD:main
g -C "$T/qemu" worktree add -q --detach "$T/qemu/.claude/worktrees/q-landed"

# this repository: scripts and the pins, pushed
git init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/LightTouchMac" 2>/dev/null
R="$T/LightTouchMac"
mkdir -p "$R/scripts" "$R/build-support" "$R/LightTouchMac.xcodeproj" && touch "$R/LightTouchMac.xcodeproj/project.pbxproj"
cp "$SRC/scripts/clean" "$SRC/scripts/vendor-check" "$R/scripts/"
printf '{"qemu-ios": {"path": "%s"}}\n' "$T/qemu" > "$R/build-support/sources.json"
printf '.claude/\nbuild/\n' > "$R/.gitignore"
g -C "$R" add -A && g -C "$R" commit -q -m pins && g -C "$R" push -q origin HEAD:main
W="$R/.claude/worktrees"
for name in landed dirty unpushed fresh locked; do g -C "$R" worktree add -q -b "$name" "$W/$name"; done
g -C "$R" worktree add -q -b outside "$T/elsewhere"
echo change >> "$W/dirty/.gitignore"
g -C "$W/unpushed" commit -q --allow-empty -m mine
g -C "$R" worktree lock "$W/locked"
for name in landed dirty unpushed locked; do old "$(git -C "$W/$name" rev-parse --absolute-git-dir)"; done
old "$(git -C "$T/elsewhere" rev-parse --absolute-git-dir)" "$(git -C "$T/qemu/.claude/worktrees/q-landed" rev-parse --absolute-git-dir)"

# vendor directories: the pins', one a kept worktree's build/vendor names, the newest, one held open, one stale
V="$T/vendor"
key="$("$R/scripts/vendor-check" --key "$R")"
for name in "$key" aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc dddddddddddd; do
    mkdir -p "$V/$name" && echo '{}' > "$V/$name/vendor.json"
done
# Several vendor packages can refer to one shared native build. Only unreferenced, old caches retire.
N="$V/native"
for name in 111111111111 222222222222 333333333333; do mkdir -p "$N/$name"; done
mkdir -p "$V/$key/work"
ln -s "$N/111111111111" "$V/$key/work/native-cache"
old "$N"
touch "$N/333333333333"
old "$V"
touch "$N/333333333333"
touch "$V/bbbbbbbbbbbb/vendor.json"
mkdir -p "$W/dirty/build" && ln -s "$V/aaaaaaaaaaaa" "$W/dirty/build/vendor"
(cd "$V/cccccccccccc" && exec sleep 60) &
HOLDER=$!; disown "$HOLDER"

# scratch: old, fresh, and one owned by the landed worktree; DerivedData of the landed worktree and of a kept one
S="$T/scratch"
mkdir -p "$S/old-task" "$S/new-task" "$S/owned-task"
touch "$S/old-task/f" "$S/new-task/f" "$S/owned-task/f"
echo "$W/landed" > "$S/owned-task/.worktree"
old "$S/old-task"
D="$T/DerivedData"
for name in landed dirty; do
    mkdir -p "$D/LightTouchMac-$name"
    plutil -create xml1 "$D/LightTouchMac-$name/info.plist"
    plutil -insert WorkspacePath -string "$W/$name/LightTouchMac.xcodeproj" "$D/LightTouchMac-$name/info.plist"
done

# Tool reuse touches the key directory even when every payload is old. Interrupted stages age out too.
C="$S/.sessions-tools"
for name in 11111111111111111111 22222222222222222222 33333333333333333333.partial-ABCDEF12 unrelated; do
    mkdir -p "$C/$name" && touch "$C/$name/payload"
done
old "$C"
touch "$C/22222222222222222222"
mkdir -p "$C/44444444444444444444" && old "$C/44444444444444444444"
# Keep one old tool in use with a process we own; lsof must protect it.
(cd "$C/44444444444444444444" && exec sleep 120) &
CACHE_HOLDER=$!; disown "$CACHE_HOLDER"
trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; kill "$CACHE_HOLDER" 2>/dev/null; rm -rf "$T"' EXIT

export LTM_VENDOR_ROOT="$V" LTM_SCRATCH_ROOT="$S" LTM_WORKTREE_ROOT="$T/managed" LTM_DERIVED_DATA="$D"
out="$("$R/scripts/clean")"
has() { grep -q "^$1 .* $2  (" <<<"$out"; }
check "a landed, clean, idle worktree is removed" 'has remove "$W/landed"'
check "a landed qemu-ios worktree is removed" 'has remove "$T/qemu/.claude/worktrees/q-landed"'
check "uncommitted changes keep a worktree" 'has keep "$W/dirty"'
check "unpushed commits keep a worktree" 'has keep "$W/unpushed"'
check "recent use keeps a worktree" 'has keep "$W/fresh"'
check "a lock keeps a worktree" 'has keep "$W/locked"'
check "a worktree outside the managed paths is kept" 'has keep "$T/elsewhere"'
check "the current pins' vendor directory is kept" 'has keep "$V/$key"'
check "a vendor directory a kept checkout names is kept" 'has keep "$V/aaaaaaaaaaaa"'
check "the newest vendor directory is kept" 'has keep "$V/bbbbbbbbbbbb"'
check "a vendor directory open in a process is kept" 'has keep "$V/cccccccccccc"'
check "a stale vendor directory is removed" 'has remove "$V/dddddddddddd"'
check "a shared native build referenced by retained vendor stays" 'has keep "$N/111111111111"'
check "an unreferenced old native build retires" 'has remove "$N/222222222222"'
check "a recent shared native build stays for reuse" 'has keep "$N/333333333333"'
check "old scratch is removed" 'has remove "$S/old-task"'
check "fresh scratch is kept" 'has keep "$S/new-task"'
check "scratch of a removed worktree is removed" 'has remove "$S/owned-task"'
check "DerivedData of a removed worktree is removed" 'has remove "$D/LightTouchMac-landed"'
check "DerivedData of a kept worktree is not listed" '! grep -q "LightTouchMac-dirty" <<<"$out"'
check "unused shared tools are removed" 'has remove "$C/11111111111111111111"'
check "recently reused tools are kept even with old payloads" 'has keep "$C/22222222222222222222"'
check "interrupted tool staging is removed when old" 'has remove "$C/33333333333333333333.partial-ABCDEF12"'
check "tools open in a process are kept" 'has keep "$C/44444444444444444444"'
check "unknown files in the tools root are left alone" '! has remove "$C/unrelated"'
check "a dry run removes nothing" '[[ -d "$W/landed" && -d "$V/dddddddddddd" && -d "$S/old-task" ]]'
check "--worktree refuses a dirty one" '! "$R/scripts/clean" --worktree "$W/dirty" --yes >/dev/null && [[ -d "$W/dirty" ]]'

"$R/scripts/clean" --yes >/dev/null
check "--yes removes the landed worktree and its branch" '[[ ! -d "$W/landed" ]] && ! git -C "$R" rev-parse -q --verify landed >/dev/null'
check "--yes keeps the dirty and unpushed worktrees" '[[ -f "$W/dirty/.gitignore" && -d "$W/unpushed" ]]'
check "--yes removes the stale vendor directory and keeps the rest" '[[ ! -d "$V/dddddddddddd" && -d "$V/$key" && -d "$V/aaaaaaaaaaaa" && -d "$V/cccccccccccc" ]]'
check "--yes removes the old and owned scratch and DerivedData" '[[ ! -d "$S/old-task" && ! -d "$S/owned-task" && -d "$S/new-task" && ! -d "$D/LightTouchMac-landed" ]]'
check "--yes prunes only unreferenced stale native builds" '[[ -d "$N/111111111111" && ! -d "$N/222222222222" && -d "$N/333333333333" ]]'
check "--yes prunes only old unused session tools" '[[ ! -d "$C/11111111111111111111" && ! -d "$C/33333333333333333333.partial-ABCDEF12" && -d "$C/22222222222222222222" && -d "$C/44444444444444444444" && -d "$C/unrelated" ]]'
# Fast cleanup does not size trees, hash vendor pins, or inspect worktrees/DerivedData.
mkdir -p "$T/bin" "$S/finished" "$S/another-task"
printf '#!/bin/sh\necho unexpected-du >&2\nexit 99\n' > "$T/bin/du"
chmod +x "$T/bin/du"
out="$(PATH="$T/bin:$PATH" "$R/scripts/clean" --task finished 2>&1)"
check "task cleanup previews only its named task" 'has remove "$S/finished" && ! has remove "$S/another-task" && [[ -d "$S/finished" ]]'
check "task cleanup skips sizing and other inventories" '! grep -qE "unexpected-du|== worktrees|== vendor|== DerivedData|== shared" <<<"$out"'
PATH="$T/bin:$PATH" "$R/scripts/clean" --task finished --yes >/dev/null
check "task cleanup removes recent owned work without touching another task" '[[ ! -d "$S/finished" && -d "$S/another-task" ]]'
ln -s "$S/another-task" "$S/linked-task"
check "task cleanup refuses symlinks and traversal" '! "$R/scripts/clean" --task linked-task --yes >/dev/null 2>&1 && ! "$R/scripts/clean" --task ../another-task --yes >/dev/null 2>&1 && [[ -d "$S/another-task" ]]'
out="$(PATH="$T/bin:$PATH" "$R/scripts/clean" --quick 2>&1)"
check "quick cleanup sweeps scratch and session tools without sizing" 'grep -q "== shared session tools" <<<"$out" && ! grep -qE "unexpected-du|== worktrees|== vendor|== DerivedData" <<<"$out"'
mkdir -p "$S/open-task"
(cd "$S/open-task" && exec sleep 120) &
TASK_HOLDER=$!; disown "$TASK_HOLDER"
trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; kill "$CACHE_HOLDER" "$TASK_HOLDER" 2>/dev/null; chflags -R -P nouchg "$T" 2>/dev/null; chmod -R u+w "$T"; rm -rf "$T"' EXIT
out="$("$R/scripts/clean" --task open-task --yes)"
check "task cleanup keeps an open directory" 'has keep "$S/open-task" && [[ -d "$S/open-task" ]]'
g -C "$R" worktree add -q -b refused "$W/refused"
mkdir -p "$S/refused-task"
echo "$W/refused" > "$S/refused-task/.worktree"
cat > "$T/bin/git" <<'GIT'
#!/bin/bash
[[ " $* " != *' worktree remove '* ]] || exit 1
exec /usr/bin/git "$@"
GIT
chmod +x "$T/bin/git"
check "a failed worktree removal preserves its owned scratch" '! PATH="$T/bin:$PATH" "$R/scripts/clean" --worktree "$W/refused" --yes --no-size >/dev/null 2>&1 && [[ -d "$S/refused-task" && -d "$W/refused" ]]'
# Preparation publishes immutable, read-only directories. Cleanup must unlock only the selected task's tree.
mkdir -p "$S/locked-task/base/nand" "$T/protected"
touch "$S/locked-task/base/nand/image"
ln -s "$T/protected" "$S/locked-task/elsewhere"
chmod 555 "$S/locked-task/base/nand" "$S/locked-task/base"
chflags uchg "$S/locked-task/base/nand" "$S/locked-task/base" "$T/protected"
out="$("$R/scripts/clean" --task locked-task --yes)"
check "cleanup removes immutable prepared bases" '[[ ! -d "$S/locked-task" ]]'
check "unlocking a task never follows its symlinks" '(( $(stat -f %f "$T/protected") & 2 ))'
chflags nouchg "$T/protected"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/lsof"
chmod +x "$T/bin/lsof"
check "failed process inventory prevents deletion" '! PATH="$T/bin:$PATH" "$R/scripts/clean" --task another-task --yes >/dev/null 2>&1 && [[ -d "$S/another-task" ]]'
check "missing and invalid age arguments are refused" '! "$R/scripts/clean" --days 0 >/dev/null 2>&1 && ! "$R/scripts/clean" --days >/dev/null 2>&1'
exit $failed
