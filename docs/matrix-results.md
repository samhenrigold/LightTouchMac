# Matrix results

Produced by `tests/matrix.py` (docs/matrix.md has the builds). Prepare = `firmwarekit create` as the app runs it; lit,
lockdown, AFC, install, package, persist and shutdown come from tests/session-driver `--single` with a second boot on
the same overlay. Screenshots and logs per entry are outside the repo (`screenshots` in matrix-results.json).
GL counters are skipped until qemu-ios gl-coverage merges. Last write 2026-09-29 01:07 UTC.

| Entry | iOS | Keys | Prepare | Lit | Lockdown | Activation | AFC | Install | Package | GL | Persist | Shutdown | Restore | First failure |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| k48ap-7B367 | 3.2 | 19/19 | ok 74.6 s | ok 18.2 s | ok 0.8 s | ok Activated | ok 4/4 | ok 3 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 20.7 s) | ok 15.4 s | - |  |
| k48ap-7B405 | 3.2.1 | 19/19 | ok 81.3 s | ok 25.1 s | ok 5.4 s | ok Activated | ok 4/4 | ok 5 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 21.2 s) | ok 15.1 s | - |  |
| k48ap-7B500 | 3.2.2 | 19/19 | ok 81.9 s | ok 27.3 s | ok 5.5 s | ok Activated | ok 4/4 | ok 2 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 74.7 s) | FAIL 16.1 s | - | **shutdown**: The device helper exited unexpectedly (code 0).<br>`AppleBCMWLAN Joined BSS:     @ 0xc5235000, BSSID = 02:00:5e:10:00:01, rssi = -45, rate = 11 (100%), channel =  6, encryption = 0x1, ap = 1, failures =   0, age = 0, ssid[ 8] = "qemu-ios"`<br>`[42.761860000]: AppleBCMWLANNetManager::handleDelayedPowerManagementTimeout(): Timed out waiting for IP address, entering powersave mode: 0`<br>`USB mux: 260 reads / 0 errors, 183 writes / 0 errors` |
| k48ap-8C148 | 4.2.1 | 18/18 | ok 83.5 s | ok 34.9 s | ok 0.9 s | ok Activated | ok 4/4 | ok 2 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 21.4 s) | ok 15.7 s | - |  |
| k48ap-8F190 | 4.3 | 18/18 | FAIL 30.2 s | - | - | - | - | - | - | - | - | - | - | **prepare**: oneshot_failed: keybag boot: panic(cpu 0 caller 0x80996535): "IOP: startup ping failed"@/SourceCache/EmbeddedIOP/EmbeddedIOP-20.4/EmbeddedIOP.cpp:221<br>`firmwarekit: oneshot_failed: keybag boot: panic(cpu 0 caller 0x80996535): "IOP: startup ping failed"@/SourceCache/EmbeddedIOP/EmbeddedIOP-20.4/EmbeddedIOP.cpp:221` |
| k48ap-8G4 | 4.3.1 | 16/16 | FAIL 12.1 s | - | - | - | - | - | - | - | - | - | - | **prepare**: internal: The file “038-0894-005-ramdisk.dmg” couldn’t be opened because there is no such file.<br>`firmwarekit: Error Domain=NSCocoaErrorDomain Code=260 "The file “038-0894-005-ramdisk.dmg” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/shg/Developer/qemu-ios-files/m` |
| k48ap-8H7 | 4.3.2 | 16/16 | FAIL 9.3 s | - | - | - | - | - | - | - | - | - | - | **prepare**: internal: The file “038-1031-007-ramdisk.dmg” couldn’t be opened because there is no such file.<br>`firmwarekit: Error Domain=NSCocoaErrorDomain Code=260 "The file “038-1031-007-ramdisk.dmg” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/shg/Developer/qemu-ios-files/m` |
| k48ap-8J3 | 4.3.3 | 16/16 | FAIL 11.9 s | - | - | - | - | - | - | - | - | - | - | **prepare**: internal: The file “038-1437-004-ramdisk.dmg” couldn’t be opened because there is no such file.<br>`firmwarekit: Error Domain=NSCocoaErrorDomain Code=260 "The file “038-1437-004-ramdisk.dmg” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/shg/Developer/qemu-ios-files/m` |
| k48ap-8K2 | 4.3.4 | 16/16 | FAIL 16.9 s | - | - | - | - | - | - | - | - | - | - | **prepare**: internal: The file “038-2175-001-ramdisk.dmg” couldn’t be opened because there is no such file.<br>`firmwarekit: Error Domain=NSCocoaErrorDomain Code=260 "The file “038-2175-001-ramdisk.dmg” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/shg/Developer/qemu-ios-files/m` |
| k48ap-8L1 | 4.3.5 | 16/16 | FAIL 14.4 s | - | - | - | - | - | - | - | - | - | - | **prepare**: internal: The file “038-2268-002-ramdisk.dmg” couldn’t be opened because there is no such file.<br>`firmwarekit: Error Domain=NSCocoaErrorDomain Code=260 "The file “038-2268-002-ramdisk.dmg” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/Users/shg/Developer/qemu-ios-files/m` |
| n72ap-5F138 | 2.1.1 | 14/14 | FAIL 0.0 s | - | - | - | - | - | - | - | - | - | - | **prepare**: unsupported: n72ap-5F138: no n72 recipe for storage none<br>`firmwarekit: unsupported: n72ap-5F138: no n72 recipe for storage none` |
| n72ap-5G77a | 2.2 | 14/14 | FAIL 0.0 s | - | - | - | - | - | - | - | - | - | - | **prepare**: unsupported: n72ap-5G77a: no n72 recipe for storage none<br>`firmwarekit: unsupported: n72ap-5G77a: no n72 recipe for storage none` |
| n72ap-5H11a | 2.2.1 | 14/14 | FAIL 0.0 s | - | - | - | - | - | - | - | - | - | - | **prepare**: unsupported: n72ap-5H11a: no n72 recipe for storage none<br>`firmwarekit: unsupported: n72ap-5H11a: no n72 recipe for storage none` |
| n72ap-7A341 | 3.0 | 19/19 | ok 21.2 s | FAIL | FAIL | FAIL ? | FAIL 0/4 | FAIL | FAIL serial None rNone | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | FAIL | FAIL | - | **lit**: ipod never lit |
| n72ap-7C145 | 3.1.1 | 19/19 | ok 33.0 s | ok 9.1 s | ok 11.5 s | ok Activated | ok 4/4 | ok 4 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 18.4 s) | ok 1.8 s | - |  |
| n72ap-7D11 | 3.1.2 | 19/19 | ok 47.9 s | ok 9.6 s | ok 17.0 s | ok Activated | ok 4/4 | ok 2 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 9.8 s) | ok 1.3 s | - |  |
| n72ap-7E18 | 3.1.3 | 19/19 | ok 30.6 s | ok 25.6 s | ok 23.8 s | ok Activated | ok 4/4 | ok 2 s | ok serial 3 r0 | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 11.8 s) | ok 1.6 s | - |  |
| n72ap-8A293 | 4.0 | 17/17 | ok 46.4 s | ok 20.8 s | ok 18.8 s | ok Activated | ok 4/4 | ok 2 s | skip (itpack has no package for this build (GuestPackage.compose: nil)) | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 20.4 s) | ok 0.8 s | - |  |
| n72ap-8A400 | 4.0.2 | 18/18 | ok 48.0 s | ok 22.5 s | ok 16.3 s | ok Activated | ok 4/4 | ok 2 s | skip (itpack has no package for this build (GuestPackage.compose: nil)) | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 19.6 s) | ok 0.9 s | - |  |
| n72ap-8B117 | 4.1 | 18/18 | ok 49.7 s | ok 21.5 s | ok 10.4 s | ok Activated | ok 4/4 | ok 4 s | skip (itpack has no package for this build (GuestPackage.compose: nil)) | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 35.4 s) | ok 1.5 s | - |  |
| n72ap-8C148 | 4.2.1 | 18/18 | ok 74.5 s | ok 23.9 s | ok 12.0 s | ok Activated | ok 4/4 | ok 2 s | skip (itpack has no package for this build (GuestPackage.compose: nil)) | skip (skipped: qemu-ios gl-coverage not merged (no counters)) | ok (boot 2 lit 22.0 s) | ok 0.8 s | - |  |

## Triage

(a) a generic pipeline/emulator fix, (b) per-build data for the catalog entry, (c) real emulator or guest-tool work.
Set with `tests/matrix.py --triage ENTRY "text"`.

- **k48ap-7B405**: pass on the first run: catalog entry only.
- **k48ap-7B500**: pass (merged tree 21:05): boot 1's quit was labelled 'helper exited unexpectedly (code 0)' although power-off confirmed in 16 s and the helper exited 0; boot 2 read 'The emulator stopped.' Reason-string race in the new DeviceLink reap path (multidevice a2d4a92), not a boot problem.
- **k48ap-8F190**: (c) iOS 4.3: prepare gets past the GL layout (stock engine fallback, generic fix committed: the 4.3.x GLI table has 870 slots, none of the shipped shims fit -> a GLEngine-8F190 build or the runtime shim of PLAN C1 is the per-build data debt), then the keybag one-shot boot of the 4.3 kernel (xnu-1735, EmbeddedIOP-20.4) panics 'IOP: startup ping failed' (EmbeddedIOP.cpp:221) three times: the s5l8930 IOP HLE answers the 4.2.1 handshake, not 4.3's. Evidence: matrix-results/k48ap-8F190/firmwarekit.log. Estimate 1-2 d emulator work (hw/arm/s5l8930_iop.c: the 4.3 startup ping / mailbox protocol), then re-check the GL table. Blocks iOS 4.3.x and, very likely, iOS 5.
- **k48ap-8G4**: (no keys) 4.3.1: The Apple Wiki has no Restore/Update ramdisk keys, so the data-protection keybag step has no ramdisk to boot (the decryptor skips keyless components with a warning). Would then hit 8F190's IOP panic. Needs the ramdisk keys from another public source or the keybag built another way.
- **k48ap-8H7**: (no keys) as 8G4.
- **k48ap-8J3**: (no keys) as 8G4.
- **k48ap-8K2**: (no keys) as 8G4.
- **k48ap-8L1**: (no keys) as 8G4.
- **n72ap-7C145**: pass on the first run: catalog entry only (7E18 GL layout, shim reused).
- **n72ap-7D11**: pass on the first run: catalog entry only (7E18 GL layout, shim reused).
