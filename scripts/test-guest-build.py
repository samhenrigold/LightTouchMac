#!/usr/bin/env python3
"""build-guest-tools.sh is a thin caller of qemu-ios contrib/export-guest-artifacts.sh: it resolves the pinned
checkout (QEMU_IOS_DIR overrides), checks the SDK, refuses an existing output directory and a checkout without
the export, hands the directory to the export, and publishes nothing itself. A fixture export stands in for
the real one (which needs the armv6 toolchain and both SDKs; the release build runs it)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile


SCRIPT = Path(__file__).with_name("build-guest-tools.sh")
FIXTURE_EXPORT = r'''#!/bin/bash
set -eu
OUT="$1"
[ ! -e "$OUT" ] || { echo "use a new output directory" >&2; exit 1; }
[ -n "${ARMV6_SDK:-}" ] || { echo "no ARMV6_SDK" >&2; exit 1; }
[ "$#" -eq 1 ] || { echo "unexpected arguments: $*" >&2; exit 1; }
if [ "${EXPORT_FAIL:-}" = 1 ]; then echo "intentional failure" >&2; exit 7; fi
mkdir -p "$OUT/guest-tools" "$OUT/ipad-guest-tools"
printf rebuilt > "$OUT/guest-tools/it_agent"
printf rebuilt > "$OUT/ipad-guest-tools/it_pbd"
printf '{"schema": 1, "files": {"guest-tools/it_agent": "x", "ipad-guest-tools/it_pbd": "x"}}\n' > "$OUT/manifest.json"
'''


with tempfile.TemporaryDirectory(prefix="lighttouch guest test ") as directory:
    root = Path(directory)
    qemu = root / "qemu source"
    (qemu / "contrib").mkdir(parents=True)
    export = qemu / "contrib/export-guest-artifacts.sh"
    export.write_text(FIXTURE_EXPORT)
    sdk = root / "old sdk"
    (sdk / "usr/lib").mkdir(parents=True)
    (sdk / "usr/lib/libSystem.dylib").write_text("fixture\n")
    environment = dict(os.environ, QEMU_IOS_DIR=str(qemu), ARMV6_SDK=str(sdk))

    def build(work, *, error=None, env=None):
        result = subprocess.run(["bash", str(SCRIPT), str(work)], env=env or environment, capture_output=True, text=True)
        if error:
            assert result.returncode != 0 and error in result.stderr, result
        else:
            assert result.returncode == 0, result.stderr
        return result

    output = root / "build output"
    result = build(output)
    assert (output / "guest-tools/it_agent").read_text() == "rebuilt"
    assert (output / "ipad-guest-tools/it_pbd").read_text() == "rebuilt"
    assert json.loads((output / "manifest.json").read_text())["schema"] == 1
    assert f"LTM_GUEST_TOOLS_DIR={output}/guest-tools".replace(" ", "\\ ") in result.stdout, result.stdout
    build(output, error="use a new build directory")

    failed = root / "failed build"
    build(failed, error="intentional failure", env=dict(environment, EXPORT_FAIL="1"))
    assert not (failed / "guest-tools").exists()

    build(root / "no sdk", error="set ARMV6_SDK", env=dict(environment, ARMV6_SDK=""))
    build(root / "bad sdk", error="missing SDK input", env=dict(environment, ARMV6_SDK=str(root)))
    export.unlink()
    build(root / "no export", error="no contrib/export-guest-artifacts.sh")
    for name in ("no sdk", "bad sdk", "no export"):
        assert not (root / name).exists(), f"preflight failure created {name}"

print("PASS: the thin caller resolves the checkout and SDK, hands a fresh directory to the export, and publishes nothing on failure")
