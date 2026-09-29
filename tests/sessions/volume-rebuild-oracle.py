#!/usr/bin/env python3
"""U1 oracle for `firmwarekit mount` (docs/filesystem-f0-findings.md): what the guest reports, for comparison
with the volumes FirmwareKit rebuilds offline from base + overlay.

    tests/sessions/volume-rebuild-oracle.py --device IPAD_DEVICE --out OUT [--ipa IPA ...] [--kill]

IPAD_DEVICE is a qemu-ios `imgtools/device.py create` output (nand/, kboot.bin, device.lock.json); it is
only read. One boot on a fresh overlay OUT/overlay, -audio driver=none, usbmuxd-qemu as the USB host:
  1. AFC: push files of awkward sizes (1 B .. 24 MiB) and 100 small ones, then overwrite one and delete two,
     so the FTL holds stale copies of live pages;
  2. install each IPA (ideviceinstaller), and check it is listed;
  3. AFC walk: `afcclient get -r /` of /var/mobile/Media into OUT/afc;
  4. shut down cleanly (QMP system_powerdown, QEMU exit 0), or with --kill SIGKILL QEMU 40 s after the writes.
OUT/guest.json then names base, overlay, clean, every walked file's size + sha256 (data-volume paths,
"mobile/Media/..."), the deleted paths and the IPAs. Check it with
    FK_U1=OUT swift test --filter VolumeRebuildTests      (Packages/FirmwareKit)
Runs in the foreground; everything it starts is stopped before it returns.
"""
import argparse, hashlib, importlib.util, json, os, random, shutil, signal, subprocess, sys, time, zipfile

HOME = os.path.expanduser("~")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def push(a, b, src, guest, say):
    """Steps 1 (skipped with --walk-only) and 2."""
    os.makedirs(src, exist_ok=True)
    if a.walk_only:
        return install(a, b, guest, say)
    rnd = random.Random(1)
    sizes = {"odd-%d.bin" % n: n for n in (1, 4095, 4097, 65537, (1 << 20) + 3, (8 << 20) + 5, (24 << 20) + 7)}
    sizes.update({"small/s%03d.txt" % i: rnd.randrange(10, 9000) for i in range(100)})
    b.run(["afcclient", "mkdir", "/u1"]); b.run(["afcclient", "mkdir", "/u1/small"])
    for name, n in sizes.items():
        p = os.path.join(src, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(rnd.randbytes(n))
        r = b.run(["afcclient", "put", p, "/u1/" + name], timeout=300)
        if r.returncode:
            sys.exit("afc put %s: %s" % (name, r.stdout + r.stderr))
    with open(os.path.join(src, "odd-65537.bin"), "wb") as f:     # overwrite: a newer copy of live pages
        f.write(rnd.randbytes(70001))
    r = b.run(["afcclient", "--", "put", "-f", os.path.join(src, "odd-65537.bin"), "/u1/odd-65537.bin"], timeout=120)
    if r.returncode:
        sys.exit("afc overwrite: %s" % (r.stdout + r.stderr))
    for name in ("small/s000.txt", "odd-4097.bin"):
        b.run(["afcclient", "rm", "/u1/" + name])
        guest["deleted"].append("mobile/Media/u1/" + name)
    say("pushed %d files" % len(sizes))
    install(a, b, guest, say)


def install(a, b, guest, say):
    for ipa in a.ipa:
        with zipfile.ZipFile(ipa) as z:
            app = next(n.split("/")[1] for n in z.namelist() if n.startswith("Payload/") and n.split("/")[1].endswith(".app"))
        r = b.run(["ideviceinstaller", "install", ipa], timeout=300)
        listed = b.run(["ideviceinstaller", "list"], timeout=90).stdout
        say("install %s: %s" % (app, (r.stdout + r.stderr).strip().splitlines()[-1:] or "?"))
        if "Complete" in r.stdout + r.stderr:
            guest["ipas"].append({"ipa": os.path.abspath(ipa), "app": app, "listed": listed})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ipa", action="append", default=[])
    ap.add_argument("--kill", action="store_true", help="SIGKILL QEMU instead of a clean shutdown")
    ap.add_argument("--walk-only", action="store_true", help="boot OUT's overlay again: no pushes (--ipa still installs)")
    ap.add_argument("--qemu-ios", default=str(sources.path("qemu-ios")))
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    spec = importlib.util.spec_from_file_location("rg", os.path.join(a.qemu_ios, "tests/ipad1/regress.py"))
    rg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rg)
    rg.ipod.START = time.time()      # its log() clock
    cfg = argparse.Namespace(out=out, kboot=None, nand=None, qemu=os.path.join(a.qemu_ios, "build/qemu-system-arm"),
                             usbmuxd=a.usbmuxd, boot_timeout=590, device=os.path.abspath(a.device), product_version=None)
    rg.device_args(cfg)
    overlay = os.path.join(out, "overlay")
    b = rg.Boot(cfg, "u1", overlay=overlay, usb=True)
    t0 = time.time()
    say = lambda s: print("[%5.0fs] %s" % (time.time() - t0, s), flush=True)
    guest = {"base": os.path.realpath(cfg.nand), "overlay": overlay, "product_version": cfg.product_version,
             "clean": False, "deleted": [], "ipas": [], "files": {}, "walk_errors": []}
    if a.walk_only:
        guest.update(json.load(open(os.path.join(out, "guest.json"))), files={}, walk_errors=[], clean=False)
        guest["ipas"] = [i for i in guest["ipas"] if i["ipa"] not in map(os.path.abspath, a.ipa)]
    try:
        b.start()
        if not b.wait_mux():
            sys.exit("usbmux never attached")
        for _ in range(30):
            if b.run(["ideviceinfo", "-k", "ProductVersion"]).returncode == 0:
                break
            time.sleep(3)
        say("usbmux up")
        src = os.path.join(out, "push")
        push(a, b, src, guest, say)
        walk = os.path.join(out, "afc")
        shutil.rmtree(walk, ignore_errors=True)
        os.makedirs(walk)
        top = [n for n in b.run(["afcclient", "ls", "/"]).stdout.splitlines() if n not in ("", ".", "..")]
        for name in top:
            r = b.run(["afcclient", "--", "get", "-r", "/" + name, os.path.join(walk, name)], timeout=300)
            if r.returncode:
                guest["walk_errors"].append("%s: exit %d %s" % (name, r.returncode, (r.stdout + r.stderr).strip()[-200:]))
        for dp, _, fs in os.walk(walk):
            for f in fs:
                p = os.path.join(dp, f)
                if os.path.islink(p):
                    continue
                rel = os.path.relpath(p, walk)
                guest["files"]["mobile/Media/" + rel] = {"size": os.path.getsize(p), "sha256": sha256(p)}
        say("AFC walk: %d files under %s; errors %s" % (len(guest["files"]), top, guest["walk_errors"]))
        pushed = {os.path.relpath(os.path.join(dp, f), src): sha256(os.path.join(dp, f)) for dp, _, fs in os.walk(src) for f in fs}
        pushed = {n: h for n, h in pushed.items() if "mobile/Media/u1/" + n not in guest["deleted"]}
        bad = [n for n, h in pushed.items() if guest["files"].get("mobile/Media/u1/" + n, {}).get("sha256") != h]
        say("guest returns %d/%d pushed files intact" % (len(pushed) - len(bad), len(pushed)))
        if a.kill:
            time.sleep(40)
            os.killpg(b.qemu.pid, signal.SIGKILL)     # the timeout wrapper and QEMU (own session)
            b.qemu.wait(timeout=30)
            say("QEMU killed")
        else:
            try:
                b.qmp.cmd("system_powerdown")
            except Exception:
                pass
            try:
                rc = b.qemu.wait(timeout=120)
            except subprocess.TimeoutExpired:
                rc = None
            guest["clean"] = rc == 0
            say("system_powerdown: QEMU exit %s" % rc)
    finally:
        b.stop()
        json.dump(guest, open(os.path.join(out, "guest.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
