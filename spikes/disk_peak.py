#!/usr/bin/env python3
"""Phase 0, spike 5: peak disk use and duration of the Python iPad pipeline.

    spikes/disk_peak.py BUILD [--activation-hook SCRIPT]      # BUILD: 7B500 | 8C148 | 7B367

Runs qemu-ios `imgtools/ipad1_device.py create` with a PRIVATE decrypt cache (its CACHE
constant overridden, so the decrypt step is measured and the shared cache is untouched)
and the private build-spike-md QEMU, sampling every 2 s: du of the output + cache dirs,
and the volume's free space (catches temp files elsewhere, e.g. hdiutil shadows).
Everything lands in ~/Developer/qemu-ios-files/spikes/disk/<BUILD>/. Run under `timeout`.
"""
import json, os, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
QROOT = f"{HOME}/Developer/qemu-ios-ipad1-spike-md"   # private worktree of branch ipad1: its own
# untracked guest builds (contrib/ipad1-guest, contrib/appsync, contrib/ipad1-gles build.sh), so the
# shared checkout's build outputs are never rebuilt under anyone
QEMU = f"{HOME}/Developer/qemu-ios-ipad1/build-spike-md/qemu-system-arm"
build = sys.argv[1]
hook = sys.argv[sys.argv.index("--activation-hook") + 1] if "--activation-hook" in sys.argv else None
base = f"{HOME}/Developer/qemu-ios-files/spikes/disk/{build}"
out, cache = f"{base}/device", f"{base}/cache"
shutil.rmtree(base, ignore_errors=True)
os.makedirs(cache)

argv = ["create", f"{QROOT}/manifests/ipad1-{build}.json", out, "--qemu", QEMU]
if hook:
    argv += ["--activation-hook", hook]
code = ("import sys; sys.path.insert(0, %r); import ipad1_device as d; d.CACHE = %r; sys.argv = %r; d.main()"
        % (f"{QROOT}/imgtools", cache, ["ipad1_device.py"] + argv))


def du(path):
    """Allocated KiB (sparse-aware), 0 if absent."""
    if not os.path.exists(path):
        return 0
    r = subprocess.run(["du", "-sk", path], capture_output=True, text=True)
    return int(r.stdout.split()[0]) if r.stdout else 0


def free_kib():
    st = os.statvfs(base)
    return st.f_bavail * st.f_frsize // 1024


free0 = free_kib()
t0 = time.monotonic()
p = subprocess.Popen([sys.executable, "-c", code], stdout=open(f"{base}/steps.log", "w"), stderr=subprocess.STDOUT,
                     stdin=subprocess.DEVNULL, cwd=QROOT)
samples = []
try:
    while p.poll() is None:
        samples.append((round(time.monotonic() - t0, 1), du(out), du(cache), free0 - free_kib()))
        time.sleep(2)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
dur = time.monotonic() - t0
samples.append((round(dur, 1), du(out), du(cache), free0 - free_kib()))
peak = max(samples, key=lambda s: s[1] + s[2])
peak_df = max(samples, key=lambda s: s[3])
apparent = subprocess.run(["du", "-sk", "-A", f"{out}/nand"], capture_output=True, text=True).stdout.split()
result = {
    "build": build, "hook": bool(hook), "rc": p.returncode, "seconds": round(dur),
    "peak_out_plus_cache_MiB": round((peak[1] + peak[2]) / 1024), "peak_at_s": peak[0],
    "peak_volume_delta_MiB": round(peak_df[3] / 1024), "peak_volume_delta_at_s": peak_df[0],
    "final_device_MiB": round(du(out) / 1024), "final_nand_MiB": round(du(f"{out}/nand") / 1024),
    "final_nand_apparent_MiB": round(int(apparent[0]) / 1024) if apparent else None,
    "decrypt_cache_MiB": round(du(cache) / 1024),
    "steps": open(f"{base}/steps.log").read().strip().splitlines(),
}
json.dump({"result": result, "samples_s_outKiB_cacheKiB_volDeltaKiB": samples}, open(f"{base}/disk-peak.json", "w"), indent=1)
print(json.dumps(result, indent=1))
