#!/bin/bash
# Exercise both agents' shared lifecycle worker without touching real scratch, vendor builds or processes.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/agent-cleanup-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
R="$T/LightTouchMac"
mkdir -p "$R/scripts" "$T/scratch" "$T/managed/LightTouchMac"
cp "$SRC/scripts/agent-cleanup" "$R/scripts/"
cat > "$R/scripts/clean" <<'CLEAN'
#!/bin/bash
printf '%s\n' "$*" >> "$LTM_SCRATCH_ROOT/calls"
if [[ "${HOLD_SWEEP:-}" == 1 ]]; then touch "$LTM_SCRATCH_ROOT/started"; sleep 1; fi
CLEAN
chmod +x "$R/scripts/clean"
git init -q "$R"
git -C "$R" add .
git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -C "$R" commit -qm fixture
git -C "$R" worktree add -q --detach "$T/managed/LightTouchMac/task"
export LTM_SCRATCH_ROOT="$T/scratch" LTM_WORKTREE_ROOT="$T/managed" LTM_AGENT_CLEANUP_SYNC=1
rm "$T/managed/LightTouchMac/task/scripts/clean"
hook() { printf '{"cwd":"%s","reason":"%s"}\n' "$1" "${3:-other}" | "$(git -C "$1" rev-parse --show-toplevel)/scripts/agent-cleanup" "$2"; }
fail() { echo "FAIL: $*"; exit 1; }
hook "$R" stop
hook "$R" stop
[[ "$(wc -l < "$T/scratch/calls" | tr -d ' ')" == 1 ]] || fail 'repeated turns repeated the sweep'
grep -qx -- '--quick --yes' "$T/scratch/calls" || fail 'Stop ran something other than quick cleanup'
hook "$R" end
! grep -q -- --worktree "$T/scratch/calls" || fail 'main checkout retired'
W="$T/managed/LightTouchMac/task"
hook "$W" end
# The main checkout's worker and cleaner run even when the retiring checkout has no copies of them.
grep -qx -- "--worktree $W --yes --no-size" "$T/scratch/calls" || fail 'Codex other reason did not retire managed worktree'
: > "$T/scratch/calls"
hook "$W" end clear
[[ ! -s "$T/scratch/calls" ]] || fail 'Claude clear retired worktree'
hook "$W" end prompt_input_exit
grep -q -- --worktree "$T/scratch/calls" || fail 'Claude exit did not retire managed worktree'
# Concurrent Stop is nonblocking and skips a redundant sweep; end requests must still be queued.
rm "$T/scratch/.agent-cleanup/last"
: > "$T/scratch/calls"
HOLD_SWEEP=1 hook "$R" stop &
first=$!
for _ in $(seq 100); do [[ -f "$T/scratch/started" ]] && break; sleep 0.02; done
[[ -f "$T/scratch/started" ]] || fail 'first sweep never started'
hook "$R" stop
hook "$W" end &
second=$!
wait "$first" "$second"
[[ "$(grep -c -- '--quick --yes' "$T/scratch/calls")" == 1 ]] || fail 'overlapping Stop duplicated the sweep'
grep -q -- --worktree "$T/scratch/calls" || fail 'busy worker dropped terminal cleanup'
# A subsequent sweep trims a large old log, avoiding a new persistent source of disk growth.
dd if=/dev/zero of="$T/scratch/.agent-cleanup/cleanup.log" bs=1024 count=1100 2>/dev/null
hook "$R" stop
[[ $(stat -f %z "$T/scratch/.agent-cleanup/cleanup.log") -lt 524288 ]] || fail 'hook log grew without bound'
echo 'ok   lifecycle cleanup is throttled, serialized, bounded and retires only managed terminal sessions'
