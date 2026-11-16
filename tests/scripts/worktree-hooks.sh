#!/bin/bash
# .claude/hooks/worktree on a made-up repository with an origin: create makes a managed worktree and its scratch;
# remove and session-end take only what is safe. Prints ok/FAIL per check; exits 1 on any FAIL.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-hooks-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
json() { perl -MJSON::PP -e 'my %h = @ARGV; print encode_json(\%h)' "$@"; }

git init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/LightTouchMac" 2>/dev/null
R="$T/LightTouchMac"
mkdir -p "$R/scripts" "$R/.claude/hooks" "$R/build-support"
cp "$SRC/scripts/clean" "$SRC/scripts/vendor-check" "$R/scripts/"
cp "$SRC/.claude/hooks/worktree" "$R/.claude/hooks/"
echo '{}' > "$R/build-support/sources.json"
g -C "$R" add -A && g -C "$R" commit -q -m one && g -C "$R" push -q origin HEAD:main
export LTM_WORKTREE_ROOT="$T/managed" LTM_SCRATCH_ROOT="$T/scratch" LTM_DERIVED_DATA="$T/dd" LTM_VENDOR_ROOT="$T/vendor"
HOOK="$R/.claude/hooks/worktree"
create() { json name "$1" cwd "$R" hook_event_name WorktreeCreate | "$HOOK" create 2>/dev/null | tail -1; }
gone() { for _ in $(seq 50); do [[ -e "$1" ]] || return 0; sleep 0.2; done; return 1; }
stays() { sleep 2; [[ -d "$1" ]]; }

a="$(create landed)"
check "create prints the managed path" '[[ "$a" == "$T/managed/LightTouchMac/landed" && -d "$a" ]]'
check "create branches worktree-<name>" '[[ "$(git -C "$a" branch --show-current)" == worktree-landed ]]'
check "create records the scratch it owns" '[[ "$(cat "$T/scratch/landed/.worktree")" == "$a" ]]'
check "create refuses a bad name" '[[ -z "$(create "../x")" ]]'
json worktree_path "$a" | "$HOOK" remove
check "remove takes a clean, landed worktree and its scratch" 'gone "$a" && gone "$T/scratch/landed"'

b="$(create unpushed)"
g -C "$b" commit -q --allow-empty -m mine
json worktree_path "$b" | "$HOOK" remove
check "remove leaves one with commits on no remote" 'stays "$b"'
touch "$T/scratch/unpushed/.abandoned"
json worktree_path "$b" | "$HOOK" remove
check "remove takes an abandoned one and keeps its branch" 'gone "$b" && git -C "$R" rev-parse -q --verify worktree-unpushed >/dev/null'

c="$(create dirty)"
echo x > "$c/new-file"
json worktree_path "$c" | "$HOOK" remove
check "remove leaves one with an untracked file" 'stays "$c" && [[ -f "$c/new-file" ]]'

d="$(create ended)"
json reason clear cwd "$d" | "$HOOK" session-end
check "session-end leaves it for a reason not on the list" 'stays "$d"'
json reason prompt_input_exit cwd "$d" | (cd "$d" && .claude/hooks/worktree session-end)
check "session-end takes it on exit" 'gone "$d"'
exit $failed
