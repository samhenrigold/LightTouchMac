#!/usr/bin/env python3
"""check-proxy-trust's "unlocked after the restart" wants SpringBoard's Home Screen, not SpringBoard alone: 8C148's
run 2 (smoke #66) passed it on `com.apple.springboard / Lock Screen` with every frame dark."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("check_proxy_trust", Path(__file__).resolve().parent / "check-proxy-trust.py")
pt = importlib.util.module_from_spec(spec); spec.loader.exec_module(pt)
SB = "com.apple.springboard"
cases = [({"bundleID": SB, "name": "Home Screen"}, True),
         ({"bundleID": SB, "name": "Lock Screen"}, False),   # the run the old check passed
         ({"bundleID": SB, "name": ""}, False),              # the agent never named the screen
         ({"bundleID": "com.apple.Preferences", "name": "Settings"}, False),   # a profile screen took over
         ({}, False)]                                        # no front event at all
bad = [(f, want) for f, want in cases if pt.home_screen(f) != want]
for f, want in bad:
    print(f"FAIL home_screen({f}) should be {want}")
print(f"{len(cases) - len(bad)}/{len(cases)} passed")
raise SystemExit(1 if bad else 0)
