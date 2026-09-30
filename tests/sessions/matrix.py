#!/usr/bin/env python3
"""The device × firmware matrix (docs/matrix.md), run through the app's own pipeline.

For each catalog entry: the IPSW is fetched into the app's content-addressed download cache if it isn't there
(resumable; sha1 checked), its keys are verified against the IPSW (firmwarekit verify-keys), `firmwarekit create`
runs exactly as the app runs it (--entry/--ipsw/--out/--seed/--helper/--cache, the guest tools), and the result
boots through tests/drivers/session-driver --single as the app boots a device: lit, lockdown (ProductType, ActivationState),
AFC round trips, the IPA install (Harness.ipa) when the entry enables appsync, the guest-package report when an
itpack is at hand, a clean shutdown, then a second boot on the same overlay that must still hold a file uploaded
before it (persist). GL counters are recorded when the emulator exposes them (qemu-ios gl-coverage), else skipped.
--restore additionally runs qemu-ios tests/ipad1/restore-smoke.py on prepared iPads.

    tests/matrix.py --guest-tools DIR --dylib PATH [--device iPad1,1] [--build 7B405 ...] [--status untested]
                    [--only-new] [--rerun] [--seed-ipsws FILE ...] [--activation-hook PATH] [--restore ...]

Results: docs/matrix-results.json (one record per entry) and docs/matrix-results.md, rewritten after every entry;
an entry with a record is skipped unless --rerun. Screenshots go under --results-dir (outside the repo), path in
the JSON. One emulator at a time; every boot -audio driver=none; the prepared device and every clone live in
--scratch and are deleted when the entry is done, so only the IPSW cache and the results remain.
Run in the foreground; the driver's processes are gone when an entry returns.
"""
import argparse, fcntl, hashlib, importlib.util, json, os, re, shutil, signal, subprocess, sys, tempfile, time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
CATALOG = ROOT / "LightTouchMac/Resources/firmware-catalog.json"
RESULTS_JSON, RESULTS_MD = ROOT / "docs/matrix-results.json", ROOT / "docs/matrix-results.md"
APP_CACHE = HOME / "Library/Caches/gold.samhenri.LightTouchMac"   # IPSWStore.cachesDirectory
FIRMWAREKIT = ROOT / "Packages/FirmwareKit/.build/release/firmwarekit"
PATCHER = HOME / "Downloads/Legacy-iOS-Kit_complete_v25.09.01/bin/macos/arm64/iBoot32Patcher"
# The brief's order: the six existing entries first, then the new ones nearest a working build outward.
ORDER = ["n72ap-7E18", "n72ap-8C148", "n72ap-5F138", "k48ap-7B500", "k48ap-7B367", "k48ap-8C148",
         "n72ap-7A341", "n72ap-7C145", "n72ap-7D11", "k48ap-7B405", "n72ap-8A293", "n72ap-8A400", "n72ap-8B117",
         "n72ap-5G77a", "n72ap-5H11a", "k48ap-8F190", "k48ap-8G4", "k48ap-8H7", "k48ap-8J3", "k48ap-8K2", "k48ap-8L1"]
CHECKS = ["prepare", "lit", "home", "lockdown", "activation", "afc", "install", "package", "helpers", "gl", "persist", "shutdown"]
USB_ETHERNET = "USB Ethernet (it_ethlink, en1 pinned by IOPathMatch)"   # FirmwareKit FitCheck.usbEthernet's piece

spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
check_sessions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_sessions)

fspec = importlib.util.spec_from_file_location("framecheck", ROOT / "tests/sessions/framecheck.py")
framecheck = importlib.util.module_from_spec(fspec)
fspec.loader.exec_module(framecheck)
MATRIX_REFS = ROOT / "tests/sessions/matrix-refs"   # per-entry known-good home pictures, if committed
HOME_FLOOR = 0.05   # a home screenshot below this luma is a slept/black panel (audit finding 3)
SPRINGBOARD = "com.apple.springboard"


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while chunk := f.read(4 << 20):
            h.update(chunk)
    return h.hexdigest()


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


def rmtree(path):
    """A prepared base is read-only (the seal); make it deletable first."""
    if path.exists():
        subprocess.run(["chmod", "-R", "u+w", path], check=False)
        shutil.rmtree(path, ignore_errors=True)


def fetch_ipsw(entry, cache, seeds):
    """The IPSW in the app's download store (<sha1>.ipsw), from a seed file or Apple's URL; None with the reason."""
    src = entry["source"]
    sha, want = src["sha1"], cache / f"{src['sha1']}.ipsw"
    if want.exists():
        return want, None
    cache.mkdir(parents=True, exist_ok=True)
    if sha in seeds:
        log(f"  ipsw: cloning {seeds[sha]}")
        if subprocess.run(["cp", "-c", seeds[sha], want], capture_output=True).returncode:
            shutil.copyfile(seeds[sha], want)
        return want, None
    if not src.get("url"):
        return None, f"no IPSW: {entry['status']} entry without a URL; put {sha}.ipsw in {cache} or pass --seed-ipsws"
    partial = cache / f"{sha}.partial"
    log(f"  ipsw: downloading {src['url']} ({src['bytes']:,} bytes)")
    for attempt in range(1, 6):
        r = subprocess.run(["curl", "-L", "-sS", "-C", "-", "--retry", "5", "--retry-all-errors", "-o", partial, src["url"]],
                           capture_output=True, text=True)
        if r.returncode == 0 and partial.exists() and partial.stat().st_size == src["bytes"]:
            break
        log(f"  ipsw: attempt {attempt} failed ({r.stderr.strip()[:200]}); resuming")
        time.sleep(5)
    else:
        return None, "download failed after 5 attempts"
    got = sha1(partial)
    if got != sha:
        partial.unlink(missing_ok=True)
        return None, f"downloaded sha1 {got}, catalog pins {sha}"
    partial.rename(want)
    return want, None


def verify_keys(entry_file, ipsw, firmwarekit):
    r = subprocess.run([firmwarekit, "verify-keys", "--entry", entry_file, "--ipsw", ipsw], capture_output=True, text=True, timeout=900)
    lines = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
    bad = [f"{l['component']} ({l['why']})" for l in lines if "component" in l and not l["ok"]]
    return {"total": len([l for l in lines if "component" in l]), "ok": len([l for l in lines if l.get("ok")]),
            "bad": ", ".join(bad), "error": next((l["error"] for l in lines if "error" in l), None)}


def prepare(entry, entry_file, ipsw, out, a, helper, env):
    cmd = [a.firmwarekit, "create", "--entry", entry_file, "--ipsw", ipsw, "--out", out, "--seed", f"matrix-{entry['id']}",
           "--helper", helper, "--cache", a.scratch / "cache", "--guest-tools", a.guest_tools]
    if a.activation_hook:   # opt-in, forwarded verbatim
        cmd += ["--activation-hook", a.activation_hook]
    if sibling := (entry.get("recipe") or {}).get("keybag_ramdisk_from"):   # its restore ramdisk boots the keybag one-shot
        sib = next(e for e in a.catalog["entries"] if e["id"] == sibling)
        sib_ipsw, why = fetch_ipsw(sib, a.ipsw_cache, a.seeds)
        if not sib_ipsw:
            raise RuntimeError(f"keybag_ramdisk_from {sibling}: {why}")
        sib_file = out.parent / "sibling.json"
        sib_file.write_text(json.dumps(sib))
        cmd += ["--sibling-entry", sib_file, "--sibling-ipsw", sib_ipsw]
    out.mkdir(parents=True, exist_ok=True)
    (a.scratch / "cache").mkdir(parents=True, exist_ok=True)
    stderr = out.parent / "firmwarekit.log"
    started = time.monotonic()
    with open(stderr, "w") as err:
        try:
            r = subprocess.run(list(map(str, cmd)), stdout=subprocess.PIPE, stderr=err, text=True, timeout=a.prepare_timeout, env=env)
            code = r.returncode
            events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        except subprocess.TimeoutExpired as e:
            code, events = -1, [json.loads(l) for l in (e.stdout or b"").decode().splitlines() if l.strip()]
            events.append({"event": "error", "code": "timeout", "message": f"firmwarekit ran past {a.prepare_timeout} s"})
    seconds = time.monotonic() - started
    last = events[-1] if events else {"event": "error", "code": "internal", "message": f"no events (exit {code})"}
    steps = [e["name"] for e in events if e["event"] == "step"]
    rec = {"seconds": round(seconds, 1), "ok": last["event"] == "done" and code == 0, "steps": steps,
           "warnings": [e["message"] for e in events if e["event"] == "warning"],
           "error": None if last["event"] == "done" else f"{last.get('code')}: {last.get('message')}",
           "last_step": steps[-1] if steps else None, "log": str(stderr)}
    if rec["ok"]:
        lock = json.loads((out / "device.lock.json").read_text())
        derived = lock.get("derived", {})
        rec["lock"] = {"boot_strategy": lock.get("boot_strategy"), "gles": derived.get("gles"), "gli": derived.get("gli"),
                       "guest_package": (lock.get("guest_package") or {}).get("family") if isinstance(lock.get("guest_package"), dict) else None,
                       "activation": bool((lock.get("inputs") or {}).get("activation")), "kernel": derived.get("kernel")}
    return rec, stderr


def excerpt(path, n=3):
    """The last few telling lines of a log: panics and errors near the end, else the tail."""
    try:
        lines = [l.rstrip() for l in Path(path).read_text(errors="replace").splitlines() if l.strip()]
    except OSError:
        return ""
    hot = [l for l in lines[-400:] if re.search(r"panic|error|fail|refus|not valid|timed out|Timeout|abort|fault", l, re.I)]
    pick = (hot or lines)[-n:]
    # iBoot's serial lines start with a NUL; one in the markdown makes git treat the file as binary.
    return "\n".join(re.sub(r"[\x00-\x08\x0e-\x1f]", "", l)[:200] for l in pick)


def boot(entry, base, a, helper, work, env):
    """tests/drivers/session-driver --single with reboot; returns the parsed events, the driver's exit and the serial log."""
    board = {"k48ap": "ipad", "n45ap": "ipod1g"}.get(entry["board"], "ipod")
    nand_current = a.files / "nand-current"
    cfg = {"helper": str(helper), "requirement": check_sessions.TEAM_REQ, "usbmuxd": str(a.usbmuxd), "ipa": str(a.ipa),
           "bundleID": a.bundle_id, "work": str(work), "files": str(a.files),
           "ipodNAND": str(a.files / os.readlink(nand_current)) if nand_current.is_symlink() else "",
           "ipadBase": str(base) if board == "ipad" else "", "timeout": a.boot_timeout - 20,
           "single": {"board": board, "base": str(base), "reboot": True, "lockdownTZ": str(a.lockdown_tz),
                      "install": (entry.get("recipe") or {}).get("options", {}).get("appsync", False), "launch": a.launch,
                      **({"launchAt": [float(v) for v in a.launch_at.split(",")]} if a.launch_at else {})}}
    if a.frameworks:
        cfg["frameworks"] = str(a.frameworks)
    itpack = a.guest_tools / ("armv7.itpack" if board == "ipad" else "armv6.itpack")
    if itpack.exists():
        if board == "ipad":
            cfg["ipadItpack"] = str(itpack)
        else:
            cfg["single"]["itpack"] = str(itpack)
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    try:
        driver.wait(timeout=a.boot_timeout)
    except subprocess.TimeoutExpired:
        driver.kill()
        driver.wait()
    events = []
    for line in (work / "driver.jsonl").read_text(errors="replace").splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            events.append({"event": "text", "text": line})
    pids = {e["pid"] for e in events if e.get("event") in ("hello", "booted", "usbmuxd") and e.get("pid")}
    if (work / "pids").exists():
        pids |= {int(x) for x in (work / "pids").read_text().split()}
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    return events, driver.returncode, work / board / "serial.log", work / board


def judge(entry, events, rc, serial, shots_from, shots_to, base_before, base):
    """The check verdicts from the driver's events (each ok/fail with a note), plus the first failure's excerpt."""
    def find(name, **m):
        return [e for e in events if e.get("event") == name and all(e.get(k) == v for k, v in m.items())]
    appsync = (entry.get("recipe") or {}).get("options", {}).get("appsync", False)
    r = {}
    lit = find("lit")
    r["lit"] = {"ok": bool(lit), "seconds": round(lit[0]["seconds"], 1) if lit else None}
    if setup := find("setup"):   # a fresh 5.x iPad's Setup Assistant, walked by the driver (single.swift Setup5)
        r["lit"]["setup"] = {"ok": setup[0].get("ok"), "detail": setup[0].get("detail"), "frontmost": setup[0].get("frontmost")}
    # home (audit gap #2): judge the home screen, not a slept boot. Every home/installed screenshot
    # must be lit (not brightness 0), SpringBoard must be frontmost where an agent can say so, and
    # where a known-good reference is committed the picture must match it (framecheck). Boot 2's home
    # is judged the same way. This fails the 4.x iPad rows whose boot-1 home is captured black
    # (audit finding 3), which the single `lit` threshold passed.
    shots_ev = {Path(e["path"]).stem: e for e in find("screenshot")}
    homes = find("home")
    home_names = [n for n in ("home", "home2", "installed") if n in shots_ev]
    dark = [n for n in home_names if float(shots_ev[n].get("brightness", 0)) < HOME_FLOOR]
    wrong_app = [h.get("frontmost") for h in homes if h.get("frontmost") and h["frontmost"] != SPRINGBOARD]
    frame = {}
    for n in home_names:
        ref = MATRIX_REFS / f"{entry['id']}-{n}.png"
        if ref.exists():
            frame[n] = framecheck.verdict(shots_ev[n]["path"], str(ref))
    bad_frame = [n for n, v in frame.items() if not v["ok"]]
    if not home_names:
        r["home"] = {"ok": None, "note": "no home screenshot taken"}
    else:
        r["home"] = {"ok": not dark and not wrong_app and not bad_frame,
                     "brightness": {n: round(float(shots_ev[n].get("brightness", -1)), 3) for n in home_names},
                     "frontmost": [h.get("frontmost", "") for h in homes] or None,
                     "dark": dark or None, "wrongApp": wrong_app or None,
                     "frame": {n: frame[n]["frac"] for n in frame} or None}
    usb = find("usb")
    want = entry["product_type"]
    r["lockdown"] = {"ok": bool(usb) and usb[0].get("productType") == want, "seconds": round(usb[0]["seconds"], 1) if usb else None,
                     "productType": usb[0].get("productType") if usb else None}
    act = find("activation")
    r["activation"] = {"ok": bool(act) and act[0].get("state") == "Activated", "state": act[0].get("state") if act else None}
    afc = find("afc")
    r["afc"] = {"ok": len(afc) >= 4 and all(x.get("same") and x.get("listed") == x["bytes"] for x in afc),
                "sizes": [x["bytes"] for x in afc if x.get("same")], "error": next((x.get("error") for x in afc if not x.get("same")), None)}
    inst = find("installed")
    if appsync:
        r["install"] = {"ok": bool(inst) and inst[0].get("has"), "seconds": round(inst[0]["seconds"]) if inst else None,
                        "attempt": inst[0].get("attempt") if inst else None,
                        "apps": [x for x in (inst[0].get("apps") or []) if not x.startswith("com.apple.")] if inst else None}
        if launched := find("launched"):   # --launch: the launched1-3 screenshots are the evidence
            r["install"]["launch"] = {k: v for k, v in launched[0].items() if k not in ("event", "t", "device")}
    else:
        r["install"] = {"ok": None, "note": "appsync off"}
    pkg = find("guestPackage", generation=1)
    offer = [o for o in find("offer") if o.get("serial", -1) >= 0]
    if find("offer") and not offer:
        r["package"] = {"ok": None, "note": "itpack has no package for this build (GuestPackage.compose: nil)"}
    elif offer:
        r["package"] = {"ok": bool(pkg) and pkg[0].get("result", -99) >= 0 and pkg[0].get("serial") == offer[0].get("serial"),
                        "offered": offer[0].get("serial"), "reported": pkg[0].get("serial") if pkg else None,
                        "result": pkg[0].get("result") if pkg else None}
    else:
        r["package"] = {"ok": None, "note": "no offer (no itpack or nothing for this build)"}
    lock = json.loads((base / "device.lock.json").read_text())
    gp = lock.get("guest_package") or {}
    if not gp:   # 3.0: no loader baked
        r["package"] = {"ok": None, "note": "no loader baked (the lock has no guest_package)"}
    elif not offer and r["package"].get("ok") is None:
        # a loader was baked but never heard from: a seed with jobs or hooks is a package it must report on, so the
        # missing report fails; a stub seed (n72-ios4: nothing to load) has nothing to report, which is not a pass
        if gp.get("jobs") or gp.get("hooks"):
            r["package"] = {"ok": False, "note": f"loader baked with {gp.get('family')} (jobs/hooks) but the host offered nothing, so it never reported"}
        else:
            r["package"] = {"ok": None, "note": f"stub seed {gp.get('family')} (no jobs, no hooks): nothing for the loader to run or report"}
    # helpers (docs/fidelity-ledger.md "Fit checks", the boot side): what the prepare baked must answer. The guest
    # agent wherever the lock has it (the seed's it-agent job, or the iPod bake's installed tools): some home event
    # names the frontmost app through it. On the iPad (its console is the serial) it_ethlink watching its service
    # where the prepare proved USB Ethernet fits, and it_prefs having run, where the seed has their jobs.
    serial_text = serial.read_text(errors="replace") if serial.exists() else ""
    jobs = gp.get("jobs") or []
    fits = {f.get("piece"): f.get("fits") for f in lock.get("fit") or []}
    helpers = {}
    if "com.qemu.it-agent.plist" in jobs or str((lock.get("derived") or {}).get("guest_tools", "")).startswith("installed"):
        helpers["agent"] = any(h.get("frontmost") for h in homes)
    if entry["board"] == "k48ap":
        if "com.qemu.it-ethlink.plist" in jobs and fits.get(USB_ETHERNET):
            helpers["ethlink"] = "it_ethlink: watching AppleUSBEthernetDevice" in serial_text
        if "com.qemu.it-prefs.plist" in jobs:
            helpers["prefs"] = "it_prefs: " in serial_text
    r["helpers"] = ({"ok": all(helpers.values()), **helpers, "silent": [k for k, v in helpers.items() if not v] or None} if helpers
                    else {"ok": None, "note": "no guest helpers baked"})
    # gl (audit gap #1/#2: this column was a hard-coded skip). The matrix boots with GL on, so its
    # home/installed screenshots ARE GL output -- a black/slept or wrong picture already fails `home`
    # above (and the framecheck diff there is the frame reference). Here we also record the render
    # path and refusals. Where the pipeline installed the GL shim (the lock's built GLEngine on k48,
    # derived.gles_shim on n72), the shim giving up on GL ("[glishim] ...: no GL", 4.3.x's "no gldshim
    # device") is a FAIL: software CoreAnimation still draws a correct home screen, so the pictures
    # cannot tell, and that fallback is the hollow pass the 09-29 test audit warned about.
    serial_text = serial.read_text(errors="replace") if serial.exists() else ""
    sw_fallback = bool(re.search(r"\[glishim\][^\n]*: no GL\r?$|no gldshim device", serial_text, re.M))
    gl_rejects = len(re.findall(r"unsupported graphics hardware|gl[ie]s?[-_ ]?reject", serial_text, re.I))
    lock = json.loads((base / "device.lock.json").read_text())
    shim = bool(((lock.get("tool") or {}).get("built") or {}).get("GLEngine") or (lock.get("derived") or {}).get("gles_shim"))
    home_ok = r["home"].get("ok")
    r["gl"] = {"ok": False if shim and sw_fallback else (bool(home_ok) and gl_rejects == 0) if home_ok is not None else None,
               "path": "software CA (no gldshim device)" if sw_fallback else "hardware GL",
               "shim": shim, "gld_registered": serial_text.count("[glishim] gld plugin registered"),
               "rejects": gl_rejects,
               "picture": {n: frame[n]["frac"] for n in frame} or None,
               "note": (("the GL shim is installed but fell back to software CoreAnimation (no gldshim device, no GL)"
                         if shim else "software-composited: the pipeline installed no GL shim") if sw_fallback else
                        (None if home_ok is not None else "no home screenshot to judge"))}
    per = find("persist")
    r["persist"] = {"ok": bool(per) and per[0].get("kept") and per[0].get("same"), "error": per[0].get("error") if per else None}
    lit2, usb2 = find("lit"), find("usb")
    r["persist"]["second_boot"] = {"lit": round(lit2[1]["seconds"], 1) if len(lit2) > 1 else None,
                                   "lockdown": round(usb2[1]["seconds"], 1) if len(usb2) > 1 else None}
    if ra := find("restartedApps"):   # audit gap #2: the reboot's app list, previously ignored
        r["persist"]["restartedApps"] = ra[0].get("has")
    # shutdown: judge boot 2's clean power-off too (audit gap #2 / finding 4: 8L1's boot-2 stalls and
    # the matrix judged only boot 1). If a second boot ran, its quit must confirm PMU standby / exit.
    quits = find("quit")
    q = quits[0] if quits else {}
    did_boot2 = len(find("lit")) > 1
    q2 = quits[1] if len(quits) > 1 else {}
    def _clean(qq):
        return qq.get("confirmed", -1) >= 0 and qq.get("exited") and str(qq.get("reason")).endswith(" stopped.")
    first_ok = bool(quits) and _clean(q)
    second_ok = _clean(q2)
    r["shutdown"] = {"ok": first_ok and (second_ok if did_boot2 else True),
                     "seconds": round(q["confirmed"], 1) if q.get("confirmed", -1) >= 0 else None, "reason": q.get("reason"),
                     "second": (round(q2["confirmed"], 1) if q2.get("confirmed", -1) >= 0 else None),
                     "second_ok": (second_ok if did_boot2 else None), "boot2_reason": q2.get("reason") if did_boot2 else None}
    r["base_unchanged"] = check_sessions.tree(base) == base_before
    r["driver_exit"] = rc
    fails = find("fail")
    if fails:
        r["driver_fail"] = fails[0]["why"]
    shots = {}
    shots_to.mkdir(parents=True, exist_ok=True)
    for e in find("screenshot"):
        dst = shots_to / Path(e["path"]).name
        shutil.copyfile(e["path"], dst)
        shots[Path(e["path"]).stem] = str(dst)
    if (shots_from / "native.log").exists():
        shutil.copyfile(shots_from / "native.log", shots_to / "native.log")
    if serial.exists():
        shutil.copyfile(serial, shots_to / "serial.log")
    first = next((c for c in CHECKS if c in r and r[c].get("ok") is False), None)
    return r, shots, first


def restore(entry, base, ipsw, a, out):
    cmd = [sys.executable, a.qemu_ios / "tests/ipad1/restore-smoke.py", "--device", base, "--ipsw", ipsw, "--rom", a.restore_rom,
           "--libirecovery", a.restore_libirecovery, "--qemu", a.qemu_ios / "build/qemu-system-arm", "--out", out / "restore"]
    started = time.monotonic()
    r = subprocess.run(list(map(str, cmd)), capture_output=True, text=True, timeout=1200)
    (out / "restore.log").write_text(r.stdout + r.stderr)
    return {"ok": r.returncode == 0, "seconds": round(time.monotonic() - started), "log": str(out / "restore.log")}


def write_md(results, catalog):
    order = {e["id"]: i for i, e in enumerate(catalog["entries"])}
    rows = []
    for eid in sorted(results, key=lambda k: order.get(k, 999)):
        r = results[eid]
        c = r.get("checks", {})

        def cell(name):
            v = c.get(name)
            if v is None:
                return "-"
            if v.get("ok") is None:
                return f"skip ({v.get('note', '')})"
            extra = {"lit": lambda: f" {v['seconds']} s" if v.get("seconds") is not None else "",
                     "home": lambda: (" black:" + ",".join(v["dark"]) if v.get("dark") else
                                      " wrong-app" if v.get("wrongApp") else
                                      " picture off" if not v["ok"] else ""),
                     "lockdown": lambda: f" {v['seconds']} s" if v.get("seconds") is not None else "",
                     "activation": lambda: f" {v.get('state') or '?'}",
                     "afc": lambda: f" {len(v.get('sizes', []))}/4",
                     "install": lambda: f" {v['seconds']} s" if v.get("seconds") is not None else "",
                     "package": lambda: f" serial {v.get('reported')} r{v.get('result')}" if v.get("ok") or v.get("offered") is not None else f" ({v.get('note', '')})",
                     "helpers": lambda: " " + ",".join(k for k in ("agent", "ethlink", "prefs") if k in v) + (f" (silent: {','.join(v['silent'])})" if v.get("silent") else ""),
                     "persist": lambda: f" (boot 2 lit {v.get('second_boot', {}).get('lit')} s)" if v.get("ok") else "",
                     "shutdown": lambda: (f" {v['seconds']} s" if v.get("seconds") is not None else "")
                                         + (f" (boot 2 {v['second']} s)" if v.get("second") is not None else
                                            " (boot 2 unconfirmed)" if v.get("second_ok") is False else ""),
                     "gl": lambda: f" ({v.get('path', '')}"
                                   + (f", {v['rejects']} rejects" if v.get("rejects") else "")
                                   + (f"; {v['note']}" if v.get("note") else "") + ")"}.get(name, lambda: "")()
            return ("ok" if v["ok"] else "FAIL") + extra
        prep = r.get("prepare") or {}
        ptxt = "-" if not prep else (f"ok {prep['seconds']} s" if prep.get("ok") else f"FAIL {prep.get('seconds', 0)} s")
        if r.get("skipped"):
            ptxt = f"skip: {r['skipped']}"
        keys = r.get("keys") or {}
        ktxt = f"{keys.get('ok', 0)}/{keys.get('total', 0)}" + (f" ({keys['bad']})" if keys.get("bad") else "") if keys else "-"
        ff = r.get("first_failure") or {}
        fftxt = ""
        if ff:
            fftxt = f"**{ff['check']}**: {ff.get('why', '')}".replace("|", "\\|").replace("\n", " ")  # a multi-line error (a tool's output) stays in its cell
            if ff.get("excerpt"):
                fftxt += "<br>" + "<br>".join("`" + l.replace("`", "'").replace("|", "\\|") + "`" for l in ff["excerpt"].splitlines())
        rows.append(f"| {eid} | {r.get('version', '')} | {ktxt} | {ptxt} | {cell('lit')} | {cell('home')} | {cell('lockdown')} | {cell('activation')} | "
                    f"{cell('afc')} | {cell('install')} | {cell('package')} | {cell('helpers')} | {cell('gl')} | {cell('persist')} | {cell('shutdown')} | "
                    f"{r.get('restore', {}).get('ok', '-') if r.get('restore') else '-'} | {fftxt} |")
    RESULTS_MD.write_text(f"""# Matrix results

Produced by `tests/matrix.py` (docs/matrix.md has the builds). Prepare = `firmwarekit create` as the app runs it; lit,
lockdown, AFC, install, package, persist and shutdown come from tests/drivers/session-driver `--single` with a second boot on
the same overlay. Screenshots and logs per entry are outside the repo (`screenshots` in matrix-results.json).
Home judges the home screen itself (audit gap #2): every home/installed screenshot lit (not brightness 0), SpringBoard
frontmost where an agent can say, and the picture against a committed reference where one exists. GL records the render
path (hardware GL vs a software-composited fallback), any refusals, and the frame-reference verdict -- it no longer
skips. Shutdown judges boot 2's clean power-off as well as boot 1. Helpers: what the prepare baked answers at boot (the
agent names the frontmost app; on the iPad it_ethlink and it_prefs report on the console), per the lock's seed and fit
checks; a loader baked with a package that never reports fails Package. Last write {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}.

| Entry | iOS | Keys | Prepare | Lit | Home | Lockdown | Activation | AFC | Install | Package | Helpers | GL | Persist | Shutdown | Restore | First failure |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
{chr(10).join(rows)}

## Triage

(a) a generic pipeline/emulator fix, (b) per-build data for the catalog entry, (c) real emulator or guest-tool work.
Set with `tests/matrix.py --triage ENTRY "text"`.

{chr(10).join(f"- **{eid}**: {results[eid]['triage']}" for eid in sorted(results, key=lambda k: order.get(k, 999)) if results[eid].get("triage")) or "(none yet)"}
""")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--device", help="iPad1,1 or iPod2,1")
    ap.add_argument("--build", nargs="*", help="build ids, e.g. 7B405")
    ap.add_argument("--status", help="catalog status, e.g. untested")
    ap.add_argument("--only-new", action="store_true", help="entries with status untested")
    ap.add_argument("--rerun", action="store_true", help="run entries that already have a result")
    ap.add_argument("--seed-ipsws", nargs="*", type=Path, default=[], help="local IPSWs to clone into the cache by sha1")
    ap.add_argument("--activation-hook", help="forwarded verbatim to firmwarekit create (opt-in)")
    ap.add_argument("--restore", action="store_true", help="also run restore-smoke.py on prepared iPads")
    ap.add_argument("--restore-rom", type=Path, help="--restore: the SecureROM image")
    ap.add_argument("--restore-libirecovery", type=Path, help="--restore: the libirecovery adapter build dir")
    ap.add_argument("--ipsw-cache", type=Path, default=APP_CACHE / "IPSW", help="the app's download store")
    ap.add_argument("--firmwarekit", type=Path, default=FIRMWAREKIT)
    ap.add_argument("--guest-tools", type=Path, default=os.environ.get("LTM_GUEST_TOOLS_DIR"), help="the flat firmwarekit guest-tools dir (with the itpacks)")
    ap.add_argument("--helper", type=Path, help="LightTouchDevice (default: build the Debug target)")
    ap.add_argument("--dylib", type=Path, default=os.environ.get("LTM_QEMU_DYLIB"), help="libqemu-arm.dylib the helper loads")
    ap.add_argument("--usbmuxd", type=Path, default=sources.path("usbmuxd") / "src/usbmuxd")
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--ipa", type=Path, default=sources.path("qemu-ios") / "contrib/it-harness/build/Harness.ipa")
    ap.add_argument("--bundle-id", default="com.qemuios.harness")
    ap.add_argument("--launch-at", help="--launch on 2.x (no springboardservices): the icon's normalized X,Y")
    ap.add_argument("--launch", action="store_true", help="after the install, open the app from the Home screen (screenshots launched1-3)")
    ap.add_argument("--frameworks", type=Path, help="where libimobiledevice is loaded from (default Homebrew's)")
    ap.add_argument("--qemu-ios", type=Path, default=sources.path("qemu-ios"))
    ap.add_argument("--patcher", type=Path, default=Path(os.environ.get("FIRMWAREKIT_IBOOT_PATCHER", PATCHER)), help="iBoot32Patcher for the k48 recipe")
    ap.add_argument("--results-dir", type=Path, default=HOME / "Developer/qemu-ios-files/matrix-results")
    ap.add_argument("--scratch", type=Path, default=HOME / "Developer/qemu-ios-files/matrix-scratch")
    ap.add_argument("--prepare-timeout", type=int, default=1800)
    ap.add_argument("--boot-timeout", type=int, default=1200)
    ap.add_argument("--build-only", action="store_true", help="build the driver, helper and firmwarekit, then exit")
    ap.add_argument("--triage", nargs=2, metavar=("ENTRY", "TEXT"), help="record a triage note for an entry's result and exit")
    a = ap.parse_args()
    if a.triage:
        catalog = json.loads(CATALOG.read_text())
        results = json.loads(RESULTS_JSON.read_text())
        results[a.triage[0]]["triage"] = a.triage[1]
        RESULTS_JSON.write_text(json.dumps(results, indent=1) + "\n")
        return write_md(results, catalog)
    if not a.guest_tools or not a.guest_tools.is_dir():
        ap.error("--guest-tools DIR (or LTM_GUEST_TOOLS_DIR) is required")
    if not a.dylib or not a.dylib.exists():
        ap.error("--dylib PATH (or LTM_QEMU_DYLIB) is required")
    if a.restore and not (a.restore_rom and a.restore_libirecovery):
        ap.error("--restore needs --restore-rom and --restore-libirecovery")
    catalog = a.catalog = json.loads(CATALOG.read_text())
    results = json.loads(RESULTS_JSON.read_text()) if RESULTS_JSON.exists() else {}
    # One runner at a time: two would share the scratch tools and the results file, and boot two emulators.
    a.scratch.mkdir(parents=True, exist_ok=True)
    lock = open(a.scratch / ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(f"another tests/matrix.py holds {a.scratch}/.lock; wait for it")

    if not a.firmwarekit.exists():
        log("building firmwarekit (release)")
        subprocess.run(["swift", "build", "-c", "release", "--product", "firmwarekit", "--package-path", ROOT / "Packages/FirmwareKit"], check=True)
    a.scratch.mkdir(parents=True, exist_ok=True)
    tools = a.scratch / "tools"
    rmtree(tools)
    tools.mkdir()
    log(f"building the session driver and helper in {tools}")
    helper = check_sessions.build(argparse.Namespace(helper=str(a.helper) if a.helper else None), tools)
    a.lockdown_tz = check_sessions.build_lockdown_tz(tools, a.frameworks)
    if a.build_only:
        return log(f"built: {helper}")

    seeds = a.seeds = {}
    for f in a.seed_ipsws:
        seeds[sha1(f)] = f
        log(f"seed {f.name}: {list(seeds)[-1]}")
    env = dict(os.environ, LTM_QEMU_DYLIB=str(a.dylib), FIRMWAREKIT_IBOOT_PATCHER=str(a.patcher))

    selected = [e for e in catalog["entries"] if (not a.device or e["product_type"] == a.device)
                and (not a.build or e["build"] in a.build) and (not a.status or e["status"] == a.status)
                and (not a.only_new or e["status"] == "untested")]
    selected.sort(key=lambda e: (ORDER.index(e["id"]) if e["id"] in ORDER else 999, e["id"]))
    for entry in selected:
        eid = entry["id"]
        if eid in results and not a.rerun:
            log(f"{eid}: has a result; skipping (--rerun to redo)")
            continue
        log(f"== {eid} (iOS {entry['version']}, {entry['status']})")
        rec = {"version": entry["version"], "board": entry["board"], "status": entry["status"], "when": datetime.now(timezone.utc).isoformat(timespec="seconds"),
               **({"prerelease": entry["prerelease"]} if entry.get("prerelease") else {}),
               "tools": {"firmwarekit": str(a.firmwarekit), "dylib": str(a.dylib), "guest_tools": str(a.guest_tools)}}
        work = a.scratch / eid
        rmtree(work)
        work.mkdir()
        shots = a.results_dir / eid
        rmtree(shots)
        try:
            ipsw, why = fetch_ipsw(entry, a.ipsw_cache, seeds)
            if not ipsw:
                rec["skipped"] = why
                rec["first_failure"] = {"check": "prepare", "why": why}
                continue
            entry_file = work / "entry.json"
            entry_file.write_text(json.dumps(entry))
            rec["keys"] = verify_keys(entry_file, ipsw, a.firmwarekit)
            log(f"  keys: {rec['keys']['ok']}/{rec['keys']['total']} verified" + (f"; bad: {rec['keys']['bad']}" if rec["keys"]["bad"] else ""))
            base = work / "device"
            rec["prepare"], fklog = prepare(entry, entry_file, ipsw, base, a, helper, env)
            log(f"  prepare: {'ok' if rec['prepare']['ok'] else 'FAIL ' + str(rec['prepare']['error'])} in {rec['prepare']['seconds']} s")
            if not rec["prepare"]["ok"]:
                rec["first_failure"] = {"check": "prepare", "why": rec["prepare"]["error"], "excerpt": excerpt(fklog)}
                shots.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(fklog, shots / "firmwarekit.log")
                for l in (base / "work").glob("*.log"):   # the one-shots' serial logs (keybag-N, seal, check)
                    shutil.copyfile(l, shots / l.name)
                continue
            base_before = check_sessions.tree(base)
            drive = work / "boot"
            drive.mkdir()
            for n in ("session-driver",):
                os.symlink(tools / n, drive / n)
            events, rc, serial, shots_from = boot(entry, base, a, helper, drive, env)
            rec["checks"], rec["screenshots"], first = judge(entry, events, rc, serial, shots_from, shots, base_before, base)
            rec["events"] = str(shots / "driver.jsonl")
            shutil.copyfile(drive / "driver.jsonl", shots / "driver.jsonl")
            if first:
                c = rec["checks"][first]
                rec["first_failure"] = {"check": first, "why": rec["checks"].get("driver_fail") or c.get("error") or c.get("reason") or json.dumps(c),
                                        "excerpt": excerpt(serial)}
            for c in CHECKS:
                if c in rec["checks"]:
                    v = rec["checks"][c]
                    log(f"  {c}: {'skip' if v.get('ok') is None else 'ok' if v['ok'] else 'FAIL'} {json.dumps({k: x for k, x in v.items() if k != 'ok'})}")
            if a.restore and entry["board"] == "k48ap":
                rec["restore"] = restore(entry, base, ipsw, a, shots)
                log(f"  restore: {'ok' if rec['restore']['ok'] else 'FAIL'} in {rec['restore']['seconds']} s")
        except Exception as e:   # the runner's own fault, not the build's; still recorded
            rec["runner_error"] = repr(e)
            rec.setdefault("first_failure", {"check": "runner", "why": repr(e)})
            log(f"  runner error: {e!r}")
        finally:
            results[eid] = rec
            RESULTS_JSON.write_text(json.dumps(results, indent=1) + "\n")
            write_md(results, catalog)
            rmtree(work)
            rmtree(a.scratch / "cache" / entry["source"]["sha1"])
            rmtree(a.scratch / "cache" / (entry["source"]["sha1"] + ".tmp"))
            free = shutil.disk_usage(a.scratch).free
            log(f"  recorded; scratch cleaned; {free / 1e9:.0f} GB free")
    rmtree(tools)
    total = sum(f.stat().st_size for f in a.ipsw_cache.glob("*.ipsw")) if a.ipsw_cache.exists() else 0
    log(f"done: {len(results)} results in {RESULTS_MD}; IPSW cache {a.ipsw_cache}: {total / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
