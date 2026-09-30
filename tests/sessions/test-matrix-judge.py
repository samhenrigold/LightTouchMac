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
  - a clean lit-SpringBoard boot with both shutdowns confirmed passes all three;
  - (matrix-holes) a lock-screen home shot and an agent that never answers FAIL `home`; with no
    agent (2.x/3.0) the frontmost is reported unknown; a dim-backlight capture of the reference
    picture passes (framecheck exposure) while a flipped one still fails;
  - (matrix-load) a boot that hits a deadline is labelled "slow" when its serial log was written just before the
    deadline and "stuck" when it had been silent, stays a FAIL either way, and the md shows the label and the load.
"""
import importlib.util, json, os, sys, tempfile, time
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

K48_SHIM = {"guest_package": None, "tool": {"built": {"GLEngine": "GLEngine"}}}   # K48Recipe's lock
N72_SHIM = {"guest_package": None, "derived": {"gles_shim": True, "gles_engine": "MBXGLEngine"}}
NO_SHIM = {"guest_package": None, "tool": {"built": {"GLEngine": None}}}

def base_dir(lock=None):
    b = TMP / ("base-%d" % len(list(TMP.glob("base-*"))))
    b.mkdir()
    (b / "device.lock.json").write_text(json.dumps(lock or {"guest_package": None}))
    return b

ENTRY = {"id": "k48ap-8L1", "product_type": "iPad1,1", "board": "k48ap", "version": "4.3.5",
         "recipe": {"options": {"appsync": False}}}

def run(events, serial_text="", lock=K48_SHIM, entry=ENTRY, timing=None, serial_mtime=None):
    b = base_dir(lock)
    serial = TMP / ("serial-%d.log" % len(list(TMP.glob("serial-*"))))
    serial.write_text(serial_text)
    if serial_mtime is not None:
        os.utime(serial, (serial_mtime, serial_mtime))
    shots_to = TMP / ("shots-%d" % len(list(TMP.glob("shots-*"))))
    before = mx.check_sessions.tree(b)
    return mx.judge(entry, events, 0, serial, TMP, shots_to, before, b, timing)

def screenshot(stem, lum):
    return {"event": "screenshot", "path": png(stem + ".png", lum), "serial": 1,
            "width": 32, "height": 48, "brightness": mx.framecheck.brightness(png(stem + ".png", lum))}

def boot_events(home_lum, frontmost, boot2_confirmed, boot2_home_lum=200, screen="Home Screen"):
    ev = [{"event": "lit", "seconds": 60.0, "brightness": 0.5},
          {"event": "usb", "productType": "iPad1,1", "seconds": 70.0},
          {"event": "activation", "state": "Activated"},
          screenshot("lock", 200), screenshot("home", home_lum), screenshot("installed", home_lum),
          {"event": "home", "generation": 1, "brightness": home_lum / 255, "frontmost": frontmost, "screen": screen if frontmost else ""},
          {"event": "quit", "generation": 1, "confirmed": 15.0, "exited": True, "reason": "the device stopped."},
          {"event": "lit", "seconds": 55.0, "brightness": 0.5},
          screenshot("home2", boot2_home_lum),
          {"event": "home", "generation": 2, "brightness": boot2_home_lum / 255, "frontmost": frontmost, "screen": "Home Screen" if frontmost else ""}]
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

# 6. helpers (fit checks, boot side): an iPad seed with the agent, it_ethlink and it_prefs jobs, USB Ethernet proven to
#    fit, must be heard from; silence fails, and a lock without them has nothing to judge.
IPAD_LOCK = {"guest_package": {"family": "k48-ios4", "seed": 8, "jobs": ["com.qemu.it-agent.plist", "com.qemu.it-ethlink.plist",
                                                                      "com.qemu.it-prefs.plist"], "hooks": ["/usr/local/lib/it_msmquiet.dylib"]},
             "fit": [{"piece": mx.USB_ETHERNET, "fits": True, "proof": "..."}]}
KONSOLE = "it_ethlink: watching AppleUSBEthernetDevice\nit_prefs: preferences already set\n"
offer = {"event": "offer", "serial": 8}
report = {"event": "guestPackage", "generation": 1, "serial": 8, "result": 0}
good = boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True)
r, _, _ = run(good + [offer, report], serial_text=KONSOLE, lock=IPAD_LOCK)
check("helpers: agent answered, ethlink and prefs reported", r["helpers"]["ok"] is True and r["helpers"]["agent"] and r["helpers"]["ethlink"])
r, _, first = run(boot_events(home_lum=200, frontmost="", boot2_confirmed=True) + [offer, report], serial_text=KONSOLE, lock=IPAD_LOCK)
check("helpers: a silent agent fails", r["helpers"]["ok"] is False and r["helpers"]["silent"] == ["agent"])
r, _, _ = run(good + [offer, report], serial_text="it_prefs: preferences already set\n", lock=IPAD_LOCK)
check("helpers: it_ethlink never watching fails", r["helpers"]["ok"] is False and r["helpers"]["silent"] == ["ethlink"])
unfit = dict(IPAD_LOCK, fit=[{"piece": mx.USB_ETHERNET, "fits": False, "proof": "..."}])
r, _, _ = run(good + [offer, report], serial_text="it_prefs: x\n", lock=unfit)
check("helpers: USB Ethernet proven not to fit is not expected", r["helpers"]["ok"] is True and "ethlink" not in r["helpers"])
r, _, _ = run(good)
check("helpers: nothing baked, nothing to judge", r["helpers"]["ok"] is None)
# 7. package: a loader baked with jobs that is never offered anything fails; a stub seed is a skip, not a pass.
r, _, _ = run(good, serial_text=KONSOLE, lock=IPAD_LOCK)
check("package: a baked package never offered fails", r["package"]["ok"] is False)
stub = {"guest_package": {"family": "n72-ios4", "seed": 8, "jobs": [], "hooks": []}}
r, _, _ = run(good + [{"event": "offer", "serial": -1}], lock=stub, entry=dict(ENTRY, board="n72ap", id="n72ap-8C148"))
check("package: a stub seed is a skip", r["package"]["ok"] is None and "stub" in r["package"]["note"])
r, _, _ = run(good + [offer, report], serial_text=KONSOLE, lock=IPAD_LOCK)
check("package: offered and reported passes", r["package"]["ok"] is True)

# 8. frontmost (matrix-holes 1/2): wherever the boot has an agent, each home shot must be SpringBoard's Home Screen.
#    4.2.1's iPod boot-1 home was the lock screen, which is SpringBoard too: it_agent names it `Lock Screen`.
AGENT_IPOD = {"guest_package": {"family": "n72-ios4", "seed": 8, "jobs": [], "hooks": []}, "derived": {"guest_tools": "installed"}}
N72 = dict(ENTRY, board="n72ap", id="n72ap-8C148", product_type="iPod2,1", version="4.2.1")
r, _, first = run(boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True, screen="Lock Screen"),
                  lock=AGENT_IPOD, entry=N72)
check("frontmost: a lock-screen home shot fails home", r["home"]["ok"] is False and r["home"]["locked"] == [1] and first == "home")
check("frontmost: the answer is recorded with its screen", r["home"]["frontmost"][0] == "com.apple.springboard / Lock Screen")
r, _, _ = run(boot_events(home_lum=200, frontmost="", boot2_confirmed=True) + [offer, report], serial_text=KONSOLE, lock=IPAD_LOCK)
check("frontmost: an iPad agent that never answers at a home shot fails home",
      r["home"]["ok"] is False and r["home"]["unanswered"] == [1, 2] and r["home"]["frontmost"] == ["no answer", "no answer"])
r, _, _ = run(good + [offer, report], serial_text=KONSOLE, lock=IPAD_LOCK)
check("frontmost: iPad Home Screen passes", r["home"]["ok"] is True and r["home"]["frontmost"][0] == "com.apple.springboard / Home Screen")
TWO_X = {"guest_package": {"family": "n72-ios2", "seed": 8, "jobs": [], "hooks": ["x"]}, "derived": {"guest_tools": "omitted: 2.x"}}
r, _, _ = run(boot_events(home_lum=200, frontmost="", boot2_confirmed=True),
              lock=TWO_X, entry=dict(N72, id="n72ap-5F138", version="2.1.1"))
check("frontmost: no agent (2.x) says unknown, not a silent pass",
      r["home"]["ok"] is True and str(r["home"]["frontmost"]).startswith("unknown") and not r["home"].get("unanswered"))

# 9. exposure (matrix-holes 3/4): a 2.x capture is the right picture under the guest's ~0.76 backlight; framecheck
#    undoes that uniform gain, so the committed full-exposure ref passes it, and a flipped dim frame still fails.
refs = TMP / "refs"; refs.mkdir()
grad = Image.new("RGB", (64, 96))
grad.putdata([((x * 4) % 256, (y * 2) % 256, ((x + y) * 3) % 256) for y in range(96) for x in range(64)])
grad.save(refs / "n72ap-5F138-home.png")
def dim_shot(stem, im):
    p = TMP / (stem + ".png")
    im.point(lambda v: round(v * 0.76)).resize((320, 480), Image.NEAREST).save(p)
    return {"event": "screenshot", "path": str(p), "serial": 1, "width": 320, "height": 480,
            "brightness": mx.framecheck.brightness(str(p))}
mx.MATRIX_REFS = refs
def two_x(im):
    ev = [e for e in boot_events(home_lum=200, frontmost="", boot2_confirmed=True) if e.get("event") != "screenshot"]
    return run(ev + [dim_shot("home", im)], lock=TWO_X, entry=dict(N72, id="n72ap-5F138", version="2.1.1"))[0]
r = two_x(grad)
check("exposure: a 0.76-backlight capture of the ref picture passes", r["home"]["ok"] is True and r["home"]["frame"]["home"] == 0.0
      and abs(((r["home"].get("exposure") or {}).get("home") or 0) - 0.76) < 0.01)
r = two_x(grad.transpose(Image.FLIP_TOP_BOTTOM))
check("exposure: a flipped dim capture still fails the picture", r["home"]["ok"] is False and r["home"]["frame"]["home"] > 0.3)
mx.MATRIX_REFS = TMP / "no-refs"

# 10. deadline triage (matrix-load, 09-30): the 9B206 "regression" was a loaded host. A never-lit boot whose serial log
#     was written 5 s before the 240 s deadline is "slow"; one silent for 200 s is "stuck". Both stay FAILs.
T0 = time.time() - 400
never_lit = [screenshot("never-lit", 2), {"event": "fail", "t": 241.0, "why": "ipad never lit"}]
TIMING = {"started": T0, "ended": T0 + 242, "load": (55.58, 41.56, 49.58), "killed": False}
KERNEL = "AppleBCMWLANCore::initDongle(): Core Driver Initialization Time 83.890805000\nit_ethlink: LinkStatus 0 -> 1\n"
r, _, first = run(never_lit, serial_text=KERNEL, timing=TIMING, serial_mtime=T0 + 236)
check("stall: serial written 5 s before the deadline is slow", (r.get("stall") or {}).get("kind") == "slow"
      and r["stall"]["load"] == 55.6 and r["stall"]["silent_s"] == 5.0 and "slow: serial still advancing at load 55.6" in r["stall"]["label"])
check("stall: slow is still a FAIL", r["lit"]["ok"] is False and first == "lit")
r, _, first = run(never_lit, serial_text=KERNEL, timing=TIMING, serial_mtime=T0 + 41)
check("stall: serial silent 200 s before the deadline is stuck", (r.get("stall") or {}).get("kind") == "stuck"
      and r["stall"]["silent_s"] == 200.0 and r["stall"]["label"].startswith("stuck: serial silent for 200 s"))
check("stall: stuck is a FAIL", r["lit"]["ok"] is False and first == "lit")
r, _, _ = run([{"event": "fail", "t": 30.0, "why": "ipad boot: no such file"}], timing=TIMING, serial_mtime=T0 + 29)
check("stall: a boot error is not a deadline, no label", "stall" not in r)
r, _, _ = run(good, timing=TIMING, serial_mtime=T0 + 100)
check("stall: a passing boot has no label", "stall" not in r)
r, _, _ = run([], timing=dict(TIMING, killed=True, ended=T0 + 1200), serial_mtime=T0 + 1195)
check("stall: a driver killed at --boot-timeout is judged at the kill", (r.get("stall") or {}).get("kind") == "slow")
# the md: the Load column and the label next to the first failure
mx.RESULTS_MD = TMP / "matrix-results.md"
r, _, first = run(never_lit, serial_text=KERNEL, timing=TIMING, serial_mtime=T0 + 41)
mx.write_md({"k48ap-9B206": {"version": "5.1.1", "load": {"start": [55.58, 41.56, 49.58], "end": [12.3, 30.1, 40.2]}, "checks": r,
                             "first_failure": {"check": first, "why": r["driver_fail"], "stall": r["stall"]["label"]}}}, {"entries": []})
md = mx.RESULTS_MD.read_text()
check("md: the row shows the load at start and end", "| 55.6 → 12.3 |" in md)
check("md: the first failure carries the label", "stuck: serial silent for 200 s" in md)

# AppSync on: the agent launch must leave the installed app frontmost, and the reboot must still list it.
APPSYNC = dict(ENTRY, recipe={"options": {"appsync": True}})
H = "com.qemuios.harness"
def appsync_events(fronts, still_there):
    ev = boot_events(home_lum=200, frontmost=mx.SPRINGBOARD, boot2_confirmed=True)
    ev.insert(3, {"event": "installed", "has": True, "seconds": 2.0, "attempt": 1, "apps": [H], "bundleID": H})
    ev.insert(4, {"event": "launched", "bundleID": H, "via": "agent", **{f"frontmost{i + 1}": f for i, f in enumerate(fronts)}})
    ev += [{"event": "persist", "kept": True, "same": True}, {"event": "restartedApps", "has": still_there}]
    return ev
r, _, _ = run(appsync_events([mx.SPRINGBOARD, H, H], True), entry=APPSYNC)
check("agent launch reaching the app passes install", r["install"]["ok"] is True and r["persist"]["ok"] is True)
r, _, _ = run(appsync_events([mx.SPRINGBOARD] * 3, True), entry=APPSYNC)
check("agent launch that never brings the app forward fails install", r["install"]["ok"] is False)
r, _, _ = run(appsync_events([H] * 3, False), entry=APPSYNC)
check("an installed app gone after the reboot fails persist", r["persist"]["ok"] is False and r["persist"]["restartedApps"] is False)

import shutil; shutil.rmtree(TMP, ignore_errors=True)
if fails:
    sys.exit("%d matrix-judge assertion(s) failed" % fails)
print("matrix judge: home (incl. lock screen, silent agent, unknown frontmost, backlight exposure), GL (incl. shim software fallback), boot-2 shutdown, helpers, package, launch-frontmost, reboot-kept app and deadline-triage (slow/stuck) verdicts all bite")
