#!/usr/bin/env python3
"""Enabling the web proxy trusts its certificate in the guest silently: no "Install Profile" screen, ever.

The session driver (tests/drivers/session-driver/proxy.swift) boots one device as the app does, with itwebproxy on
the wifi guestfwd, and trusts the `--init-ca` certificate the way WebProxySetup.configure does when
the guest agent is up: GuestServices.trustCertificate, which runs the package's ittrust (securityd's own
trust-store API) or the app's copy out of the armv6 itpack. Checked: the guest's own HTTPS client through
the proxy (httpget) fails before the trust and answers HTTP 200 after; Safari stays the front app with the
HTTPS page open (safari-https.png); a restart on the same overlay, unlocked, shows the home screen and no
profile screen (rebooted-unlocked.png) after the trust runs again; the fetch still answers 200.

    tests/sessions/check-proxy-trust.py --board ipod|ipad [--base DIR] --itwebproxy PATH --itpack armv6.itpack
                               [--ipad-itpack armv7.itpack] [--httpget PATH] [--url https://example.com/]
                               [--helper PATH] [--dylib PATH] [--work DIR]

--base empty (the default) with --board ipod boots the shipping image (qemu-ios-files/nand-current).
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--board", choices=("ipod", "ipad"), required=True)
    ap.add_argument("--base", type=Path, help="a prepared base; omit for the shipping iPod image")
    ap.add_argument("--itwebproxy", required=True, help="the host proxy helper (a packaged app's Contents/MacOS/itwebproxy)")
    ap.add_argument("--itpack", type=Path, default=sources.path("qemu-ios") / "build/guest-package/armv6.itpack")
    ap.add_argument("--httpget", type=Path, help="contrib/it-proxy/httpget built for armv6 (the guest-side fetch proof)")
    ap.add_argument("--ipad-itpack", type=Path, help="--board ipad: the armv7.itpack whose offer brings it_agent up (as the app boots an iPad)")
    ap.add_argument("--url", default="https://example.com/")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--frameworks")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    if args.board == "ipad" and not (args.base and args.ipad_itpack):
        ap.error("--board ipad needs --base and --ipad-itpack (the iPad's agent comes from the package offer)")

    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-proxy-trust-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    nand_current = args.files / "nand-current"
    cfg = {"helper": str(helper), "requirement": sessions.TEAM_REQ, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files),
           "ipodNAND": str(args.files / os.readlink(nand_current)) if nand_current.is_symlink() else "",
           "ipadBase": str(args.base if args.board == "ipad" else ""), "timeout": 900,
           "proxy": {"board": args.board, "base": str(args.base or ""), "itwebproxy": args.itwebproxy, "itpack": str(args.itpack),
                     "httpget": str(args.httpget) if args.httpget else None, "url": args.url}}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    if args.ipad_itpack:
        cfg["ipadItpack"] = str(args.ipad_itpack)
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
    events = []
    try:
        try:
            driver.wait(timeout=920)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
    finally:
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
                print(f"  (killed leftover {pid})")
            except (ProcessLookupError, PermissionError):
                pass

    def find(name, **match):
        return [e for e in events if e.get("event") == name and all(e.get(k) == v for k, v in match.items())]

    def one(name, **match):
        return (find(name, **match) or [{}])[0]

    results = []

    def check(ok, what):
        results.append(bool(ok))
        print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)

    b = args.board
    check(one("lit"), f"{b}: lit in {one('lit').get('seconds', -1):.1f} s")
    check(one("usb").get("productType"), f"{b}: lockdown over its usbmuxd: {one('usb').get('productType')}")
    agent = one("agent", generation=1)
    check(agent.get("alive"), f"{b}: the guest agent is up (packaged: {agent.get('packaged')}, ActivationState {agent.get('state')!r})")
    route = one("route")
    check(route.get("ok"), f"{b}: guest routed through the proxy (the image's PAC, or itproxy without one)"
          + ("" if route.get("ok") else f": {route.get('error')}"))
    if args.httpget:
        http = one("httpget", label="http")
        check(http.get("ok"), f"{b}: plain HTTP through the proxy (the guest's Wi-Fi is up): {http.get('output', '')[:60]!r}")
        before = one("httpget", label="untrusted")
        # The proxy's untrusted chain: -1200 "secure connection failed" through the PAC (7E18 and 7B500 bases), -1202
        # "untrusted server certificate" through itproxy's static proxy (the legacy image). The route check above
        # makes sure it is the proxy's certificate being refused, not 3.1.3's TLS against the real origin (-1200 too).
        check(before and not before.get("ok") and any(code in before.get("output", "") for code in ("-1200", "-1202")),
              f"{b}: HTTPS through the proxy refused before the trust (untrusted certificate): {before.get('output', '')[:90]!r}")
    trust = one("trust", generation=1)
    check(trust.get("ok"), f"{b}: certificate trusted through the agent in {trust.get('seconds', -1):.1f} s"
          + ("" if trust.get("ok") else f": {trust.get('error')}"))
    if args.httpget:
        after = one("httpget", label="trusted")
        check(after.get("ok"), f"{b}: HTTPS through the proxy answers after the trust: {after.get('output', '')[:40]!r}")
    check(one("front", label="after-trust").get("bundleID") == "com.apple.springboard",
          f"{b}: no screen took over after the trust (front: {one('front', label='after-trust').get('bundleID')})")
    check(one("safari").get("launched") == "Safari", f"{b}: Safari launched")
    front = one("front", label="safari")
    check(front.get("bundleID") == "com.apple.mobilesafari", f"{b}: Safari still in front after the page load (front: {front.get('bundleID')})")
    check(one("quit").get("exited"), f"{b}: clean halt, helper exited in {one('quit').get('seconds', -1):.1f} s")
    check(one("agent", generation=2).get("alive"), f"{b}: restarted on the same overlay, agent up")
    check(one("trust", generation=2).get("ok"), f"{b}: the trust runs again after the restart, silently")
    rebooted = one("front", label="rebooted")
    check(rebooted.get("bundleID") == "com.apple.springboard", f"{b}: unlocked after the restart: the home screen, no profile screen (front: {rebooted.get('bundleID')})")
    if args.httpget:
        again = one("httpget", label="rebooted")
        check(again.get("ok"), f"{b}: HTTPS still answers after the restart: {again.get('output', '')[:40]!r}")
    check(one("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = find("fail")
    if fails:
        print("  driver: " + fails[0]["why"])
    for e in find("screenshot"):
        print(f"   {e['path']}  ({e['width']}x{e['height']}, brightness {e['brightness']:.2f})")
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
