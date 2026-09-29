# Early activation and AppSync — 2026-09-29

The built-in activation path now supports the inspected 1.x layouts without an opt-in.
Recognized pre-signing binaries remain unsigned; signed firmware still requires signature refresh.
A fresh n45 image initializes `-BrickState` to false in its own Lockdown preferences, the
independent state normally cleared by the first iTunes handshake. No imported identity,
activation record, user-selected hook, or host USB setup is needed.

3A101a (1.1): native preparation from the stock IPSW completes and reaches Home automatically.
4B1 (1.1.5): native recognizer, exact-byte/refusal, and unsigned policy verified against stock;
guest boot is not yet checked. Existing signed activation corpus checks still pass.
The private working HFS image is repaired and checked before editing because modern HFS tools
reject stale folder counts in the stock 1.x image. The original IPSW/cache remains untouched.
A hard-reset reboot of the 1G test hit its existing storage panic; this is not a reboot-fidelity claim.

AppSync uses a legacy-linked armv6 slice (classic relocations, r9 reserved) and the existing armv7
slice. 2.x installs through `mobile_installation_proxy`; Lockbot ignores EnvironmentVariables,
so the built-in `appsync-launch` sets the helper and execs the original service. Its explicit ARM
entry trampoline reads argc/argv from the stack. 3.0 uses the existing installd injection.
Standalone libmis stays stock: changing it prevented 2.1.1 startup. The standard emulator AMFI
boot arguments permit the ad-hoc app to execute; no additional SpringBoard hook is needed.

Evidence: fresh native 5F138 and 7A341 images install an ad-hoc ARMv6 UIKit smoke IPA and visibly
launch its green window and label. The AppSync-off 5F138 control rejects the identical IPA with
ApplicationVerificationFailed. These are decrypted/ad-hoc app tests, not FairPlay decryption or
an exhaustive game-compatibility pass. Other 2.x releases share the service path but need their
own compatibility runs. Catalog defaults now enable AppSync on 2.1.1, 2.2 and 2.2.1 (3.0 already did).

Integration: merge qemu-ios `early-appsync` (`e72fab4f9e`) and rebuild/export guest artifacts, then
merge LightTouchMac `legacy-activation-appsync`. The source pin includes that helper commit;
the USB protocol is unchanged. Both `libappsync.dylib` and `appsync-launch` are built/exported
internally. FirmwareKit rejects an armv6 helper with modern loader commands before baking it.
No preference or file picker is added.

Checks: activation ASan/UBSan fixtures; native activation/N45/early-AppSync/shared-cache regression
suite (13 tests); Python preparation checks for both service forms; shell/Python syntax checks.
Local guest evidence, creation logs, test IPA and screenshots: `/private/tmp/legacy-support/`.
The test helper location for fixture-backed tests is `FK_EARLY_APPSYNC_HELPERS`; this is only a
test harness input, not an application setting.
