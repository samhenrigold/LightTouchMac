#!/usr/bin/env python3
"""framecheck.py -- is a captured frame the right *picture*, not just lit?

The 2026-09-29 test audit (LightTouchMac docs/test-audit-2026-09-29.md, ranked gap #1)
showed every boot leg and matrix column judges liveness -- lit-pixel counts, "nothing
refused" -- so a frame written upside down, with red and blue swapped, or left stale
(a previous surface) all PASS. Section 4 of the audit also showed the fix: the GL path
renders the software-CoreAnimation path's pixels to within 1 LSB on the screens we can
pin (2.x/1.x home and Safari, the iPad SpringBoard), captured over the same QMP
screendump. So a reference *does* work here -- as long as it is a downsampled, tolerant
signature (block means, not pixel-exact: robust to host-GPU filtering) rather than a
golden PNG.

The reference is a `GW`-wide box-filter downsample of a known-good frame, stored as a
tiny PNG (a few KB, human-inspectable, so the repo stays small). `verdict` downsamples
the capture the same way and reports the fraction of blocks (status-bar/clock band
masked) that differ by more than TOL. Measured margins on the audit's captures: a
correct frame is 0.000-0.007; flip 0.30-0.69, R/B swap 0.21-0.31, a stale iPad surface
0.10 -- so THR 0.02 separates them with room on both sides.

    framecheck.py make REF.png IMG            build a reference from a known-good frame
    framecheck.py check REF.png IMG [--thr F]    diff a capture against it
    framecheck.py selftest                     tiny built-in assert demo
"""
import sys

GW = 64          # signature grid width; height is aspect-scaled from the source
TOL = 8          # per-channel block-mean drift still counted as "the same block"
THR = 0.02       # FAIL if more than this fraction of unmasked blocks differ by > TOL
MASK_TOP = 0.08  # top band excluded: the status-bar clock (and the iPad lock time)
# The iPod panel model scales every pixel by the backlight level the guest programs (qemu-ios
# ipod_touch_lcd.c, PMU WLED register 0x30), as a dim real screen looks; the references are
# captured at full exposure (IT_LCD_BRIGHT=255). 2.x's SpringBoard leaves the backlight at
# ~0.76-0.79 (5F138 193/255, 5G77a/5H11a 201/255), so its captures are the right picture,
# uniformly dimmer. `verdict` measures that gain and undoes it before the diff, down to this
# exposure; a dimmer capture is compared as it is (and fails).
EXPOSURE_MIN = 0.6


def signature(path, gw=GW):
    """A frame -> (gw, gh, [ (r,g,b), ... ]) of block means. Idempotent on a reference
    PNG that is already gw wide. Needs Pillow."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    w, h = im.size
    gh = max(1, round(gw * h / w))
    small = im.resize((gw, gh), Image.BOX)  # BOX = block-mean downsample
    return gw, gh, list(small.getdata())


def fraction_differing(cap, ref, tol=TOL, mask_top=MASK_TOP):
    """Fraction of unmasked blocks whose max channel drift exceeds `tol`."""
    (gw, gh, a), (rw, rh, b) = cap, ref
    if (gw, gh) != (rw, rh):
        raise ValueError("aspect/grid mismatch: capture %dx%d vs reference %dx%d" % (gw, gh, rw, rh))
    top = int(gh * mask_top)
    differ = total = 0
    for i in range(top * gw, gh * gw):
        pa, pb = a[i], b[i]
        if max(abs(pa[0] - pb[0]), abs(pa[1] - pb[1]), abs(pa[2] - pb[2])) > tol:
            differ += 1
        total += 1
    return differ / total if total else 0.0


def exposure(cap, ref):
    """The capture's backlight gain against the reference: the median capture/reference
    ratio over blocks the reference has bright (a uniform backlight scales them all alike)."""
    r = sorted(sum(c) / sum(f) for c, f in zip(cap[2], ref[2]) if sum(f) > 150)
    return r[len(r) // 2] if r else 1.0


def normalise(cap, gain):
    """Undo a backlight gain (see EXPOSURE_MIN); outside [EXPOSURE_MIN, 1) the capture stays as it is."""
    if not EXPOSURE_MIN <= gain < 1:
        return cap
    return cap[0], cap[1], [tuple(min(255, round(v / gain)) for v in px) for px in cap[2]]


def verdict(cap_path, ref_path, thr=THR):
    """{ok, frac, thr, exposure, why} for a captured frame against a reference PNG."""
    try:
        ref = signature(ref_path)
        cap = signature(cap_path, ref[0])
        gain = exposure(cap, ref)
        frac = fraction_differing(normalise(cap, gain), ref)
    except Exception as e:  # aspect mismatch, unreadable frame: not the reference picture
        return {"ok": False, "frac": None, "thr": thr, "why": "could not compare: %s" % e}
    ok = frac <= thr
    return {"ok": ok, "frac": round(frac, 4), "thr": thr, "exposure": round(gain, 3),
            "why": ("matches the reference (%.3f <= %.2f)" % (frac, thr)) if ok else
                   ("differs from the reference (%.3f > %.2f): flip / colour swap / stale surface"
                    % (frac, thr))}


def make_ref(src_path, out_png, gw=GW):
    """Write a known-good frame's downsample as the reference PNG."""
    from PIL import Image
    gw, gh, grid = signature(src_path, gw)
    im = Image.new("RGB", (gw, gh))
    im.putdata(grid)
    im.save(out_png)


def home_verdict(lock, events, entry_id, references):
    """Judge home independently of panel liveness. An unobserved screen is unknown.

    Stock 2.x has no guest agent, so a known-good picture is its evidence. A lit
    Connect-to-iTunes screen alone must never qualify as home.
    """
    from pathlib import Path
    gp = lock.get("guest_package") or {}
    has_agent = ("com.qemu.it-agent.plist" in (gp.get("jobs") or []) or
                 str((lock.get("derived") or {}).get("guest_tools", "")).startswith("installed"))
    shots = {Path(e["path"]).stem: e for e in events if e.get("event") == "screenshot"}
    homes = [e for e in events if e.get("event") == "home"]
    names = [n for n in ("home", "home2", "installed") if n in shots]
    dark = [n for n in names if float(shots[n].get("brightness", 0)) < 0.05]
    wrong = [h["frontmost"] for h in homes if h.get("frontmost") and h["frontmost"] != "com.apple.springboard"]
    locked = [h.get("generation") for h in homes if h.get("frontmost") == "com.apple.springboard" and h.get("screen") != "Home Screen"]
    unanswered = [h.get("generation") for h in homes if has_agent and not h.get("frontmost")]
    frames = {}
    for name in names:
        ref = Path(references) / f"{entry_id}-{name}.png"
        if ref.is_file():
            frames[name] = verdict(shots[name]["path"], str(ref))
    bad_frame = [n for n, result in frames.items() if not result["ok"]]
    observed = {"home" if h.get("generation", 1) == 1 else "home" + str(h["generation"])
                for h in homes if h.get("frontmost")}
    unknown = [n for n in names if n.startswith("home") and not has_agent and n not in observed and n not in frames]
    if not names:
        return {"ok": None, "note": "no home screenshot taken"}
    ok = False if dark or wrong or locked or unanswered or bad_frame else None if unknown else True
    return {"ok": ok, "brightness": {n: round(float(shots[n].get("brightness", -1)), 3) for n in names},
            "frontmost": ([" / ".join(x for x in (h.get("frontmost"), h.get("screen")) if x) or "no answer" for h in homes]
                          if has_agent else "unknown (no guest agent on this build)") if homes else None,
            "dark": dark or None, "wrongApp": wrong or None, "locked": locked or None,
            "unanswered": unanswered or None, "unknown": unknown or None,
            "frame": {n: frames[n]["frac"] for n in frames} or None,
            "exposure": {n: frames[n].get("exposure") for n in frames} or None}


def brightness(path):
    """Mean luma 0..1. A slept/black panel is ~0; the audit's black home is exactly this."""
    from PIL import Image
    px = list(Image.open(path).convert("L").getdata())
    return sum(px) / (len(px) * 255) if px else 0.0


def _selftest():
    black = (2, 2, [(0, 0, 0)] * 4)
    assert fraction_differing(black, black) == 0.0
    red = (2, 2, [(255, 0, 0)] * 4)
    assert fraction_differing(black, red) == 1.0        # every unmasked block differs
    assert fraction_differing(black, red, tol=255) == 0.0  # tolerance swallows it
    grad = (2, 2, [(40, 80, 120), (200, 160, 120), (120, 200, 40), (240, 240, 240)])
    dim = (2, 2, [tuple(round(v * 0.76) for v in px) for px in grad[2]])
    assert abs(exposure(dim, grad) - 0.76) < 0.01
    assert fraction_differing(normalise(dim, exposure(dim, grad)), grad) == 0.0  # a dim backlight is undone
    assert normalise(dim, 0.5) is dim                                             # below EXPOSURE_MIN: as is
    flip = (2, 2, dim[2][::-1])
    assert fraction_differing(normalise(flip, exposure(flip, grad)), grad) > 0.5  # a dim flip still fails
    print("framecheck selftest ok")


def main(argv):
    if len(argv) >= 2 and argv[1] == "selftest":
        return _selftest()
    if len(argv) >= 4 and argv[1] == "make":
        make_ref(argv[3], argv[2])
        print("wrote %s from %s" % (argv[2], argv[3]))
        return
    if len(argv) >= 4 and argv[1] == "check":
        thr = float(argv[argv.index("--thr") + 1]) if "--thr" in argv else THR
        import json
        v = verdict(argv[3], argv[2], thr)
        print(json.dumps(v))
        sys.exit(0 if v["ok"] else 1)
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
