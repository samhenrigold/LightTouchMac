#!/usr/bin/env python3
"""A stand-in for `firmwarekit create` that follows the preparer contract
(docs/multi-device-plan.md, "Preparer contract") without touching firmware.

    fake-firmwarekit.py create --entry ENTRY.json --ipsw IPSW --out STAGING [--seed S]
                               [--helper PATH] [--cache DIR]

FAKE_MODE picks the run: ok (default), error, crash, incomplete, slow (waits for SIGTERM
after step 2, with a read-only nand/ like the real one). FAKE_ARGV, if set, gets argv as JSON.
"""
import argparse, hashlib, json, os, signal, sys, time

signal.signal(signal.SIGTERM, lambda *_: os._exit(143))
mode = os.environ.get("FAKE_MODE", "ok")
if os.environ.get("FAKE_ARGV"):
    json.dump(sys.argv[1:], open(os.environ["FAKE_ARGV"], "w"))

ap = argparse.ArgumentParser()
ap.add_argument("cmd", choices=["create"])
for flag in ("--entry", "--ipsw", "--out"):
    ap.add_argument(flag, required=True)
for flag in ("--seed", "--helper", "--cache"):
    ap.add_argument(flag)
a = ap.parse_args()
entry = json.load(open(a.entry))
out = a.out


def emit(**event):
    print(json.dumps(event), flush=True)


emit(event="begin", steps=3, seconds=[5, 10, 70])
emit(event="step", index=1, name="Decrypting")
emit(event="progress", fraction=0, detail="Decrypting the firmware — 0 s")
if a.cache:
    os.makedirs(os.path.join(a.cache, entry["source"]["sha1"]), exist_ok=True)
    open(os.path.join(a.cache, entry["source"]["sha1"], "rootfs.dmg"), "w").write("x")
emit(event="progress", fraction=0.5, detail="Decrypting the firmware — 1 s")
emit(event="progress", fraction=1, detail="Decrypting the firmware — 2 s")
if mode == "crash":
    print("fake: crashing", file=sys.stderr)
    sys.exit(3)
if mode == "error":
    emit(event="error", code="key_missing", message="no key for rootfs")
    sys.exit(1)
emit(event="step", index=2, name="Building the NAND")
os.makedirs(os.path.join(out, "nand"), exist_ok=True)
with open(os.path.join(out, "nand", "store"), "wb") as f:   # 1 GiB apparent, a few KiB allocated
    f.write(b"NAND")
    f.truncate(1 << 30)
if entry["board"] == "n72ap":   # N72Recipe: the direct iBoot, NOR and KBAG table, no kboot.bin
    for name in ("iBoot.bin", "nor.bin", "gid-blobs.bin"):
        open(os.path.join(out, name), "wb").write(name.encode())
else:
    open(os.path.join(out, "kboot.bin"), "wb").write(b"KBOOT")
if (entry.get("recipe") or {}).get("options", {}).get("writable_nor"):
    open(os.path.join(out, "nor.bin"), "wb").write(b"\xff" * 4096)
os.chmod(os.path.join(out, "nand", "store"), 0o444)
os.chmod(os.path.join(out, "nand"), 0o555)
if mode == "slow":
    emit(event="warning", message="waiting to be cancelled")
    time.sleep(60)
    sys.exit(4)
emit(event="step", index=3, name="Sealing")
for i, f in enumerate([0, 0.25, 0.5, 0.75, 1]):
    emit(event="progress", fraction=f, detail=f"Booting to seal the flash — {i * 10} s")
die = ["0x00000123", "0x00000456"]
ident = {"udid": hashlib.sha1((a.seed or "").encode()).hexdigest(), "die-id": die}
fd = os.open(os.path.join(out, "identity.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, json.dumps(ident).encode())
os.close(fd)
lock = {"format": 1, "build": entry["build"], "product_version": entry["version"],
        "identity": {"seed": a.seed, "udid": ident["udid"], "die_id": ":".join(die)},
        "inputs": {}}
if mode != "incomplete":
    json.dump(lock, open(os.path.join(out, "device.lock.json"), "w"))
emit(event="done", lock="device.lock.json")
