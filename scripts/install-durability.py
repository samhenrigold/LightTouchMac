#!/usr/bin/env python3
"""Does an installed app survive a hard exit? The app's core durability check.

MEASURED 2026-08-06 on nand-ultimate, one run per arm:

    none    0/1 apps still installed after the reboot   (GONE)
    sync    1/1 apps still installed after the reboot

In the losing run the overlay held 9,408 pages / 74 MB -- the app's DATA was on
flash the whole time. What never landed was the directory entry for
/var/mobile/Applications/<uuid>/. So this is the "I installed it, quit, and it
was gone" bug, and one `sync` over ssh is the difference. That is why
EmulatorController.beginCleanShutdown runs one, and this is the test that keeps
it true.

Do NOT re-write this to use an AFC file as the marker. An AFC write survives a
hard kill with or without the flush, so that version passes no matter what the
app does -- it measures the one path that was never fragile. The workload has to
go through installd.

    scripts/install-durability.py none|sync [nand]

Needs: a built build-min12b/qemu-system-arm, the usbmuxd fork, ideviceinstaller,
and a decrypted iOS 3-compatible .ipa (edit IPA below).
"""
import os, subprocess, sys, time, tempfile, socket
from types import SimpleNamespace

ROOT = "/Users/shg/Developer/qemu-ios"
FILES = "/Users/shg/Developer/qemu-ios-files"
MUXD = os.path.expanduser("~/Developer/usbmuxd-qemu/usbmuxd/src/usbmuxd")
IPA = os.path.expanduser("~/Downloads/ios3/01 Temple Run 1.0 (3423942).ipa")
sys.path.insert(0, os.path.join(ROOT, "tests", "ipod"))
from regress import QMP, boot_env                                   # noqa: E402

MODE = sys.argv[1] if len(sys.argv) > 1 else "none"
NAND = sys.argv[2] if len(sys.argv) > 2 else "nand-ultimate"
OUT = tempfile.mkdtemp(prefix="install-%s-" % MODE)
OVL = os.path.join(OUT, "overlay"); os.makedirs(OVL)


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


def log(m): print("[install:%s] %s" % (MODE, m), flush=True)


class Boot:
    def __init__(self, tag):
        self.tag = tag
        self.dir = os.path.join(OUT, tag); os.makedirs(self.dir, exist_ok=True)
        self.mux_port, self.usb_port, self.qmp_port = free_port(), free_port(), free_port()
        env = dict(os.environ, USBMUXD_QEMU_ADDR="127.0.0.1:%d" % self.usb_port,
                   USBMUXD_QEMU_DELAY="12")
        os.makedirs(os.path.join(OUT, "muxcfg"), exist_ok=True)
        self.muxlog = open(os.path.join(self.dir, "usbmuxd.log"), "w")
        self.mux = subprocess.Popen(
            [MUXD, "-f", "-v", "-v", "-v", "-S", "127.0.0.1:%d" % self.mux_port,
             "-P", "NONE", "-C", os.path.join(OUT, "muxcfg")],
            stdout=self.muxlog, stderr=subprocess.STDOUT, env=env)
        time.sleep(2)
        machine = ("iPod-Touch,bootrom=%s/bootrom_240_4,nand=%s/%s,nor=%s/ios3/nor_7E18.bin,"
                   "nandrw=%s,usb-attached=on,usb-tcp-addr=127.0.0.1:%d"
                   % (FILES, FILES, NAND, FILES, OVL, self.usb_port))
        self.qlog = open(os.path.join(self.dir, "qemu.log"), "w")
        self.qemu = subprocess.Popen(
            [os.path.join(ROOT, "build-min12b", "qemu-system-arm"), "-M", machine,
             "-m", "128M", "-display", "none", "-audio", "driver=none",
             "-serial", "file:" + os.path.join(self.dir, "serial.log"),
             "-qmp", "tcp:127.0.0.1:%d,server=on,wait=off" % self.qmp_port],
            stdout=self.qlog, stderr=subprocess.STDOUT,
            env=boot_env(SimpleNamespace(files=FILES)))
        log("%s: qemu pid %d, mux %d" % (tag, self.qemu.pid, self.mux_port))
        self.qmp = QMP(self.qmp_port, timeout=180)

    def wait_home(self, timeout=300):
        shot = os.path.join(self.dir, "s.ppm")
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(10)
            if self.qemu.poll() is not None:
                log("%s: qemu exited early rc=%s" % (self.tag, self.qemu.returncode)); return False
            try:
                self.qmp.shot(shot)
                lit = sum(1 for b in open(shot, "rb").read()[15:] if b > 40)
            except Exception:
                lit = -1
            if lit > 150000:
                log("%s: home at lit=%d" % (self.tag, lit)); return True
        log("%s: never reached home" % self.tag); return False

    def env(self):
        return dict(os.environ, USBMUXD_SOCKET_ADDRESS="127.0.0.1:%d" % self.mux_port)

    def listed(self, timeout=180):
        r = subprocess.run(["ideviceinstaller", "list"], capture_output=True,
                           text=True, env=self.env(), timeout=timeout)
        return r.stdout + r.stderr

    def ssh(self, command, timeout=120):
        port = free_port()
        script = """
        set -u
        iproxy %d 22 >/dev/null 2>&1 &
        IP=$!
        trap 'kill $IP 2>/dev/null' EXIT
        sleep 2
        ASK="$(mktemp -t ask)"
        printf '#!/bin/sh\\necho alpine\\n' > "$ASK"; chmod 700 "$ASK"
        SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1 \
            -p %d root@127.0.0.1 '%s'
        """ % (port, port, command)
        return subprocess.run(["/bin/bash", "-c", script], capture_output=True,
                              text=True, env=self.env(), timeout=timeout)

    def kill(self):
        for p in (self.qemu, self.mux):
            try: p.kill(); p.wait(timeout=20)
            except Exception: pass


if not os.path.exists(IPA):
    log("no .ipa at %s" % IPA); sys.exit(2)

b1 = Boot("boot1")
if not b1.wait_home():
    b1.kill(); sys.exit(2)
time.sleep(15)

log("installing %s" % os.path.basename(IPA))
r = subprocess.run(["ideviceinstaller", "install", IPA], capture_output=True,
                   text=True, env=b1.env(), timeout=900)
log("install rc=%d out=%r" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
before = b1.listed()
open(os.path.join(OUT, "list-before.txt"), "w").write(before)
ids = [l.split(",")[0].strip() for l in before.splitlines() if "," in l and "." in l.split(",")[0]]
log("installd lists %d app(s) before the kill: %s" % (len(ids), ids))
if not ids:
    log("nothing installed; cannot measure"); b1.kill(); sys.exit(3)

if MODE == "sync":
    s = b1.ssh("sync; echo SYNCED")
    log("sync rc=%d out=%r" % (s.returncode, s.stdout.strip()[-120:]))
else:
    log("no flush (control)")
time.sleep(3)

log("SIGKILLing qemu")
b1.kill()
time.sleep(3)

b2 = Boot("boot2")
if not b2.wait_home():
    log("RESULT %s: second boot never reached home" % MODE); b2.kill(); sys.exit(4)
time.sleep(15)
after = b2.listed()
open(os.path.join(OUT, "list-after.txt"), "w").write(after)
survived = [i for i in ids if i in after]
log("RESULT %s: %d/%d app(s) still installed after the hard kill -> %s"
    % (MODE, len(survived), len(ids), survived or "GONE"))
# Did the bundle survive on disk even though the registry did not?
s = b2.ssh("ls -d /var/mobile/Applications/*/*.app 2>/dev/null | head -5; "
           "ls -l /var/mobile/Library/Caches/com.apple.mobile.installation.plist 2>&1")
log("on-disk: %r" % s.stdout.strip()[-400:])
b2.kill()
log("artifacts in %s" % OUT)
sys.exit(0 if len(survived) == len(ids) else 1)
