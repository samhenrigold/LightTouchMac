# Built-in legacy iOS activation

Light Touch always activates devices during FirmwareKit system preparation. The recognizer is statically linked into FirmwareKit from `Packages/FirmwareKit/Sources/CActivation`; Swift refreshes the code signature while preserving entitlements. There is no hook path, preference, catalog switch, or separate shipped executable.

The command-line wrapper here is only for developer diagnostics and sanitizer tests. It uses the same C source, but does not sign its output.

## Light Touch integration

## Build and use

```sh
./tools/activation/build.sh --universal  # macOS arm64 + x86_64; omit flag for native cc
./tools/activation/build/lt-activation --probe /path/to/stock/lockdownd
./tools/activation/build/lt-activation /path/to/staging/lockdownd
./tools/activation/test.sh
```

Probe mode never writes. Apply mode requires one unambiguous match, writes a temporary sibling file,
then renames it over the input, retaining permission bits. Symlinks, malformed/unsupported executables,
ambiguous matches, and repeated application are refused. Reports contain strategy, ISA, discovered
address/offset, and original/replacement bytes. Exit status is 0 for success, 1 for refusal/error, 2 for
incorrect arguments. Input is a thin little-endian 32-bit ARM Mach-O executable.

The diagnostic CLI does not sign. FirmwareKit preserves entitlements and re-signs automatically.

## Strategies

- **Development activation shortcut:** recognizes the function-name string and activation log message,
  tracks a restricted set of literal loads, PC-relative additions and immediate construction, and checks
  the guarded control flow. Supports ARM and Thumb, direct strings and constant CFStrings, narrow and
  wide branches, and both forward and backward layouts. It enables the firmware's existing local
  activation path. Register allocation and addresses need not match a particular build.
- **Legacy no-record initializer (experimental):** for the inspected 1.x/2.x implementations, recognizes
  the `determine_activation_state` context, the no-record initializer, zeroed temporary references,
  state storage and its control flow. Redirects the state load to the firmware's existing `Activated`
  CFString and clears the associated brick boolean. It does not rewrite shared string objects or disable
  record verification. This has static validation only and cannot be applied accidentally: it requires
  `--experimental-legacy`. Probe mode reports it without that flag.

The instruction decoder is intentionally limited to the operations needed to establish these patterns.
Unknown code fails closed. `compatibility.json` records observations and hashes; the tool does **not**
use its addresses, hashes, product names, or build numbers as a patch lookup table.

## Compatibility evidence

| Device / version | Build | Evidence |
|---|---|---|
| iPod touch 1 / 1.1.5 | 4B1 | Experimental legacy pattern; exact-byte and refusal checks only |
| iPod touch 2 / 2.1.1 | 5F138 | Experimental legacy pattern; exact-byte and refusal checks only |
| iPod touch 2 / 3.0 | 7A341 | Native probe/apply and exact-byte/repeat checks |
| iPod touch 2 / 3.1.1 | 7C145 | Same |
| iPod touch 2 / 3.1.2 | 7D11 | Same |
| iPod touch 2 / 3.1.3 | 7E18 | **Fresh image: home, pairing, AFC, clean shutdown, reboot, persisted file** |
| iPad 1 / 3.2 | 7B367 | Native probe/apply and exact-byte/repeat checks |
| iPad 1 / 3.2.2 | 7B500 | Same patch bytes as the earlier successful offline home/reboot experiment |
| iPod touch 2 / 4.2.1 | 8C148 | Native probe/apply and exact-byte/repeat checks; NAND boot blocker is separate |
| iPad 1 / 4.2.1 | 8C148 | Same patch bytes as the earlier successful offline home/reboot experiment |
| iPad 1 / 5.1.1 | 9B206 | Native probe/apply and exact-byte/repeat checks; no emulator boot validation |
| iPhone 3GS / 6.1.6 | 10B500 | Same; no emulator boot validation |

This is coverage of these **12 binaries**, not every release or beta between 1.1.5 and 6.1.6. Static
recognition cannot establish that SpringBoard, pairing, or a particular device's activation requirements
are satisfied. The early strategy remains experimental until a compatible emulator can exercise it.

The 7E18 test starts with a stock-IPSW-derived image, generated identity and NOR, and no imported
Lockdown directory. It uses no Wi-Fi/netdev; USB is a private local test bridge. Both home screenshots
were checked visually. Pairing succeeded; AFC round trips passed SHA-256 comparisons at 1, 1000, 4096,
65535, and 262143 bytes; a written file survived a clean shutdown and reboot. Both guests exited 0.
The final tool produces the same ARM patch bytes used in that boot test.

`test.sh` builds synthetic Mach-O fixtures under AddressSanitizer and UndefinedBehaviorSanitizer. Tests
cover ARM/Thumb, register variation, literal/PIC/CFString arguments, MOVW/MOVT, both wide-branch layouts,
both legacy initializers and their explicit opt-in, exact writes, read-only probing, mode preservation,
ambiguity, repeat application, malformed/truncated headers and symlinks. No Apple firmware is shipped
in the source tree or tests. Real-firmware hashes and exact observed patches are in `compatibility.json`.

## Artifacts and next work

Preserved local evidence and the working iPod image live at:
`/Users/shg/Developer/qemu-ios-files/activation-native/`.
The two iPad experiments remain in `ipad1/offline-activation/` and `ipad1/offline-activation-8C148/`.

Next useful checks are early 1.x/2.x guest activation once those platforms boot, and iOS 5/6 UI + pairing
validation when their emulation is ready. New builds should first pass `--probe`, then a fresh offline
boot and persistence test. Add a recognition strategy when behavior differs; do not loosen a matcher
merely to make an unsupported binary pass.
