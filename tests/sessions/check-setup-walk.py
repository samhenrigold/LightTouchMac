#!/usr/bin/env python3
"""The 5.x Setup walk's retry core (session-driver Setup5.tapUntil): builds the driver and runs its --selftest-walk
against fake taps, no emulator. Fails if a lost tap is not retried, a landed tap is repeated, or the budget is ignored."""
import argparse, importlib.util, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
with tempfile.TemporaryDirectory(prefix="setup-walk-") as d:
    cs.build(argparse.Namespace(helper="/usr/bin/true"), Path(d))
    r = subprocess.run([str(Path(d) / "session-driver"), "--selftest-walk"], capture_output=True, text=True, timeout=120)
    print(r.stdout, end="")
    sys.exit(0 if r.returncode == 0 else "setup walk self-test failed")
