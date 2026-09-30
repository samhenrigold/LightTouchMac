# Animation jank, measured in guest-virtual time

STATUS's old frame-rate numbers (the 2.x/1.x GL front-end rows, the iPad app-close row) were single
wall-clock samples taken by hand. The 2026-09-29 test audit (`test-audit-2026-09-29.md`, section 4 and ranked
gap 7) explains why they prove nothing:
- they were taken at host load 13-220;
- none can be reproduced;
- nothing gates on them.

A mean fps also hides what a person notices. One 200 ms frame in an otherwise fast animation looks like a
stutter but barely moves the average.

The jank harness replaces them with a metric that is the same at any host load.

Code: qemu-ios `jank-harness`, based on the 0a2fc35669 pin:
- `include/hw/arm/frame-timeline.h`, `hw/arm/s5l8930_display.c`, `hw/arm/ipod_touch_lcd.c`;
- `tests/ipad1/jank.py`, `tests/ipad1/jank-baselines.json`, `tests/ipad1/test_jank.py`;
- the `tests/gate.sh --full` suite.

## Ground truth: what the panel latched, and when, in guest time

Both display models latch the scanned-out frame at each 60 Hz vsync:
- iPad: `vbl_tick`, `VBL_PERIOD_NS`;
- iPod: `refresh_timer_tick`, `LCD_VSYNC_PERIOD_NS`.

At that point the model now writes one entry per vsync into a 4096-entry ring (about 68 s):

    seq  virt_ns  newframe  key

| Field | Meaning |
|---|---|
| `virt_ns` | `QEMU_CLOCK_VIRTUAL` at the latch |
| `newframe` | 1 if the latched content changed this vsync: a completed swap on the iPad, a new scanout base on the iPod. 0 if the same frame was shown again, which is a dropped or held frame. |
| `key` | Swap id or scanout base, so a new frame can be told from a rescan of the same buffer |

The ring is read through the display's `frame-timeline` QOM property (`qom-get`). Recording costs two stores
per vsync, and nothing runs on the frame path unless a tool reads the ring.

## Why the numbers don't depend on host load

Virtual time alone is not enough. Without `-icount`, `QEMU_CLOCK_VIRTUAL` follows the host clock while the VM
runs. A guest starved by host load then misses vsyncs, and the timeline shows it. The first runs here, at host
load 145, read `longest 196.7 ms, 49 dropped` for a page swipe that is smooth.

Two more things are needed.

1. **`-icount shift=0,sleep=off`.** Virtual time is counted in retired guest instructions (1 ns each, a 1 GHz
   A4). An idle guest skips straight to its next timer. A frame then costs its instruction count in virtual
   time, whatever the host is doing, and the intervals come out as exact multiples of 16.67 ms.
2. **Input on vsync steps.** A drag injected every 30 ms of host time arrives at a different guest time on
   every run.
   - The iPad display's writable `stop-after-vsyncs` property pauses the machine after N vsyncs. The iPod LCD has the ring
     only, not the stepping properties yet.
   - `jank.py` stops the machine. For each touch sample it queues the sample on the display's `vsync-input`
     property and runs exactly N vsyncs. The display delivers the sample at the first vsync, the way a 60 Hz
     digitizer reports. `input-send-event` refuses a paused VM, and injecting after `cont` would land a few
     host milliseconds late, or miss a short window altogether.
   - It keeps stepping until one second of virtual time passes with no new frame.

   Every stretch of guest time in the measurement is a fixed number of vsyncs. Because the machine is paused
   between steps, reading the ring cannot disturb the frames being measured.

Measured result: two gate runs, one at host load 206→89 and one at 151→165 (the second with 96 extra busy
loops), gave identical new-frame timestamps, frame for frame, on all three animations. The host never came
quiet (under 8) during the work, so there is no quiet-host run to pair with them. See the STATUS row
"Animation jank in guest-virtual time".

The setup is stepped too. The machine stops as soon as the lock screen is confirmed, and the unlock and tip
dismissal run as vsync-stepped scripts. Under `sleep=off` an idle lock screen races through virtual time: its
~8 s dim can pass in under a wall second. So a wall-paced unlock succeeded or failed depending on the host's
speed, and it failed at load 17.

The machine boots with `iop-core=off` (the IOP HLE). The default second core, running Apple's IOP firmware,
never reaches the lock screen under icount. That is noted as an open item, not worked around.

## What this metric can and cannot see

Under icount, anything the emulator does on the host inside one guest instruction costs no virtual time: an
MMIO handler, a GL bridge call, a page-fault storm in the surface cache.

**It catches** regressions in guest-visible timing:
- a swap completed a vsync late, a lost or late VBL/IRQ, a timer model gone wrong;
- guest CPU work per frame, such as CoreAnimation falling back to software rendering.

**It does not catch** host-side emulator slowness. The 4.2.1 surface bind storm fixed by surfaces-by-pages
cost host CPU, not guest instructions, so it would not show here. That needs host CPU per frame, which depends
on load by nature and belongs in a separate, quiet-host measurement.

## The statistics

For each gesture, `jank.py` takes a fixed window of virtual time from the first input and splits the new
frames into runs at gaps over 100 ms. A longer gap is the screen at rest: a finger holding still, or a pause
between two animations.

| Statistic | Why it describes smoothness better than fps |
|---|---|
| **p50 / p95 / p99 frame interval** (in-run) | Jank lives in the tail. A 40 fps mean can be steady 25 ms frames or 16 ms frames with a 200 ms stall; p99 tells them apart. |
| **hitches > 33 ms** | An interval over two vsyncs is a frame that missed a whole refresh, which a person sees as a stutter. The mean spreads one hitch over the whole animation. |
| **dropped** | Held vsyncs inside a run: refreshes that showed no new frame while the screen was animating. |
| **longest** | The single worst in-run interval, the stutter a person remembers. |
| **runs** | A stall long enough to split one animation in two, which would otherwise be classed as rest, shows up as an extra run. |
| **frames** | A floor. An animation that got shorter or disappeared (the app never opened) fails. |

The 60 Hz budget comes from the guest's own cadence: both panels raise a 60 Hz frame interrupt, and
CADisplayLink paces to it.

### Reading a verdict

    app-close   43 frames in 2 runs, p99 16.7 ms, 0 hitches >33 ms, longest 16.7 ms, 0 dropped

This is 43 frames. The button hold is one run, then the zoom follows as a second run after the release. Every
frame arrived on the next vsync, with no hitch and no held refresh. A regression such as one held swap in four
shows up as hitches, a p99 of 33 ms or more, and dropped vsyncs.

## The gate

`tests/ipad1/jank.py --gate` checks three animations on 3.2.2 (golden, `iop-core=off`) against
`jank-baselines.json` and exits non-zero on a regression:
- a home-screen drag to the Spotlight page;
- the Notes launch zoom;
- the app-close zoom.

It runs as a suite of `tests/gate.sh --full`. `tests/ipad1/test_jank.py` checks the scoring on synthetic
timelines in `--quick`.

`IT_JANK_STALL_EVERY=N` makes the display hold every Nth swap for one extra vsync (VBL without swap-done), a
real two-vsync panel stall. It exists only to prove that the gate fails on a stall.

`jank.py --rescore OUT/jank.json [--gate]` re-scores a saved run's timelines without booting.

Results are in the qemu-ios commit and in STATUS.
