#!/usr/bin/env python3
"""App-level regression checks for LightTouchMac.

Reuses the qemu-ios harness (tests/ipod/regress.py) for the boot/device
machinery and adds the checks that are specific to the app's stability work:
env parity with the harness. (The snapshot round trip went with the app's
quit-with-resume feature; the helper's snapshot ops are covered by
tests/check-helper-boot.py's restore case.)

    scripts/regress_app.py                 # all checks
    scripts/regress_app.py --checks env    # the fast, device-free ones

Needs the qemu-ios checkout and its images; run locally / pre-release, not per-PR.
"""
import os, sys, re, time, subprocess, argparse

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(APP, "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
QEMU_IOS = str(sources.path("qemu-ios"))
sys.path.insert(0, os.path.join(QEMU_IOS, "tests", "ipod"))
import regress as R
if not hasattr(R, "START"):
    R.START = time.time()

FAILURES = []


def check(name, ok, detail):
    print(f"  {name:<22} {'PASS' if ok else 'FAIL'}  {detail}")
    if not ok:
        FAILURES.append(name)
    return ok


# --------------------------------------------------------------------------
# 1. env parity — the cheapest, highest-value check
# --------------------------------------------------------------------------

def computed_boot_args(text):
    # Resolve the known Swift expression, excluding the two optional app flags.
    # Unknown expressions fail parity instead of silently using a guessed base.
    base = re.search(
        r'static var bootArgs: String\s*\{\s*var args = "([^"]*)"\s*'
        r'if verboseBoot \{ args \+= " -v" \}\s*'
        r'if kernelConsole \{ args \+= " serial=3 debug=0x8" \}\s*'
        r'return args\s*\}', text)
    return base.group(1) if base else None


def boot_env_keys(text):
    """Literal IT_* pairs, including the former computed app boot-args value."""
    values = dict(re.findall(r'"(IT_[A-Z_]+)":\s*"([^"]*)"', text))
    if re.search(r'"IT_BOOT_ARGS":\s*Self\.bootArgs\b', text):
        base = computed_boot_args(text)
        if base is not None:
            values["IT_BOOT_ARGS"] = base
    return values


def boot_config_keys(text):
    """Compare effective startup values regardless of property/alias spelling."""
    values = boot_env_keys(text)
    for prop, alias in (("boot-args-delay-ms", "IT_BOOT_ARGS_DELAY_MS"),
                        ("boot-args-repeat", "IT_BOOT_ARGS_REPEAT"),
                        ("boot-args-interval-ms", "IT_BOOT_ARGS_INTERVAL_MS")):
        if "," + prop + "=" in text:
            # Explicit properties override aliases, even if the checker cannot
            # evaluate them. Missing values must remain a parity failure.
            values.pop(alias, None)
            match = re.search(r"," + prop + r"=(\d+)(?=,|\")", text)
            if match:
                values[alias] = match.group(1)
    if ",boot-args=" in text:
        values.pop("IT_BOOT_ARGS", None)
        expression = r',boot-args=\(Self.bootArgs.replacingOccurrences(of: ",", with: ",,"))'
        if expression in text:
            base = computed_boot_args(text)
            if base is not None:
                values["IT_BOOT_ARGS"] = base
    return values


def env_drift(app, harness, required):
    return {key: (app.get(key), harness.get(key)) for key in required
            if key not in app or key not in harness or app[key] != harness[key]}


def self_test():
    source = '''
    static var bootArgs: String {
        var args = "test=1"
        if verboseBoot { args += " -v" }
        if kernelConsole { args += " serial=3 debug=0x8" }
        return args
    }
    "IT_BOOT_ARGS": Self.bootArgs,
    "IT_WDT_NORESET": "1"
    '''
    app = boot_env_keys(source)
    assert app == {"IT_BOOT_ARGS": "test=1", "IT_WDT_NORESET": "1"}
    assert not env_drift(app, dict(app), app)
    assert env_drift({}, {}, ["missing"]) == {"missing": (None, None)}
    assert env_drift(app, {}, ["IT_BOOT_ARGS"]) == {"IT_BOOT_ARGS": ("test=1", None)}
    assert env_drift({"key": "1"}, {"key": "2"}, ["key"]) == {"key": ("1", "2")}
    assert "IT_BOOT_ARGS" not in boot_env_keys(source.replace("return args", "return other"))
    properties = source + r' ",boot-args=\(Self.bootArgs.replacingOccurrences(of: ",", with: ",,"))"'
    properties += '\n",boot-args-delay-ms=1500,boot-args-repeat=200,boot-args-interval-ms=250"'
    effective = boot_config_keys(properties)
    expected = {**app, "IT_BOOT_ARGS_DELAY_MS":"1500", "IT_BOOT_ARGS_REPEAT":"200",
                "IT_BOOT_ARGS_INTERVAL_MS":"250"}
    assert not env_drift(effective, expected, expected)
    assert "IT_BOOT_ARGS" not in boot_config_keys(properties.replace("return args", "return other"))
    assert "IT_BOOT_ARGS" not in boot_config_keys(properties.replace('with: ",,"', 'with: ","'))
    assert "IT_BOOT_ARGS_REPEAT" not in boot_config_keys(properties.replace("repeat=200", "repeat=unknown"))
    assert env_drift(boot_config_keys(properties.replace("repeat=200", "repeat=201")),
                     expected, expected) == {"IT_BOOT_ARGS_REPEAT": ("201", "200")}
    aliases = properties + '\n"IT_BOOT_ARGS_REPEAT": "999"'
    assert boot_config_keys(aliases)["IT_BOOT_ARGS_REPEAT"] == "200"
    assert boot_config_keys(properties.replace('test=1', 'test=1,more=2'))["IT_BOOT_ARGS"] == "test=1,more=2"
    print("env parity self-test passed")


def check_env_parity():
    app_src = open(os.path.join(APP, "LightTouchMac", "EmulatorController.swift")).read()
    app = boot_config_keys(app_src)
    harness_src = open(os.path.join(QEMU_IOS, "tests", "ipod", "regress.py")).read()
    m = re.search(r"def boot_env.*?return env", harness_src, re.S)
    harness = boot_config_keys(m.group(0)) if m else {}

    # Required effective boot configuration must agree, or one side
    # boots a device the other cannot. (Direct iBoot is now a machine property,
    # and IT_LCD_BRIGHT is a harness-only knob — its lit-pixel checks need full exposure, while the app
    # must show the real backlight or Lock looks dead — so none are compared.)
    required = ["IT_TVOUT_READY",
                "IT_BOOT_ARGS", "IT_BOOT_ARGS_DELAY_MS", "IT_BOOT_ARGS_REPEAT",
                "IT_BOOT_ARGS_INTERVAL_MS"]
    check("obsolete-env-absent", all(key not in app and key not in harness
          for key in ("IT_TVOUT_VBLANK", "IT_IMG3_SIG_ASIS")),
          "removed behavior switches stay absent")
    check("guest-reset-enabled", "IT_WDT_NORESET" not in app and
          "IT_WDT_NORESET" not in harness,
          "neither launcher suppresses guest watchdog reset commands")
    check("direct-boot-property", ",direct-iboot=" in app_src and ",direct-llb=" in app_src
          and '"IT_DIRECT_IBOOT":' not in app_src,
          "app selects direct boot explicitly without a process-wide environment mutation")
    check("boot-properties", all(
          "," + prop + "=" in app_src and '"' + alias + '":' not in app_src
          for prop, alias in (("boot-args", "IT_BOOT_ARGS"),
                              ("boot-args-delay-ms", "IT_BOOT_ARGS_DELAY_MS"),
                              ("boot-args-repeat", "IT_BOOT_ARGS_REPEAT"),
                              ("boot-args-interval-ms", "IT_BOOT_ARGS_INTERVAL_MS"))),
          "app sets boot configuration through startup properties")
    drift = env_drift(app, harness, required)
    check("env-parity", not drift,
          "app and harness effective boot configuration agree" if not drift
          else f"DRIFT (app, harness): {drift}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checks", default="env")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    selected = args.checks.split(",")
    print("LightTouchMac app regression")
    if "env" in selected:
        check_env_parity()
    print("=" * 50)
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        sys.exit(1)
    print("all app checks passed")


if __name__ == "__main__":
    main()
