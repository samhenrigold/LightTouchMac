#!/usr/bin/env python3
"""Phase 0, spike 1: rendezvous, peer validation, IOSurface ring, lifetime.

    spikes/build.sh && spikes/spike1.py

Every process started here is killed or reaped before exit.
"""
import json, os, re, signal, subprocess, sys, time

B = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".build")
DEV = f"{B}/LightTouchDevice"
OUT = "/tmp/ltm-spike1"
os.makedirs(OUT, exist_ok=True)
results = {}


def host(name, devices, extra=(), wait=None):
    """Start spike-host; returns (Popen, log path)."""
    path = f"{OUT}/{name}.log"
    cmd = [f"{B}/spike-host", "--seconds", "30", *extra]
    for d in devices:
        cmd += ["--device", d]
    p = subprocess.Popen(cmd, stdout=open(path, "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    return p, path


def text(path):
    return open(path).read()


def wait_for(path, pattern, timeout=10):
    t = time.time() + timeout
    while time.time() < t:
        m = re.search(pattern, text(path))
        if m:
            return m
        time.sleep(0.01)
    return None


def result_json(path):
    m = re.search(r"HOST_RESULT (\{.*\})", text(path), re.S)
    return json.loads(m.group(1)) if m else None


def stamp(line_pattern, path):
    m = re.search(r"\[(\d+\.\d+) \d+\] " + line_pattern, text(path))
    return float(m.group(1)) if m else None


# (c) ring at 60 Hz: 1 ms polling (latency resolution) and 16.7 ms (display-link cadence)
for poll in (1000, 16667):
    p, log = host(f"ring-poll{poll}", [f"{DEV} --synthetic --seconds 10"], ["--poll-us", str(poll), "--check-tear", "1"])
    p.wait(timeout=40)
    results[f"ring poll {poll} us"] = result_json(log)

# (b) validation: impostor signatures and a wrong token are rejected
for name, spec in [("adhoc", f"{B}/LightTouchDevice-adhoc --synthetic --seconds 2"),
                   ("otherteam", f"{B}/LightTouchDevice-otherteam --synthetic --seconds 2"),
                   ("badtoken", f"{DEV} --synthetic --seconds 2 --bad-token")]:
    if not os.path.exists(spec.split()[0]):
        continue
    p, log = host(f"reject-{name}", [spec])
    p.wait(timeout=40)
    m = re.search(r"(REJECT.*|ACCEPT.*)", text(log))
    results[f"reject {name}"] = m.group(1) if m else "no hello seen"

# (b) a correctly signed process the host did not spawn
p, log = host("reject-rogue", [f"{DEV} --synthetic --seconds 4"])
m = wait_for(log, r"HOST_READY pid=(\d+) service=(\S+)")
rogue = subprocess.Popen([DEV, "--connect", m.group(2), "--uuid", "x", "--token", "guess", "--synthetic", "--seconds", "1"],
                         stdout=subprocess.DEVNULL, stderr=open(f"{OUT}/rogue.log", "w"), stdin=subprocess.DEVNULL)
rogue.wait(timeout=20)
p.wait(timeout=40)
results["reject rogue"] = [l for l in text(log).splitlines() if "REJECT" in l or "ACCEPT" in l]

# (d) kill -9 the parent: the child notices
p, log = host("kill-parent", [f"{DEV} --synthetic --seconds 60"])
wait_for(log, r"ACCEPT device 0 pid (\d+)")
child = int(wait_for(log, r"spawned device 0 pid (\d+)").group(1))
time.sleep(1)
t0 = time.time()
p.send_signal(signal.SIGKILL)
p.wait()
wait_for(log, r"NOTICED parent exit", 5)
t_noticed = stamp(r"NOTICED parent exit", log)
time.sleep(0.5)
alive = subprocess.run(["kill", "-0", str(child)], capture_output=True).returncode == 0
if alive:
    os.kill(child, signal.SIGKILL)
results["kill -9 parent"] = {"child noticed after ms": round((t_noticed - t0) * 1000, 1) if t_noticed else None,
                             "child still alive 0.5 s later": alive,
                             "lines": [l for l in text(log).splitlines() if "NOTICED" in l or "shutdown" in l]}

# (d) kill -9 the child: the parent notices
p, log = host("kill-child", [f"{DEV} --synthetic --seconds 60"])
wait_for(log, r"ACCEPT device 0")
child = int(wait_for(log, r"spawned device 0 pid (\d+)").group(1))
time.sleep(1)
t0 = time.time()
os.kill(child, signal.SIGKILL)
p.wait(timeout=10)
ts = [float(x) for x in re.findall(r"\[(\d+\.\d+) \d+\] NOTICED device 0", text(log))]
results["kill -9 child"] = {"parent noticed after ms (each signal)": [round((t - t0) * 1000, 1) for t in ts],
                            "lines": [l for l in text(log).splitlines() if "NOTICED" in l]}

print(json.dumps(results, indent=1))
