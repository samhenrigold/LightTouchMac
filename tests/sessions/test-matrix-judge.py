#!/usr/bin/env python3
"""test-matrix-judge.py -- the matrix's new home / GL / boot-2-shutdown verdicts bite.

Fabricates a session-driver event stream (no emulator) and runs matrix.judge, asserting the
gaps the 2026-09-29 audit found are now caught:
  - a black/slept home screenshot FAILs the `home` check (audit finding 3 / gap #2);
  - a wrong frontmost app FAILs `home`;
  - a boot-2 quit that never confirms FAILs `shutdown` (finding 4 / gap #2);
  - the `gl` column reports the render path instead of a hard-coded skip, and a software
    fallback shows rather than passing silently;
  - a clean lit-SpringBoard boot with both shutdowns confirmed passes all three.
"""
import importlib.util, json, os, sys, tempfile
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("matrix", HERE / "matrix.py")
mx = importlib.util.module_from_spec(spec); spec.loader.exec_module(mx)

TMP = Path(tempfile.mkdtemp(prefix="judge-"))
mx.MATRIX_REFS = TMP / "no-refs"   # the fabricated flat frames judge brightness/frontmost, not a committed picture ref
def png(name, lum):
    p = TMP / name
    Image.new("RGB", (32, 48), (lum, lum, lum)).save(p)
    return str(p)

def base_dir():
    b = TMP / ("base-%d" % len(list(TMP.glob("base-*"))))
    b.mkdir()
    (b / "device.lock.json").write_text(json.dumps({"guest_package": None}))
    return b

ENTRY = {"id": "k48ap-8L1", "product_type": "iPad1,1", "board": "k48ap", "version": "4.3.5",
         "recipe": {"options": {"appsync": False}}}

def run(events, serial_text=""):
    b = base_dir()
    serial = TMP / ("serial-%d.log" % len(list(TMP.glob("serial-*"))))
    serial.write_text(serial_text)
    shots_to = TMP / ("shots-%d" % len(list(TMP.glob("shots-*"))))
    before = mx.check_sessions.tree(b)
    return mx.judge(ENTRY, events, 0, serial, TMP, shots_to, before, b)

def screenshot(stem, lum):
    return {"event": "screenshot", "path": png(stem + ".png", lum), "serial": 1,
            "width": 32, "height": 48, "brightness": mx.framecheck.brightness(png(stem + ".png", lum))}

def boot_events(home_lum, frontmost, boot2_confirmed, boot2_home_lum=200):
    ev = [{"event": "lit", "seconds": 60.0, "brightness": 0.5},
          {"event": "usb", "productType": "iPad1,1", "seconds": 70.0},
          {"event": "activation", "state": "Activated"},
          screenshot("lock", 200), screenshot("home", home_lum), screenshot("installed", home_lum),
          {"event": "home", "generation": 1, "brightness": home_lum / 255, "frontmost": frontmost},
          {"event": "quit", "generation": 1, "confirmed": 15.0, "exited": True, "reason": "the device stopped."},
          {"event": "lit", "seconds": 55.0, "brightness": 0.5},
          screenshot("home2", boot2_home_lum),
          {"event": "home", "generation": 2, "brightness": boot2_home_lum / 255, "frontmost": frontmost}]
    if boot2_confirmed:
        ev.append({"event": "quit", "generation": 2, "confirmed": 16.0, "exited": True, "reason": "the device stopped."})
    else:
        ev.append({"event": "quit", "generation": 2, "confirmed": -1, "exited": True, "reason": "timeout"})
    return ev

fails = 0
def check(label, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + label)
    if not cond: fails += 1

# 1. black boot-1 home (the 4.x iPad bug): home FAILs even though lit fired.
r, _, first = run(boot_events(home_lum=0, frontmost=mx.SPRINGBOARD, boot2_confirmed=True))
check("black home fails the home check", r["home"]["ok"] is False and "home" in (r["home"].get("dark") or []))
check("lit still passes (panel did light once)", r["lit"]["ok"] is True)
check("first_failure is home", first == "home")

# 2. wrong frontmost app: home FAILs.
r, _, _ = run(boot_events(home_lum=200, frontmost="com.apple.mobilesafari", boot2_confirmed=True))
check("wrong frontmost app fails home", r["home"]["ok"] is False and r["home"]["wrongApp"])

# 3. boot-2 never confirms: shutdown FAILs (boot 1 did confirm).
r, _, _ = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=False))
check("boot-2 unconfirmed fails shutdown", r["shutdown"]["ok"] is False and r["shutdown"]["second_ok"] is False)
check("boot-1 shutdown still recorded", r["shutdown"]["seconds"] == 15.0)

# 4. software-CA fallback shows in the GL column, does not pass silently.
r, _, _ = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True),
              serial_text="glishim ... no gldshim device (GLRendererFloatQEMU.bundle missing?): no GL\n" * 3)
check("gl column reports software fallback", "software" in r["gl"]["path"])
check("gl not a hard-coded skip note", "gl-coverage not merged" not in json.dumps(r["gl"]))

# 5. clean lit-SpringBoard boot, both shutdowns confirmed: home / gl / shutdown all pass.
r, _, first = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True))
check("good boot: home ok", r["home"]["ok"] is True)
check("good boot: shutdown ok (both boots)", r["shutdown"]["ok"] is True and r["shutdown"]["second_ok"] is True)
check("good boot: gl ok on hardware path", r["gl"]["ok"] is True and r["gl"]["path"] == "hardware GL")
# (afc/persist aren't fabricated here, so the row's first failure is afc -- our three checks must not be it)
check("good boot: home/gl/shutdown are not the failure", first not in ("home", "gl", "shutdown"))

import shutil; shutil.rmtree(TMP, ignore_errors=True)
if fails:
    sys.exit("%d matrix-judge assertion(s) failed" % fails)
print("matrix judge: home, GL and boot-2 shutdown verdicts all bite")
