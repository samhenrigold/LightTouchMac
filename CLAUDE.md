# Working in Light Touch

For coding agents. The build, the gates, the layout and the style are in [CONTRIBUTING.md](CONTRIBUTING.md); this is
what to do and not do on a shared Mac.

## Files and processes

- Scratch goes under one root: `~/Developer/ltm-scratch.noindex/<task>/`. Never `/tmp/<name>`. Delete your task's
  directory when you are done; `scripts/clean` (a dry run; `--yes` acts) sweeps what is left.
- Worktrees live under `~/Developer/ltm-worktrees.noindex/<repository>/<name>` (the hooks in `.claude/settings.json`
  make them there, with the scratch directory `~/Developer/ltm-scratch.noindex/<name>/`); put a qemu-ios worktree
  you need beside them. When the session ends, a worktree that is clean with every commit on a remote is removed with
  what it owns; to drop unpushed work, `touch ~/Developer/ltm-scratch.noindex/<name>/.abandoned` (the branch stays).
- Never modify a shared base, vendor directory or another checkout in place. Copy it into your scratch directory (or
  boot it with an overlay) and work on the copy.
- Kill by PID only: the PID you started, or one read from a pid file. No `pkill`, `killall` or `pgrep -f` patterns;
  they hit other agents' emulators (and a `pgrep -f` wait loop matches its own shell).
- Never `git stash`: the stash is shared by every worktree. Commit work in progress on your branch instead.
- Never push; the lead lands changes.
- Emulators are silent: every headless boot passes `-audio driver=none`.
- Never launch, quit or UI-script Light Touch.app, Xcode previews or on-screen test windows. Everything you run is
  headless.

## Building and testing

- First build, and after a pin bump: `scripts/vendor` (`--check` only checks). Xcode fails with one line when the
  vendor directory or the machine options it writes are missing or stale; run what it says.
- Before `sessions`: `swift build --package-path tests/sessions`, then `swift run --package-path tests/sessions
  sessions …`.
- The device helper is sandboxed in every build (`LTM_HELPER_SANDBOX`, CONTRIBUTING.md, Building); `sessions` and
  `firmwarekit` from a Terminal without Full Disk Access make macOS ask once for the app group's container.
  `LTM_HELPER_SANDBOX=NO` builds it unsandboxed for debugging.
- Unit tests: `xcodebuild test -project LightTouchMac.xcodeproj -scheme LightTouchMac -testPlan Unit -skipMacroValidation`, or
  `swift test --package-path Packages/<Package>` for one package. Tests live in `Packages/*/Tests`, `tests/offline`
  and `tests/sessions` (CONTRIBUTING.md, Gates); the scripts' shell tests in `tests/scripts`.
- `sessions` and `scripts/ship` end with one line, `PASS <summary> <log>` or
  `FAIL <first failure> <log>`; exit 0 pass, 1 fail, 2 refused or stale input, 3 infrastructure. Read that line, not
  the logs.
- Before booting emulators, `scripts/host-ready` prints `READY …` (exit 0) or `WAIT <why>` (exit 1: load, all three
  emulator slots taken, or disk); `sessions` holds a slot for its run and waits for one when none is free.
- Check a change with the fast tiers, not every device: `sessions affected main` prints what it needs (the Unit plan,
  and which board families boot, one row each) and `--run` runs it through `sessions matrix`. Boot every catalog row
  (jailbroken rows with `--network`) only before a release or for a change to the boot path, the emulator or its pin.
- A preparation change (FirmwareKit's recipes and volumes) runs `sessions listings` first: about two minutes, no
  emulator. Never re-record (`--record`) to make it pass without saying in the commit why each changed path changed.
- A new test must fail with the fix reverted; say so in the commit.
- The pre-commit hook formats staged Swift and C (`scripts/format --staged`; `scripts/vendor` turns it on). When
  it refuses a partly staged file, run the command it prints. `scripts/format --check` (run by the Unit plan) fails on
  an unformatted file or any swift-format lint finding: change the code, don't disable the rule.

## Commits

- Repository style: one long message saying what changed and why, ending with `Checked:` and the evidence (test
  names, pass counts, what failed with the fix reverted).
- American spelling (license, behavior, color), but Apple's cancelled and cancellable.
- The product is "Light Touch", two words, wherever a person reads it; `LightTouch` only in identifiers.
