# iPod touch 2G / 2.1.1 activation

The original experimental recognizer patched a factory-cache fallback that the fresh device never executed. A GDB trace of stock 5F138 lockdownd instead reaches the earlier no-record block, guarded by a null record and the diagnostic `There is no activation record?`. That block jumps to a shared state store. The corrected recognizer proves this structure, reuses the existing Activated constant, and clears the brick flag. It does not depend on fixed firmware addresses.

The 2.x strategy now runs automatically in FirmwareKit and the diagnostic CLI. The 1.x strategy remains experimental. No user activation setting or path is introduced.

## Verification

- Fresh IPSW-derived 5F138 device, generated identity, empty writable overlay, `aes-uid=engine`, emulator from `qemu-ios-ipod-211` with the audio fix f2ec3285e4.
- Paired `ideviceinfo -k ActivationState` returns `Activated` on both the first boot and a second boot using the same overlay. `idevicepair validate` succeeds after the second boot.
- No kernel panic observed. The second boot followed QMP quit; this is not evidence of clean guest shutdown (2.1.1 did not expose diagnostics relay restart).
- The activation screen is gone, but the observed screen has only the status bar. A usable home screen is **not verified**. Investigate this in the graphics/integration pass; activation state alone does not establish UI rendering or interaction.
- Native ASan/UBSan tests pass, including rejection of altered guards, diagnostics, and shared stores. FirmwareKit tests cover activation and signature hashes for 11 supported local corpus binaries. The 12-binary CLI corpus preserves all other exact patch hashes, with 1.x tested using its existing experimental flag.

Local evidence: `/private/tmp/activation-211/` (`device/`, `state.log`, `activation-state.txt`, `activation-state-boot2.txt`, `boot1-serial.log`, `fresh-serial.log`, `fresh.ppm`, and test logs). Firmware bytes are not checked in.

For the existing Python image builder, use this branch's `tools/activation/build/lt-activation` diagnostic executable as the builder's activation tool. No `--experimental-legacy` argument is needed for 5F138. Light Touch's built-in FirmwareKit path links the same recognizer directly.
