#!/usr/bin/env python3
"""Phase 0, spikes 2 and 3: the hardened LightTouchDevice boots real devices.

    spikes/spike2.py ipad-boot      # iPad 3.2.2 GL-CA golden, fresh overlay: lit, unlock, 2 snapshots, quit
    spikes/spike2.py ipad-restore   # -incoming the second snapshot on the same overlay, prove it's alive
    spikes/spike2.py ipod-boot      # iPod nand-current, fresh overlay, home screen
    spikes/spike2.py both           # spike 3: iPod + iPad at once, each with its own usbmuxd; ideviceinfo each

Read-only bases, private overlays and dumps under ~/Developer/qemu-ios-files/spikes/multidevice.
Run it in the foreground under `timeout`; everything it starts is reaped before it returns.
"""
import json, os, re, shutil, signal, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
B = f"{HERE}/.build"
HOME = os.path.expanduser("~")
FILES = f"{HOME}/Developer/qemu-ios-files"
DYLIB = f"{HOME}/Developer/qemu-ios-ipad1/build-spike-md/libqemu-arm.dylib"
WORK = f"{FILES}/spikes/multidevice"
USBMUXD = f"{HOME}/Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd"
esc = lambda p: p.replace(",", ",,")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def ipad(work, actions, restore=None, usb=None, fresh=True):
    ovl = f"{work}/overlay"
    if fresh and os.path.exists(ovl):
        shutil.rmtree(ovl)
    os.makedirs(ovl, exist_ok=True)
    machine = (f"ipad1,kboot={esc(FILES + '/ipad1/7B500/k48-kboot.bin')}"
               f",nand={esc(FILES + '/ipad1/userland/golden-pristine')},nand-overlay={esc(ovl)}")
    if usb:
        machine += f",usb-tcp-addr={usb}"
    argv = ["LightTouchDevice", "-M", machine, "-display", "none", "-no-shutdown",
            "-serial", f"file:{work}/serial.log", "-device", "usb-kbd,bus=usb-bus.0"]
    if restore:
        argv += ["-incoming", f"file:{restore}"]
    return {"dylib": DYLIB, "argv": argv, "actions": actions, "maxSeconds": 480}


def ipod(work, actions, usb=None):
    ovl = f"{work}/overlay"
    if os.path.exists(ovl):
        shutil.rmtree(ovl)
    os.makedirs(ovl)
    shutil.copy(f"{FILES}/ios3/nor_7E18.bin", f"{ovl}/nor.bin")      # DeviceStateStorage.writableNOR
    os.chmod(f"{ovl}/nor.bin", 0o600)
    boot_args = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
    machine = ("iPod-Touch,h264-decode=on,scaler-decode=on,mpvd-decode=on,amc-mode=decode,lcd-planes=on"
               f",boot-args={esc(boot_args)},boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"
               f",direct-iboot={esc(FILES + '/ios3/iBoot.bin')},direct-llb=,bootrom={FILES}/bootrom_240_4"
               f",nand={FILES}/{os.readlink(FILES + '/nand-current')},nor={FILES}/ios3/nor_7E18.bin"
               f",nor-rw={ovl}/nor.bin,nandrw={ovl},wifi=on")
    if usb:
        machine += f",usb-tcp-addr={usb},osk=on"
    argv = ["LightTouchDevice", "-M", machine, "-m", "128M", "-display", "none", "-no-shutdown",
            "-audio", "driver=coreaudio,out.buffer-count=16", "-serial", f"file:{work}/serial.log",
            "-netdev", "user,id=wifi0"]
    return {"dylib": DYLIB, "argv": argv, "env": {"IT_TVOUT_READY": "1"}, "actions": actions,
            "maxSeconds": 400, "litFraction": 0.03}


def run_host(name, configs, seconds, dump):
    os.makedirs(dump, exist_ok=True)
    cmd = [f"{B}/spike-host", "--seconds", str(seconds), "--poll-us", "16667", "--dump", dump]
    for i, c in enumerate(configs):
        path = f"{dump}/{name}-dev{i}.json"
        json.dump(c, open(path, "w"), indent=1)
        cmd += ["--device", f"{B}/LightTouchDevice --config {path}"]
    log = f"{dump}/{name}.log"
    return subprocess.Popen(cmd, stdout=open(log, "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL), log


IPOD_UNLOCK = "drag 0.18 0.9 0.92 0.9"   # the lock screen slider, 320x480 portrait
UNLOCK = "drag 0.9365 0.621 0.9365 0.0612"      # tests/ipad1/boot-smoke.py UNLOCK_FROM/TO over 1024x768
scenario = sys.argv[1]
os.makedirs(WORK, exist_ok=True)

if scenario in ("ipad-boot", "ipad-restore", "ipod-boot"):
    w = f"{WORK}/{scenario.split('-')[0]}"
    os.makedirs(w, exist_ok=True)
    if scenario == "ipad-boot":
        cfg = ipad(w, ["wait 5", "dump lock", UNLOCK, "wait 5", "dump home", f"snapshot {w}/snap1",
                       "dump after-save1", "resume", "wait 4", "dump after-resume", f"snapshot {w}/snap2", "quit"])
    elif scenario == "ipad-restore":
        cfg = ipad(w, ["wait 2", "dump restored", "tap 0.4375 0.846", "wait 5", "dump settings",
                       "button 0", "wait 4", "dump after-home", "quit"], restore=f"{w}/snap2", fresh=False)
        cfg["litFraction"] = 0.1
    else:
        cfg = ipod(w, ["dump lock", IPOD_UNLOCK, "wait 4", "dump home", "quit"])
    p, log = run_host(scenario, [cfg], 560, f"{WORK}/dumps/{scenario}")
    rc = p.wait(timeout=585)
    print(open(log).read()[-6000:])
    sys.exit(rc)

if scenario == "both":
    # Spike 3: one usbmuxd per device, own client port, guest port and conf dir.
    daemons, envs = [], []
    for name in ("ipod", "ipad"):
        conf = f"{WORK}/both-{name}/usbmuxd-conf"
        os.makedirs(conf, exist_ok=True)
        client, guest = f"127.0.0.1:{free_port()}", f"127.0.0.1:{free_port()}"
        env = dict(os.environ, USBMUXD_QEMU_ADDR=guest, USBMUXD_QEMU_DELAY="0")
        d = subprocess.Popen([USBMUXD, "-f", "-v", "-S", client, "-P", "NONE", "-C", conf], env=env,
                             stdout=open(f"{WORK}/both-{name}/usbmuxd.log", "w"), stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL)
        daemons.append(d)
        envs.append((name, client, guest))
    time.sleep(0.5)
    # Both stay up until this script SIGTERMs the host: that also exercises parent death
    # with real QEMU (the helpers power down and exit on their own).
    c_ipod = ipod(f"{WORK}/both-ipod", ["dump lock", IPOD_UNLOCK, "wait 4", "dump home", "wait 540"], usb=envs[0][2])
    c_ipad = ipad(f"{WORK}/both-ipad", ["wait 3", "dump lock", "wait 540"], usb=envs[1][2])
    os.makedirs(f"{WORK}/both-ipod", exist_ok=True)
    p, log = run_host("both", [c_ipod, c_ipad], 560, f"{WORK}/dumps/both")
    report = {}
    try:
        deadline = time.time() + 540
        lit = set()
        while time.time() < deadline and len(lit) < 2 and p.poll() is None:
            lit = set(re.findall(r"device (\d) event .*\blit\b", open(log).read())) | lit
            time.sleep(2)
        report["lit"] = sorted(lit)
        for name, client, _ in envs:
            out = []
            for attempt in range(6):
                r = subprocess.run(["ideviceinfo", "-k", "ProductType"], env=dict(os.environ, USBMUXD_SOCKET_ADDRESS=client),
                                   capture_output=True, text=True, timeout=30)
                r2 = subprocess.run(["ideviceinfo", "-k", "ProductVersion"], env=dict(os.environ, USBMUXD_SOCKET_ADDRESS=client),
                                    capture_output=True, text=True, timeout=30)
                out.append((r.returncode, r.stdout.strip() or r.stderr.strip(), r2.stdout.strip() or r2.stderr.strip()))
                if r.returncode == 0:
                    break
                time.sleep(5)
            ids = subprocess.run(["idevice_id", "-l"], env=dict(os.environ, USBMUXD_SOCKET_ADDRESS=client),
                                 capture_output=True, text=True, timeout=30)
            report[name] = {"socket": client, "ideviceinfo": out, "udids": ids.stdout.split()}
        time.sleep(3)   # let the ipod's "dump home" land
        # Every socket and file each process holds, to spot anything shared.
        pids = [int(x) for x in re.findall(r"spawned device \d pid (\d+)", open(log).read())] + [d.pid for d in daemons]
        for pid in pids:
            r = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-i"], capture_output=True, text=True)
            report[f"sockets {pid}"] = [" ".join(l.split()[7:]) for l in r.stdout.splitlines()[1:]]
            r = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-d", "0-999"], capture_output=True, text=True)
            report[f"files {pid}"] = sorted({l.split()[-1] for l in r.stdout.splitlines()[1:]
                                             if "/" in l.split()[-1] and "/dev/" not in l.split()[-1]})
    finally:
        pids = [int(x) for x in re.findall(r"spawned device \d pid (\d+)", open(log).read())]
        t0 = time.time()
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=30)
        gone = {}
        while time.time() < t0 + 40 and len(gone) < len(pids):
            for pid in pids:
                if pid not in gone and subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode:
                    gone[pid] = round(time.time() - t0, 1)
            time.sleep(0.2)
        for pid in pids:
            if pid not in gone:
                os.kill(pid, signal.SIGKILL)
        report["helpers exited after parent SIGTERM (s)"] = gone
        for d in daemons:
            d.terminate()
            d.wait(timeout=10)
    print(open(log).read()[-8000:])
    print("REPORT " + json.dumps(report, indent=1))
