# Test audit, 2026-09-29

Sam's question: are the tests checking useful things (graphics, activation, guest services, performance,
compatibility, fidelity), and do they fail on real regressions, or are they skin-deep so that passing is
happenstance?

Adversarial audit, 2026-09-29, of qemu-ios `ipad1` 5d5b70d6c7 (the pin) and LightTouchMac `multidevice`
f425da5. The work was done in worktrees:
- qemu-ios `audit` (5d5b70d6c7 + the test repair), build `audit/build`;
- LightTouchMac `audit-docs` (this file only).

Scratch is `~/Developer/audit-0929/`: the devices I prepared, mutant builds (`mut-*`), matrix results
(`results-*`, `matrix-*.log`), regress runs (`r-*`, `ri-*`) and pixel diffs (`pd-*`). Every boot used
`-audio driver=none`, one emulator at a time. Host load was 13-220 on 16 cores through the whole audit (other
agents); section 4 says where that matters.

## Top findings

1. **Graphics is judged by liveness, not by the picture, on every boot leg.**
   - *Upside down passes.* A mutant that writes 2.x/1.x frames back upside down passes the 2.x (5F138) and 1.x
     (1G) `boot,gles` legs and the whole unit gate (85/85). `pd-5F138-flip-home.png` is an upside-down home
     screen that PASSes.
   - *Red/blue swap passes.* A mutant that swaps red and blue in every BGRA surface passes the iPad
     `gles,shadow` legs on 4.2.1. The unit test `test_gles_surface` does catch that one.
   - *What is actually asserted.* The iPad gles leg asserts only "nothing refused, no magenta". The 2.x/1.x leg
     asserts lit-pixel counts. No leg compares a frame with a reference.
2. **The matrix has no graphics column.** `gl` is hard-coded "skipped: qemu-ios gl-coverage not merged"
   (tests/sessions/matrix.py:233). gl-coverage has merged.
   - Every catalog flip to experimental today went through with no GL verdict.
   - On 4.3.5 (8L1) the guest runs software CoreAnimation: `glishim ... no gldshim device (GLRendererFloatQEMU.bundle
     missing?): no GL`, 415 times per boot. Nothing flags it.
3. **Boot 1's screen is black on 4.x iPad rows, and the matrix passes them.**
   - *My runs.* Across all 6 of my 4.x iPad rows (8L1 ×5, 8C148 ×1), every boot-1 screenshot (lock, home,
     installed) has brightness 0. It happens 12 s after `lit`.
   - *Today's recorded evidence.* The same holds for 8C148, 8F190, 8J3, 8K2 and 8L1: one byte-identical 10453-byte
     black PNG.
   - *Why it passes.* `lit` is a threshold crossed once, and the home screen is never judged. The unlock drag of
     boot 1 lands on a dark panel.
4. **Boot 2 is not judged, and 8L1's boot 2 power-off fails intermittently.** It went unconfirmed in 50 s in
   the recorded row and in my cold tip run. It passed in 2 of my runs whose mutation doesn't touch shutdown: 15.3
   s and 16.1 s. So it fails in 2 of the 4 runs I know of.
   - *Serial on the failures.* SpringBoard sits in the glishim `no gldshim device` retry loop, then
     `lcdEnable 0`, and never reaches `reboot(RB_HALT)`.
   - *Wrongly logged.* smoke #42(c) calls this an unreproduced one-off. It reproduces.
   - *Looks like the bug it replaced.* On the matrix's evidence, a failing boot 2 is indistinguishable from the
     reverted #27 (RGBOUT) fix.
5. **5F138 (2.1.1, `experimental`) fails the matrix cold at the pin.**
   - *The row.* `install: FAIL` (six retries, "The device stopped responding during install"). Persist and
     shutdown were never reached.
   - *Why.* The catalog turned AppSync on for 2.x (4add406) after the matrix row that justified the flip. That row
     had AppSync off, so the install column was "skip".
   - *What was actually run.* The flip itself was committed while its JSON row still said shutdown FAIL. Its GL
     cell is a hand-written note.
6. **Most of today's emulator fixes have no host test, and several have no automated check at all.**
   - *No host test.* Of 18 fix commits, only the iBoot epoch fix is caught by a unit test. So is the
     surfaces-by-pages fix, by the mutant I wrote for it (a whole-commit revert conflicts). No file under tests/
     touches H2FMI, the D1815/I2C PMU, CDMA, the IOP, the 1G ADM/FMC, the iPad display (RGBOUT), DART or the MBX.
   - *Caught by a boot.* Boot-backed mutation found these fixes covered: FMI gate, ADC mux 6, RGBOUT, I2S,
     CDMA AES, 1G LCD generation.
   - *Nothing fails.* These pass every automated check with the fix reverted:
     - 1G ADM 0x400/0x600;
     - D1815 restart;
     - H2FMI write-wait/O(1);
     - CDMA channel status and CDMA drain race (the race is probabilistic; one run);
     - the LCD generation fix on the 2G;
     - the iBoot-chain fixes for 5.x and SEPO 2. 8K2 and 8L1 run on `boot: kboot`, so no matrix row runs the
       real iBoot on 1072/1219.
7. **Frame-rate and CPU numbers have no committed harness, and no check gates on them.** The 2.x, 1.x and
   app-close tables were measured by scripts that aren't in either repo.
8. **Fidelity: none of the five R closures I checked cites a hardware contract.**
   - *Inferred.* Four rest on inference from the driver: I2S bit 1, FMI transfer rule, ADC 0 V, RGBOUT timing.
   - *Wrong class.* One contradicts the ledger: CDMA AES is ledger #34 **H**, and the fix removed AES on writes.
   - *Misfiled.* #27 is closed while its component stays S.
9. **The quick gate hid 12 real tests.** All 12 KNOWN entries tested live code; every break was a stale mock,
   slice bound or stub, and 5 of the 12 KNOWN reasons were wrong. They are repaired, KNOWN is empty, and the gate
   is 85/0/26 skip.
   - *Proof they bite.* Each repaired test fails on a one-line mutation of its model.
   - *Now covered.* One repair (test_dsi_fifo) now covers today's K48 panel-ID fix.

## 1. Mutation checks on today's fixes

Method. For each fix on `ipad1` since 2026-09-29 00:00:
1. **Unit gate.** Revert the commit's non-test files on `audit`, keep today's tests, and run
   `tests/gate.sh --quick`.
2. **Boot-backed.** Rebuild qemu-system-arm and the dylib (`contrib/macos-app/make-dylib-macos.sh`), then run
   the check STATUS/smoke names. That is a matrix row through the app's helper
   (`tests/sessions/matrix.py --rerun`, cold IPSW cache) or a regress leg on a device I prepared.
3. **Controls.** Tip-pin runs of the same row/leg as controls: 8L1, 7B500, 8A230m, 5F138, 1G, k48 8C148.

A revert that conflicts was replaced by a hand mutation of the fix's core hunk (patch files in scratch).

| Fix (commit) | Check claimed to cover it | Unit gate with fix reverted | Boot check with fix reverted | Verdict |
|---|---|---|---|---|
| I2S reg 0 bit 1 stopped, smoke-4 (436eaadc1a) | 8A230m agent halt → PMU power-off | 73/0: no unit test | matrix 8A230m: **shutdown FAIL** (boot 1 never; boot 2 23.0 s). Tip: 1.5 / 0.9 s | Covered by the matrix shutdown column (boot 1) |
| FMI read transfer rule, FPart Init (b8cb740548) | 7B500 seal | 73/0: no unit test | matrix 7B500: **prepare FAIL** "seal boot: no clean halt after 300 s". Tip control: all ok | Covered by prepare |
| FMI drain re-queue (8326e086ed) | 7B500 seal hang | revert conflicts | not run separately (the b8cb740548 revert already hangs the seal) | Unknown alone |
| PMU ADC mux 6, #35 (b273f07a02, 5d5b70d6c7) | 8L1 lockdown | no unit test (no test touches s5l8930_i2c.c) | `S5L8930_ADC=6:800` (the pre-fix mid-scale) on matrix 8L1: **lockdown FAIL**, serial `AppleUSBCableType Detached`. Tip: `USBHost` | Covered by the lockdown column |
| ADC start bit clears (b273f07a02) | iBoot-1219 `dialog_read_adc` (5.1.1 on iboot=) | none | no catalog row boots iBoot-1219; 8K2/8L1 are `boot: kboot` | **No automated check** |
| RGBOUT swap + IRQ 0x2b, #27 (0c9207cbd9) | 8L1 slider power-off | 73/0 | matrix 8L1: **shutdown FAIL** (boot 1). The prepare still passes (the seal only gets slower) | Covered by boot 1's shutdown. The tip's boot 2 fails the same way, unjudged (finding 4) |
| 1G ADM 0x400/0x600 (d430053290) | "power-off → reboot keeps the setting" on an N45NAND store | 73/0 | 1G `boot,gles` **PASS** with it reverted. No 1G two-boot leg exists, and no n45 catalog entry exists, so the matrix can't run it | **Not covered** by anything automated |
| 1G spare programming (a75adb9bab) | same | revert conflicts | not run | Not covered (same reason) |
| Surfaces by pages, re-read only when written (eb83ca1aed) | 4.2.1 app-close; test_gles_surface | revert conflicts. Mutant "CPU writes never seen" (`gles_surface_changed` returns false): **test_gles_surface FAILS (SIGABRT)** | same mutant: 5F138 gles PASS, 1G gles PASS, iPad 8C148 gles+shadow PASS. The frames are byte-identical to the tip below the status bar (these screens upload each surface once) | Covered by the unit test only. No boot leg exercises a CPU-updated surface |
| 1G LCD write generation (920a3eeac4, LCD hunk) | 1G gles leg ("fails with the LCD fix reverted") | 73/0 | mutant (generation read, redraw dropped): **1G gles FAIL** "frames did not follow the gestures". **5F138 gles PASS** | Covered on the 1G only. STATUS says "both boards"; on the 2G no check can tell |
| MBX 0x130/0x12c (920a3eeac4) | 1G gles | revert conflicts | not run separately | Unknown |
| CDMA inline AES on device-FIFO writes (f653711345) | 4.3.5 fsck/remount | conflicts (trace part); CDMA hunk reverted alone | matrix 8L1: **prepare FAIL** "keybag boot: halted without the keybag" | Covered by prepare |
| D1815 0x7b = 0x0b restart (c1b1305129) | "launchd reboot resets the machine" | 73/0 | matrix 8L1 **all ok**, both shutdowns confirmed | **Not covered by the matrix.** Only restore-smoke/by-hand reboots exercise it, and I didn't run restore-smoke |
| CDMA +0x10/+0x14 enabled status (19ede8f9b5) | 5.1.1 AppleCDMA | 73/0 | matrix 8L1 all ok. No 5.x catalog row | **Not covered** (5.x only) |
| H2FMI write needs meta, O(1) pops, migration (3efabacbc5) | 3.2.2 IOP firmware stale-meta panic; restore verify speed | 73/0 | matrix 7B500 **all ok** | **Not covered by the matrix.** Restore-smoke is its only candidate, and it isn't in the matrix by default |
| iBoot epoch from LLB's check (2760108041) | test_iboot_epoch | **test_iboot_epoch FAILS** | 8K2/8L1 on kboot: no row boots iBoot-1072/1219 | Unit-covered (the finder). The boot behaviour isn't covered |
| K48 panel ID (fa8f3404b6) | iBoot-1219 `pinot_read_panel_id` | 73/0 on the tip gate | not run | **Now unit-covered** by the repaired test_dsi_fifo (its mutation `panel_id_len<<8 → 3<<8` fails) |
| CDMA drained-during-last-push (4b14ef8bf5) | IOP "dma timeout" on 2 of 4 5.x seals | 73/0 | matrix k48 8C148 all ok (one run) | Not shown covered: a probabilistic race, 4.x never hit it |
| 2.x front end fixes (63ae50e755) | 5F138 gles | conflicts | window-order mutant (write-back ignores row order): **5F138 and 1G gles PASS with an upside-down screen**, unit gate 85/85 | **The geometry of the 2.x/1.x path is not covered by anything** |
| R/B order of BGRA surfaces (gles-host, general) | iPad gles, shadow | **test_gles_surface FAILS** | iPad 8C148 gles + shadow **PASS** with a red/blue-swapped home screen (`pd-k8C148-rbswap-home-small.png`) | Unit-covered only. The iPad boot legs are blind to colour |

## 2. The quick gate's 12 KNOWN tests: all repaired, none deleted

qemu-ios `audit` c9ac5d7173 (cherry-picked from audit-tests aec7785036). KNOWN is now empty. Gate
`--quick` is 85 PASS / 0 FAIL / 26 SKIP (it was 73 / 12 XFAIL). Every break was harness rot, not a model
regression.

| Test | Covers | Matters | Real break (KNOWN said) | Mutation proving it bites |
|---|---|---|---|---|
| test_amc_aac | AMC DMA/PCM contract with real libavcodec (AAC-LC/HE, MP3, ALAC), slots, backpressure, snapshot | yes | mock lacked `buf_base` | `amc_decode_publish` slot offset dropped → PCM compare assert |
| test_app_ledger | ledger verdicts, check_applaunch stages and evidence | yes (harness) | check_applaunch now spawns through `procs` (KNOWN: right) | schedule `(5,20)→(5,25)`; verdict `'yes (30 s)'→'yes'` |
| test_battery_bridge | app→emulator battery/charging calls, bounds, BH marshalling | UI plumbing only (not the PMU model) | slice ran into machine-prop code | `charging > 2 → > 3` |
| test_dsi_fifo | MIPI-DSIM FIFO, wrap, INTSRC, reset; **now also** the K48 4-lane status and Pinot panel ID | yes | helpers never sliced; property defaults missing | `panel_id_len << 8 → 3 << 8` |
| test_gles_drawable_storage | CA drawable resize, renderbuffer size, full write-back | yes | `gles_guest_fault_pending` undeclared | `bgra = true` → pixel compare fails |
| test_launch | unlock after the lock-status reply, exact foreground bundle | yes (harness) | AgentControl, not int | lock-status test widened → assert |
| test_multitouch_frames | Zephyr touch frame wire format, 0–5 fingers, K48 span | yes | **KNOWN wrong**: `profile` exists; the mock lacked it | `fd[i].y` truncation → K48 position assert |
| test_osk_config | osk= vs IT_OSK precedence | marginal (property plumbing) | **KNOWN wrong**: slice bound drifted | env alias ignores `osk_explicit` |
| test_pvrtc_upload | PVRTC upload rules, decoded pixels read back | yes (games) | **KNOWN incomplete**: gles_refuse/gles_debug_texture stubs | `pvrtc_twiddle dst<<1 → dst` |
| test_scaler | NV12→RGB565/BGRA, padding, DMA bounds, IRQ | yes (movies) | DeviceState/ROUND_UP missing | video-range offset `?16:0 → ?0:0` |
| test_uart_rx_transitions | UART IRQ map, Rx timeout, DMA mode | yes (console, BT) | **KNOWN incomplete**: MIN plus new tx fields | Rx IRQ bit where Tx belongs |
| test_ui_buttons | batched host button events still give a ≥100 ms guest hold | yes (Home/Hold) | `ipad1_press_button` undeclared | `MAX(now, pressed_at+100) → now` |

What the repaired tests still don't reach:
- the scaler's RGB→RGB path;
- battery_bridge never touches the PMU model;
- osk_config tests option precedence, not the typist.

## 3. What the checks can detect

Classes:
- **(a)** behaviour through a real boot or helper;
- **(b)** a real function compiled and executed;
- **(c)** a source or string assertion only.

### App offline tier (tests/run.py offline, 74 entries)

| Class | Count | Notes |
|---|---|---|
| (a) | 0 | by design |
| (b) | 74 | 27 compile cut-out sections of the big controllers (tests/SLICED.md) |
| (c) | 0 pure; 3 with string-check tails | `check-window-restoration.py:63-69` (source text and project file), `check-web-proxy.py:95` (project-file count), `check-help.py:19-21` (phrases in Help.txt) |

Checks whose result doesn't depend on the code under test:
- **Pass without running anything.** `check-media-preflight.py:13` and `check-video-preflight.py:12` print SKIP
  and **exit 0** when `contrib/it-harness/build/Payload/Harness.app` is missing. It is missing on the pinned
  checkout, and run.py counts exit 0 as PASS. Both media checks count toward "offline 73/0" without running.
- **Never run.** `run-catalog-checks.py`'s apps-list UI half needs `--ui`, and the tier never passes it.
- **Structure only.** `check-apps-menu` and `check-device-menus` stub every menu action as a no-op, so they test
  menu structure only.
- **Pass when their input is missing.** check-activation-gate and check-boot-deadline return 0 when their default
  device is missing.

### Sessions tier

| Check | Detects | Can't detect |
|---|---|---|
| check-sessions "both reach their home screens" | a newer frame exists (`check-sessions.py:319`) | lock vs home, black, wrong picture |
| check-sessions `--guest` (agent, respring, time zone, photo, rollback) | real guest services | SKIP unless `LTM_IPOD_DEVICE` is set; no default (`run.py:131-134`) |
| check-helper-boot iPad cases | – | never run on the default iBoot device (no kboot.bin) |
| session driver `lit` | brightness ≥ threshold once (0.03 on iPod: the white Apple logo, ~4% of the panel, can count as lit) | a home screen; a panel that goes dark 12 s later (finding 3) |

### qemu-ios regress legs

| Leg | Asserts | Would trip on | Blind to |
|---|---|---|---|
| iPod boot | lit sub-pixels above a minimum, not a solid fill, held 15 s | dark or solid panel | content; lock vs home |
| iPod gles (3.x/4.x fixture app) | magenta ≥ 5% and cyan ≥ 5% over two shots, nothing ≥ 35%; no refusals | missing scene, **R/B swap**, wedged renderer | position, flip, texture content |
| **iPod gles, 2.x/1.x front end** | one hello, pixmap log line, a live context, no refusals, lit counts: Safari differs from home by ≥ 1000, the close returns within 5% | SpringBoard restart, software fallback, stuck Safari frame (1G LCD) | **an upside-down screen (shown), colour, stale surfaces (shown).** The "swipe" is not required to change anything (2.1.1 and 1.1 have one page: swipe lit == home lit) |
| **iPad gles (3.x/4.x/5.x)** | nothing refused, magenta ≤ 0.1% | refusals only | **everything visual: R/B swap passes (shown), stale surfaces pass (shown).** "page 2" is byte-identical to home on 4.2.1. On 5.x the Setup Assistant walk only checks that a region changed, and it needs a scratch-only activation hook (#37) |
| iPad shadow | two pixels of the popover shadow | solid-box shadow | everything else |
| iPad boot | lit ≥ 50% and ≥ 64 colours for lock *and* "home" | dark or solid panel, USB alert, Hold | a failed unlock (home uses the lock test) |
| audio (both) | 440/880 Hz ±5 Hz per channel; iPad correlation ≥ 0.8 | pitch, channel swap, silence | short dropouts |
| afc, persist (iPod) | sha256 equal after a clean shutdown | lost or changed file | – |
| iPad persist | the file survives a reboot | – | kills the guest 45 s after the upload, so never the clean-shutdown path |
| fsck | `fsck_hfs -n` exit | filesystem damage | – |
| wifi, net, usbmux, applaunch, agent | link/DHCP, a GET, a string, the foreground app, a ping | dead service | wrong content |

### Matrix columns (tests/sessions/matrix.py `judge`)

| Column | Judged from | Wrong pixel | Wrong activation | Lost file | Slow frame |
|---|---|---|---|---|---|
| lit | first `lit` event on boot 1 | no (black 12 s later passes) | – | – | no |
| lockdown | boot 1 ProductType | – | – | – | – |
| activation | boot 1 `ActivationState == "Activated"` string | – | yes, the string only | – | – |
| afc | 4 sizes, same bytes | – | – | yes | – |
| install | the app is listed | – | – | – | – |
| package | it_boot's report serial | – | – | – | – |
| **gl** | **hard-coded skip** (`matrix.py:233`) | **no** | – | – | **no** |
| persist | file kept after boot 1's shutdown + boot 2 | – | – | yes | – |
| shutdown | **the first quit only** (`matrix.py:242-245`); boot 2's `confirmed` is stored as `second` and never judged; `restartedApps` is ignored | – | – | – | – |

A skipped column never fails a row, and there is no timing column at all.

## 4. Self-graded criteria, re-measured

**Quiet-host rule.** Load under 8 was reached once in about 2 h: 16:08, 1-min load 6.9. The 5F138 GL run started
then; other agents pushed the load to 24 within the run. Every later start waited up to 20 min for load < 8 and
was **skipped**:
- 5F138 software at 17:00 (min 8.8);
- 5F138 GL at 17:20 (min 10.6);
- the iPad app-close at 17:40 (min 18.3).

The numbers below are therefore **not comparable with STATUS's**. STATUS's 2.x numbers were themselves taken at
load 9-15, the 1.x ones at load 2-5. None of STATUS's measuring scripts is in either repo, so there was nothing
to rerun. The audit's harnesses are in scratch:
- `perf.py`: IT_LCD_FRAMETRACE presents plus QEMU CPU, three passes;
- `perf_ipad.py`: the display's `swaps` counter sampled over QMP.

| Claim (STATUS / from-ipsw.md) | Reported | Re-measured (audit) | Verdict |
|---|---|---|---|
| 2.x GL front end, Safari launch zoom | 40-41 fps, 0.27-0.31 cores, load 9-15 | GL 27 / 37 / 35 fps, 0.17 / 0.13 / 0.15 cores (load 11-19) | Not reproduced at the reported rate. The method differs (my window is first-to-last present, launch included), so this is neither a confirmation nor a refutation. No script to rerun theirs |
| 2.x Safari close zoom | 57-60 fps GL | 56 / 42 / 41 fps (load 11-24) | Same caveat |
| 2.x "GL ≈ software, ~25% less CPU on the launch zoom" | – | software twin (same entry, `gles_shim` off) at load 37-42: launch 0.28 / 0.24 / 0.25 cores against GL's 0.13-0.17 | The CPU direction agrees, but the runs were 25 load points apart: indicative only |
| 1.x table | load 2-5 | not rerun (no quiet window) | Skipped |
| iPad 4.2.1 app-close: 44-49 fps, first frame 1.0 s | – | one functional trial at load 20: close 47.9 fps, first frame 0.78 s, 35 frames; launch 38.3 fps | Consistent with the claim at load 20, one sample. Not a quiet-host measurement |

**5.x gles leg: not rerun.** It needs a 9B206 device whose lockdownd carries the scratch-only 5.x activation
hook (smoke #37, `repro-ios5gl/patch_lockdownd5.py`), which no committed pipeline produces. From its code, it
asserts what the 4.x leg asserts (no refusals, no magenta), plus "a screen region changed" per Setup Assistant
tap. It is self-graded in the same way.

**Same image, not just an image.** The GL frame was compared with a software-CA frame of the same screen:
- same capture path (QMP screendump);
- a software twin prepared from the same catalog entry with `options.gles_shim` off, for 1.x through
  `ipod1g_device.py --no-gles`;
- status bar masked.

| Board / screen | Pixels differing (>2 / >8 of 255) | Max | Verdict |
|---|---|---|---|
| 2.1.1 home | 0 / 0 | 1 | **same image** |
| 2.1.1 Safari Bookmarks | 0 / 0 | 1 | **same image** |
| 1.1 Safari | 0 / 0 | 1 | **same image** |
| 1.1 home | 656 / 617, all in the Calendar icon | 205 | Same except the date: Friday 4 against Saturday 5 across two boots, the 1G RTC drift (smoke #22) |

So the 2.x/1.x front end renders the software path's pixels to within 1 LSB on these screens. This is the
strongest graphics evidence in the tree, and it exists only in this audit. No committed check does it, and the
same legs pass upside-down and colour-swapped frames (section 1).

Frame-rate numbers are hand-measured and ungated. Nothing in either repo would fail on a slow frame, a longer
first frame or more host CPU; `gltest.py` itself says "fps is reported, not judged".

## 5. Catalog flips today, and two cold reruns

Evidence check (under `~/Developer/qemu-ios-files/matrix-results/<entry>/`, against matrix-results.json):

| Entry | Flip | Evidence | Mismatch or flag |
|---|---|---|---|
| n72ap-5F138 | dbeee59 | present (04:31) | Flipped while the JSON row said shutdown FAIL; the passing row came ~2 h later. The GL cell was hand-edited into the JSON (1cf9cbe), with no artefact. The row ran with AppSync off: the shipped recipe (AppSync on, 4add406) never went through the matrix. It ran on qemu-ios-2x-hold (worktree deleted) |
| n72ap-5G77a, 5H11a | inside merge c73f37c (neither parent) | present | Same as 5F138. The flip isn't attributable to a branch commit |
| k48ap-8F190, 8J3, 8K2, 8L1 | d68a3f1 | present | Boot-1 lock/home/installed are one black 10453-byte PNG (brightness 0) |
| k48ap-8G4 | d68a3f1 | present | Real screenshots |
| k48ap-8H7 | d68a3f1 | present | Boot-2 shutdown 24.2 s against 14.4 s for boot 1, unjudged |
| k48ap-8L1 | d68a3f1 | present | **Boot 2 power-off unconfirmed (`second: null`), flipped anyway.** Runs on `boot: kboot`. Software CA (no GL) |
| all iPad 4.3.x rows | – | – | Recorded with the `qemu-ios-ipad-43-usb` dylib; the worktree and dylib are deleted. The commit is known only from STATUS text |

Cold reruns at the pin (5d5b70d6c7, guest tools and dylib exported from the same tree, empty IPSW cache, fresh
downloads from Apple):

| Entry | Host load | Prepare | lit | lockdown | Activated | AFC | install | package | persist | boot-1 shutdown | **boot-2 shutdown** | Boot-1 screenshots |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| k48ap-8L1 | 30–60 | ok 92 s | 66.8 s | ok | ok | 4/4 | ok | 7 | ok | 15.1 s | **unconfirmed in 50 s** | all 3 black |
| n72ap-5F138 | 35–60 | ok 37 s | 16.1 s | ok | ok | 4/4 | **FAIL** (6 retries, "stopped responding during install") | 7 | not reached | not reached | not reached | lit |

8L1's boot 2 in my runs whose mutation doesn't touch shutdown: confirmed on the CDMA-status mutant (15.3 s)
and the D1815-restart mutant (16.1 s). Together with the recorded row, that is 2 failures in 4.

Serial on the failing boot 2: SpringBoard loops `gliInitializeLibrary / no gldshim device`, then
`ApplePinotLCD::_lcdEnable: enable: 0`, and never `reboot(RB_HALT)`.

**5F138 fails the matrix at the pin. 8L1's boot 2 fails in about half the runs, unjudged.** Both are `experimental` in the
catalog.

## 6. Fidelity classes: five R closures against the evidence bar

The bar: "modelled faithfully or shown to be real-hardware behaviour". What each closure cites:

| Claim | Class claimed | Evidence | Verdict |
|---|---|---|---|
| #35 ADC mux 6 = host pull-downs, 0 V | S→R | **The reader, from disassembly:** the power-source classifier at 4.2.1 807b6b38 and 4.3.5 809f7d00; gdbstub on 8C148 and 8L1. **The value, inferred:** no D1815 datasheet, no measurement. The first commit's "4.x never reads it" was wrong and was corrected 2 h later | **Inferred value, R-labelled.** The model is narrower than the claim. `usb_host` is simply `usb_cable`; brick_id_p/n line selection isn't modelled; there is no charger case. With the cable out the lines read the mid-scale value just shown to classify as a 1 A brick. Ledger K48 #15 still calls the D1815 H |
| I2S reg 0 bit 1 "stopped" (smoke-4) | R | the driver's spin after writing 0x30; STATUS row 62 itself says "meaning inferred from the driver; no datasheet" | **Should be H.** The bit sets the instant enable clears, with no drain latency |
| FPart Init FMI transfer rule (b8cb740548) | R | iBoot-817 write sequences (0x5ff04066, 0x5ff0422e) and EmbeddedIOP-20's; the commit says "the rule that fits both drivers" | **Inferred from two drivers**, not a hardware contract. The drain re-queue (8326e086ed) is a genuine model bug, fairly R |
| #27 RGBOUT swap completion + IRQ 0x2b | closed; ledger #27 stays **S** | The waiter is proven by disassembly (`swap_wait` 0x8084e7b8 via `clientClose`); DT `rgbout` interrupt 0x2b. The code's own note: RGBOUT runs off pipe0's tick and is never scanned out | **Closed while the component is S: misses the bar.** That real RGBOUT completes swaps with no dock and an unprogrammed timing generator is assumed |
| #3 CDMA inline AES | R (STATUS row 58, smoke Closed) | the commit cites "the store is in the clear by contract, fidelity-ledger K48 #34"; ledger #34 is **H** ("a real device holds ciphertext") | **Mislabelled: H.** It removed AES on writes to match an existing H shortcut. The device-FIFO inline AES path is now dead code |
| (extra) D1815 ADC start bit clears | R | "as on the part"; the only evidence is iBoot-1219 polling it | Inferred, plausible |

Mechanism (the waiter, the reader) is often backed by real disassembly. The hardware answer is inferred
every time. Those are H by the ledger's own definitions.

## Tests repaired and deleted

- **Repaired (12):** test_amc_aac, test_app_ledger, test_battery_bridge, test_dsi_fifo (extended to the K48
  panel ID), test_gles_drawable_storage, test_launch, test_multitouch_frames, test_osk_config, test_pvrtc_upload,
  test_scaler, test_uart_rx_transitions, test_ui_buttons. qemu-ios `audit` c9ac5d7173; tests/gate.sh KNOWN
  emptied.
- **Deleted:** none (every one tests live code).

## Coverage gaps that matter most, ranked

1. **Graphics correctness (all boards).** ~~No boot leg or matrix column compares a frame with a reference, so
   upside-down, colour-swapped and stale frames all pass.~~ **DONE** (matrix-graphics / matrix-graphics-qemu,
   2026-09-29). `tests/framecheck.py` diffs a capture against a committed software-CA reference: a 64-wide
   box-filter downsample stored as a tiny PNG (block means, tolerant to host-GPU filtering, not a golden), the
   status-bar/clock band masked. The 2.x/1.x front-end leg (`check_gles_front_end`) diffs gles-{home,safari,swipe},
   and the iPad `gl_clean` diffs each pinnable screendump (home/screen/lock), against `tests/gles-refs/`; both FAIL
   on a mismatch. `tests/ipod/test_framecheck.py` proves, with no boot, that a correct frame passes and the
   audit's flip / R/B-swap / stale mutants each FAIL on a screen where they manifest (correct 0.000-0.007; flip
   0.30-0.69, R/B swap 0.21-0.31, stale iPad surface 0.10; THR 0.02). The matrix `gl` column no longer skips: it
   records the render path (hardware GL vs a software-CA fallback), refusals, and the frame verdict.
   - *Remaining.* 3.0's MBXGLEngine home and the 4.x/5.x shim path have no committed reference yet, so they stay
     liveness-only (noted in the pass line); stale is invisible on the single-page 2.x front end (it only
     manifests on a CPU-updated iPad surface -- caught there).
2. **Boot 2 and screen state in the matrix.** ~~It should judge boot 2's shutdown, `restartedApps`, and a
   home-screen brightness/colour floor on every screenshot. Boot 1 on 4.x iPads is black today.~~ **DONE**
   (matrix-graphics, 2026-09-29). The session driver wakes the panel before every home/installed capture
   (`wakeForShot`: the display sleeps ~12 s after `lit`) and emits a `home` event with brightness and the
   SpringBoard-frontmost bundle id for boot 1 and boot 2. The matrix's new `home` check FAILs any home/installed
   screenshot below the luma floor (the 4.x iPad black home now fails), a non-SpringBoard frontmost, or a
   frame-reference mismatch. `shutdown` now judges boot 2's clean power-off (8L1's stalled second boot fails);
   `restartedApps` is recorded. `tests/sessions/test-matrix-judge.py` drives `judge()` to prove each verdict bites.
   The two defects this hid (8L1 boot 2, 4.x boot-1 black) now surface as row failures instead of passing.
3. **Activation.** The matrix and sessions check the `ActivationState` string only. Nothing checks that the
   device *behaves* activated: no Setup/activation screen, installs allowed, and on 5.x the hook exists only in
   scratch (#37). A lockdownd patched to report "Activated" while SpringBoard still gates passes.
4. **IOP/NAND/PMU emulator fixes have no host tests.** H2FMI, CDMA, D1815, IOP core and DART get no unit coverage.
   - *Boot-only.* Of today's fixes, D1815 restart, H2FMI write-wait, CDMA status and CDMA drain are exercised by no
     automated check.
   - *What would close it.* Register-level unit tests in the style of test_dsi_fifo, plus restore-smoke and one
     reboot in the matrix.
   - **Partly DONE** (matrix-graphics, 2026-09-29): the "one reboot in the matrix" half is closed -- the matrix now
     judges boot 2's clean shutdown, so a fix whose regression stalls the second power-off (e.g. D1815 restart)
     fails a row instead of passing. `test_framecheck` also establishes the boot-free "prove the fix with a
     committed mutant" pattern for graphics. *Remaining:* the register-level H2FMI/CDMA/D1815/IOP/DART unit tests,
     and restore-smoke in the matrix by default.
5. **The real iBoot chain on SEPO 2 and 5.x.** No catalog row boots iBoot-1072/1219 (8K2/8L1 are kboot, 9B206
   isn't in the matrix). The epoch, ADC start bit, panel ID and CDMA status fixes have no standing check.
6. **1G storage.** No two-boot leg and no catalog entry, so the ADM 0x400/0x600 model is unguarded (its revert
   passes everything).
7. **Performance.** Nothing gates on fps, first-frame latency or host CPU. The STATUS numbers came from scripts
   outside the repos. A committed harness (the audit's `perf.py`/`perf_ipad.py` are a start) and a coarse gate
   would do: "close zoom first frame < 1.5 s", "fps within 30% of the software path".
8. **Guest services.** The sessions tier's guest checks don't run by default (`LTM_IPOD_DEVICE`), so the agent,
   respring, photo import and rollback can regress unseen.
9. **Compatibility.** The shipped 2.x recipe (AppSync on) was never run through the matrix, and it fails install
   at the pin. Catalog flips should require a matrix row recorded with the shipped recipe on the pinned commit,
   with the dylib's commit in the row.
10. **Tests that pass without testing.** check-media-preflight and check-video-preflight exit 0 on SKIP.
    run.py should treat "SKIP" output as SKIP, not PASS.
