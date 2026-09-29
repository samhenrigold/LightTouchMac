#!/usr/bin/env python3
"""Golden-lock gate for FirmwareKit refactors: `firmwarekit create` every verifiable catalog entry, then diff.

    scripts/lock-identity.py create --firmwarekit BIN --app "Light Touch.app" --out DIR [--entry ID ...]
    scripts/lock-identity.py diff BEFORE_DIR AFTER_DIR

create runs BIN (a built firmwarekit) with the app bundle's helper, guest tools, bootrom and iBoot32Patcher, a
fixed seed and a cache shared by both runs, one entry at a time (the k48 seal and keybag boots are emulator
boots). diff compares, per entry, outputs.nand.built_listing_sha256, the iboot / nor / gid_blobs hashes and
the whole lock minus `created`; exit 1 on any difference. IPSWs are looked up as OracleFixtures.swift does.
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "LightTouchMac/Resources/firmware-catalog.json"
IPSWS = {
    "k48ap-7B500": HOME / "Downloads/ipad1-ios32-feasibility/iPad1,1_3.2.2_7B500_Restore.ipsw",
    "k48ap-7B367": HOME / "Downloads/ipad1-ios32-feasibility/iPad1,1_3.2_7B367_Restore.ipsw",
    "k48ap-8C148": HOME / "Downloads/ipad1-ios32-feasibility/iPad1,1_4.2.1_8C148_Restore.ipsw",
    "n72ap-7E18": HOME / "Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw",
    "n72ap-8C148": HOME / "Downloads/ios4/iPod2,1_4.2.1_8C148_Restore.ipsw",
}
SEED = "lock-identity"


def create(args):
    entries = {e["id"]: e for e in json.loads(CATALOG.read_text())["entries"]}
    app = args.app / "Contents"
    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.cache or args.out.parent / "cache"
    failed = []
    for eid in args.entry or list(IPSWS):
        ipsw = IPSWS[eid]
        if not ipsw.exists():
            print(f"SKIP  {eid}: no IPSW at {ipsw}"); continue
        out = args.out / eid
        if (out / "device.lock.json").exists():
            print(f"KEEP  {eid}: {out}"); continue
        if out.exists():
            subprocess.run(["chmod", "-R", "u+w", out]); subprocess.run(["rm", "-rf", out])
        out.mkdir(parents=True)
        entry = args.out / f"{eid}.json"
        entry.write_text(json.dumps(entries[eid]))
        cmd = [str(args.firmwarekit), "create", "--entry", str(entry), "--ipsw", str(ipsw), "--out", str(out),
               "--seed", SEED, "--helper", str(app / "MacOS/LightTouchDevice"), "--guest-tools", str(app / "Resources/guest-tools"),
               "--cache", str(cache)]
        t0 = time.time()
        with open(args.out / f"{eid}.events", "w") as ev, open(args.out / f"{eid}.stderr", "w") as err:
            r = subprocess.run(cmd, stdout=ev, stderr=err)
        state = "PASS" if r.returncode == 0 and (out / "device.lock.json").exists() else "FAIL"
        if state == "FAIL": failed.append(eid)
        print(f"{state}  {eid}: {time.time() - t0:.0f} s (exit {r.returncode})", flush=True)
    return 1 if failed else 0


def scrub(lock):
    lock = dict(lock)
    lock.pop("created", None)
    return lock


def diff(args):
    bad = 0
    for eid in sorted(p.name for p in args.before.iterdir() if (p / "device.lock.json").exists()):
        b = json.loads((args.before / eid / "device.lock.json").read_text())
        after = args.after / eid / "device.lock.json"
        if not after.exists():
            print(f"MISSING {eid}: no lock in {args.after}"); bad += 1; continue
        a = json.loads(after.read_text())
        keys = [("outputs", "nand", "built_listing_sha256"), ("outputs", "iboot", "sha256"), ("outputs", "nor", "sha256"),
                ("outputs", "gid_blobs", "sha256"), ("outputs", "kboot", "sha256")]
        def get(d, ks):
            for k in ks:
                d = d.get(k) if isinstance(d, dict) else None
            return d
        lines = []
        for ks in keys:
            x, y = get(b, ks), get(a, ks)
            if x != y: lines.append(f"  {'.'.join(ks)}: {x} != {y}")
        sb, sa = scrub(b), scrub(a)
        if sb != sa:
            def walk(x, y, path):
                if isinstance(x, dict) and isinstance(y, dict):
                    for k in sorted(set(x) | set(y)): walk(x.get(k), y.get(k), path + [k])
                elif x != y and not (path == ["outputs", "nand", "listing_sha256"] and eid.startswith("k48")):
                    lines.append(f"  {'.'.join(path)}: {json.dumps(x)[:80]} != {json.dumps(y)[:80]}")
            walk(sb, sa, [])
        print(("DIFF " if lines else "SAME ") + eid)
        for l in lines: print(l)
        bad += bool(lines)
    return 1 if bad else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create"); c.add_argument("--firmwarekit", type=Path, required=True); c.add_argument("--app", type=Path, required=True)
    c.add_argument("--out", type=Path, required=True); c.add_argument("--cache", type=Path); c.add_argument("--entry", action="append")
    d = sub.add_parser("diff"); d.add_argument("before", type=Path); d.add_argument("after", type=Path)
    a = ap.parse_args()
    sys.exit(create(a) if a.cmd == "create" else diff(a))
