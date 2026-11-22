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
old "$V"
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
# old work Finder has since shown (a fresh .DS_Store, and so a fresh directory, at each level), and an old directory
# holding a kept worktree's markers
mkdir -p "$S/finder-task/sub" "$S/kept-owner" && touch "$S/finder-task/sub/f"
echo "$W/unpushed" > "$S/kept-owner/.worktree" && touch "$S/kept-owner/.abandoned"
old "$S/finder-task" "$S/kept-owner"
touch "$S/finder-task/.DS_Store" "$S/finder-task/sub/.DS_Store"
mkdir "$S/empty-task"
D="$T/DerivedData"
for name in landed dirty; do
    mkdir -p "$D/LightTouchMac-$name"
    plutil -create xml1 "$D/LightTouchMac-$name/info.plist"
    plutil -insert WorkspacePath -string "$W/$name/LightTouchMac.xcodeproj" "$D/LightTouchMac-$name/info.plist"
done

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
check "old scratch is removed" 'has remove "$S/old-task"'
check "fresh scratch is kept" 'has keep "$S/new-task"'
check "scratch of a removed worktree is removed" 'has remove "$S/owned-task"'
check "old scratch Finder has written .DS_Store into is removed" 'has remove "$S/finder-task"'
check "a new empty scratch directory is kept" 'has keep "$S/empty-task"'
check "old scratch of a kept worktree is kept, with its markers" 'has keep "$S/kept-owner"'
check "DerivedData of a removed worktree is removed" 'has remove "$D/LightTouchMac-landed"'
check "DerivedData of a kept worktree is not listed" '! grep -q "LightTouchMac-dirty" <<<"$out"'
check "a dry run removes nothing" '[[ -d "$W/landed" && -d "$V/dddddddddddd" && -d "$S/old-task" ]]'
check "--worktree refuses a dirty one" '! "$R/scripts/clean" --worktree "$W/dirty" --yes >/dev/null && [[ -d "$W/dirty" ]]'

"$R/scripts/clean" --yes >/dev/null
check "--yes removes the landed worktree and its branch" '[[ ! -d "$W/landed" ]] && ! git -C "$R" rev-parse -q --verify landed >/dev/null'
check "--yes keeps the dirty and unpushed worktrees" '[[ -f "$W/dirty/.gitignore" && -d "$W/unpushed" ]]'
check "--yes removes the stale vendor directory and keeps the rest" '[[ ! -d "$V/dddddddddddd" && -d "$V/$key" && -d "$V/aaaaaaaaaaaa" && -d "$V/cccccccccccc" ]]'
check "--yes removes the old and owned scratch and DerivedData" '[[ ! -d "$S/old-task" && ! -d "$S/owned-task" && -d "$S/new-task" && ! -d "$D/LightTouchMac-landed" ]]'
exit $failed
