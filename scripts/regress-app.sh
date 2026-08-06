#!/bin/bash
#
# App-level regression for LightTouchMac. Thin wrapper over regress_app.py,
# which reuses the qemu-ios harness. Needs the qemu-ios checkout + images.
#
#     scripts/regress-app.sh                 # all checks
#     scripts/regress-app.sh --checks env    # fast, device-free
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/regress_app.py" "$@"
