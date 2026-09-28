#!/bin/sh
# Builds the phase 0 spike binaries into spikes/.build and signs them.
#   SIGN_ID="Developer ID Application: Sam Gold (SM75355Y6R)" (default) or SIGN_ID=- for ad-hoc
set -eu
cd "$(dirname "$0")"
OUT=.build; mkdir -p $OUT
ID="${SIGN_ID:-Developer ID Application: Sam Gold (SM75355Y6R)}"
ENT="$HOME/Developer/qemu-ios-ipad1/contrib/macos-app/entitlements.plist"
SW="swiftc -O -import-objc-header shim.h -swift-version 5 -lbsm"
clang -O -c mach.c -o $OUT/mach.o
$SW $OUT/mach.o Shared.swift host/main.swift -o $OUT/spike-host
$SW $OUT/mach.o Shared.swift device/main.swift -o $OUT/LightTouchDevice
codesign -f -o runtime --timestamp=none -s "$ID" --identifier gold.samhenri.LightTouchMac.spikehost $OUT/spike-host
codesign -f -o runtime --timestamp=none -s "$ID" --identifier gold.samhenri.LightTouchMac.LightTouchDevice --entitlements "$ENT" $OUT/LightTouchDevice
# Impostors for the rejection tests: same code, ad-hoc and other-team signatures.
cp $OUT/LightTouchDevice $OUT/LightTouchDevice-adhoc
codesign -f -o runtime -s - --entitlements "$ENT" $OUT/LightTouchDevice-adhoc
if security find-identity -v -p codesigning | grep -q U3A5RKDN46; then
  cp $OUT/LightTouchDevice $OUT/LightTouchDevice-otherteam
  codesign -f -o runtime --timestamp=none -s "Developer ID Application: Nealfun Inc (U3A5RKDN46)" --entitlements "$ENT" $OUT/LightTouchDevice-otherteam
fi
codesign -dv --entitlements - $OUT/spike-host $OUT/LightTouchDevice 2>&1 | grep -E "Executable|flags|Authority=Developer|TeamIdentifier|allow|disable" || true
