# October 1 fidelity continuation

The work remains on `reuse-implementation` in the isolated Light Touch,
QEMU and usbmuxd worktrees. No merge, publish, installed-app replacement or
Finder virtual-USB entitlement work occurred. Requested local targets and main
changes are incorporated; the final upstream refresh was at 11:28 UTC. The
rewritten remote ipad1 history was inspected and not blindly merged.

## User-visible fixes

Music import reads source tags and embedded artwork before raw AAC conversion,
and includes those source fields in import identity. Native production Swift →
service worker → AFC → guest MusicLibrary/ArtworkCache tests retain all twelve
tag fields, stock-decoded art and exact millisecond duration. Six source formats
are covered; duplicate import remains one item. Fractional NSNumber durations
retain whole milliseconds rather than disappearing. MP3/M4A payloads remain
byte-identical. Cold reboot retains the tested tags/art/duration and duplicate
identity. Old entries already imported without their source metadata need
removal and reimport; no host-side MusicLibrary database writer was introduced.

Developer tools now use one pinned, source-complete legacy Bash build across
qualified 2.x–4.x builds. Actual SSH and binary SFTP pass on 5F138, 7A341, 7E18,
8C148 and 7B500. The iPod builds additionally pass production-loader install and
cold persistence with the original per-instance keys. Automatic package revision
selection upgrades earlier developer offers. It does not require the QEMU
runtime shim or old private startup object. Source, patch, SDK-input and payload
hashes are recorded and source/license/tamper checks pass. This is an opt-in
terminal/debug facility; ordinary activation remains automatic.

Shared legacy-linked core helpers, stock 2.x launch-API selection and correctly
signed guest hooks close the absent 2.x/3.0 helper seam. All four iPod firmware
versions pass actual installed-app foreground, automatic activation, Home,
four factory identity fields, file/app cold persistence and two guest-confirmed
power-offs: **18/18 each** through the packaged production app components.

## Smaller and more faithful hardware paths

- Removed the iBoot Bluetooth UART-path literal rewrite. The combo-chip CIS/OTP
  and HCI hardware models supply identity; all four iPod lifecycle gates and
  network-disabled identity/snapshot controls pass without changing iBoot bytes.
- Removed 477 lines of fixed-address TCG guest libc interception and its public
  controls. Guest instructions execute normally; default iPod boot, graphics,
  audio, services, app and filesystem gates pass. No performance gain is claimed.
- Kept the soldered BCM4325/4329 and host controllers present when networking is
  disabled. The switch controls host bridging. Production-board enumeration,
  CIS, reset, bridge controls and native no-NIC identity/snapshot tests pass.
- Migrated FMSS authoritative physical-page/erase maps using QEMU's existing
  GTree VMState serializer. Clear incoming state, validate coordinates/modes,
  rebuild derived indexes and restore IRQ. Native save/new-process resume passes
  identity/files/USB/clock/live GL, with separate audio and new HTTP-request
  checks. Existing host TCP connection migration remains unqualified.
- Repaired the iPad audio oracle: read stock reference sounds from the actual
  tested guest before shutdown, reuse the shared Boot owner, and require explicit
  matching rootfs references for old images without an agent. Full stock 7B500
  default regression passes **9/9**, including four sounds. The standalone sound
  check passes too. Other version selectors and stereo order remain separate.
- Traced N72 DFU using real SecureROM and the existing emulator-only libirecovery
  transport. Stock iBSS uploads unchanged and reaches recovery. Real guest ECID
  reads exposed two zero chip-ID fuse words; configurable read-only fuse inputs
  allow stock ROM/iBSS to report a matching ECID and stock idevicerestore to select
  the target. Guest stores/reset preserve the fuses. Automatic N72 identity
  provisioning and the subsequent old-IPSW host suitability check remain open.

The exact N72 restore evidence and fuse layout are in QEMU's
`docs/research/n72-dfu-recovery.md`; no completed iPod restore is claimed.

## Qualification and release limits

The clean universal ad-hoc bundle built from app `8ba30bc`, QEMU `a5e2c8c529`
and usbmuxd `e19fac2` passed every source/license/binary hygiene check, 32 release
provenance tests and the four native iPod lifecycle runs above. The small ECID
follow-up is tested separately before repinning/rebuilding; build receipts name
which exact source revision an artifact contains. Host arm64 and x86_64 slices
build, but runtime evidence is on native arm64. Developer ID signing,
notarization, Intel runtime and oldest-supported-macOS execution are not implied.

Before ECID, ten production model suites passed with no skips. The ECID addition
raises that gate to **eleven**, also without skips. Required default iPod tests
are rerun after each hardware change. Test logs retain failed first experiments
and distinguish harness inputs from guest/model failures.

## Highest-value remaining work

1. **Physical restore/storage:** retire generated N72 FTL relocation/free-pool
   shortcuts through stock blank-chip restore. K48 blank-NAND erase restore
   already passes, but cold stock graphics does not. Per-operation crash atomicity,
   encryption and N45/K48 stopped-edit format support remain open. The stopped
   N72 transaction boundary already preserves originals, leases, generation and
   stale-snapshot rejection; do not bypass it with direct live NAND edits.
2. **GPU:** identify the producer of the restored K48 kernel's polled DRAM word
   and decode SGX/MBX command formats. No fake completion. ANGLE's ES1 prototype
   passes exact pixels and sharegroups but K48 ES2 composition/legacy rectangles
   do not; CGL remains the qualified backend, with no adoption-benefit claim.
3. **Boot/power/clock:** retire the N72 RAM command-line compatibility injection
   using the actual stock handoff contract. NOR NVRAM reads succeed; empty
   boot-args are not evidence of SPI failure. N45 retained-RAM hibernate wake,
   watchdog divider/counter behavior and remaining clock consumers/gates need
   measured contracts. Do not invent timings from a stalled boot.
4. **Guest/host seams:** automatic per-unit N72 ECID provisioning, old stock
   host-tool restore metadata compatibility, K48 UART3/CDMA Bluetooth wiring,
   and older-version typing/clipboard/media proofs. Keep required activation in
   internal provisioning, GUI presentation in Light Touch and runtime guest
   writes behind guest services. 1.x/5.x developer shell and additional boot
   families need their own proof.
5. **Acceptance breadth:** exact storage generation/mode guards remain essential
   for snapshots; already-open host TCP and unsupported formats must not gain
   accidental acceptance. Extend high-risk DMA/IRQ/reset coverage as traces
   identify contracts. Future Retina boards, telephony and Siri are new hardware
   scope, not cleanup of the current devices.

Current detailed classifications, prior report dispositions and retained
acceptance seams are in [remaining work](remaining-work-2026-09-30.md) and the
[fidelity ledger](fidelity-ledger.md). The residual GPU, physical FTL and power
contracts prevent any honest claim that all firmware now runs unmodified.
