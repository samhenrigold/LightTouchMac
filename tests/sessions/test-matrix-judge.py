#!/usr/bin/env python3
"""test-matrix-judge.py -- the matrix's new home / GL / boot-2-shutdown verdicts bite.

Fabricates a session-driver event stream (no emulator) and runs matrix.judge, asserting the
gaps the 2026-09-29 audit found are now caught:
  - a black/slept home screenshot FAILs the `home` check (audit finding 3 / gap #2);
  - a wrong frontmost app FAILs `home`;
  - a boot-2 quit that never confirms FAILs `shutdown` (finding 4 / gap #2);
  - the `gl` column reports the render path instead of a hard-coded skip, and a software
    fallback FAILs it where the pipeline installed the GL shim (k48's built GLEngine, n72's
    gles_shim): the 4.3.x "no gldshim device" boots drew a correct home screen in software;
  - a clean lit-SpringBoard boot with both shutdowns confirmed passes all three.
"""
import importlib.util, json, os, sys, tempfile
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("matrix", HERE / "matrix.py")
mx = importlib.util.module_from_spec(spec); spec.loader.exec_module(mx)

TMP = Path(tempfile.mkdtemp(prefix="judge-"))
def png(name, lum):
    p = TMP / name
    Image.new("RGB", (32, 48), (lum, lum, lum)).save(p)
    return str(p)

K48_SHIM = {"guest_package": None, "tool": {"built": {"GLEngine": "GLEngine"}}}   # K48Recipe's lock
N72_SHIM = {"guest_package": None, "derived": {"gles_shim": True, "gles_engine": "MBXGLEngine"}}
NO_SHIM = {"guest_package": None, "tool": {"built": {"GLEngine": None}}}

def base_dir(lock):
    b = TMP / ("base-%d" % len(list(TMP.glob("base-*"))))
    b.mkdir()
    (b / "device.lock.json").write_text(json.dumps(lock))
    return b

ENTRY = {"id": "k48ap-8L1", "product_type": "iPad1,1", "board": "k48ap", "version": "4.3.5",
         "recipe": {"options": {"appsync": False}}}

def run(events, serial_text="", lock=K48_SHIM):
    b = base_dir(lock)
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

# 4. software-CA fallback with the GL shim installed: the home screen is lit and right (software CA
#    draws it), so only the gl column can catch it, and it must FAIL, on k48 and n72 locks alike.
SW = ("[glishim] gliInitializeLibrary\n"
      "[glishim] libGFXShared registered no gldshim device (GLRendererFloatQEMU.bundle missing?): no GL\n") * 3
for name, lock in (("k48", K48_SHIM), ("n72", N72_SHIM)):
    r, _, _ = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True), serial_text=SW, lock=lock)
    check(f"{name}: home still passes (software CA draws it)", r["home"]["ok"] is True)
    check(f"{name}: shim installed + software fallback FAILs gl", r["gl"]["ok"] is False and "software" in r["gl"]["path"])
r, _, _ = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True),
              serial_text="[glishim] libGFXShared lacks gfxPluginConnectAll/gfxGet*WithID: no GL\n")
check("any glishim 'no GL' give-up FAILs gl", r["gl"]["ok"] is False)
check("gl not a hard-coded skip note", "gl-coverage not merged" not in json.dumps(r["gl"]))
# no shim installed: software CA is the recipe's own choice; it shows, but the picture decides.
r, _, _ = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True), serial_text=SW, lock=NO_SHIM)
check("no shim: software path shows, not failed by gl", "software" in r["gl"]["path"] and r["gl"]["ok"] is True)

# 5. clean lit-SpringBoard boot, both shutdowns confirmed: home / gl / shutdown all pass.
r, _, first = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True),
                  serial_text="[glishim] gliInitializeLibrary\n[glishim] gld plugin registered, device 0x1027000\n")
check("good boot: home ok", r["home"]["ok"] is True)
check("good boot: shutdown ok (both boots)", r["shutdown"]["ok"] is True and r["shutdown"]["second_ok"] is True)
check("good boot: gl ok on hardware path", r["gl"]["ok"] is True and r["gl"]["path"] == "hardware GL"
      and r["gl"]["gld_registered"] == 1)
# (afc/persist aren't fabricated here, so the row's first failure is afc -- our three checks must not be it)
check("good boot: home/gl/shutdown are not the failure", first not in ("home", "gl", "shutdown"))

import shutil; shutil.rmtree(TMP, ignore_errors=True)
if fails:
    sys.exit("%d matrix-judge assertion(s) failed" % fails)
print("matrix judge: home, GL (incl. shim software fallback) and boot-2 shutdown verdicts all bite")
