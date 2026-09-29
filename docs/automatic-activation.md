# Automatic activation

Activation is built into preparation and completed automatically after the first lockdown response on each boot. There is no hook path, plugin, catalog activation option, or user action.

Preparation recognizes the stock daemon's local activation path, changes only that path, and refreshes its existing signature while retaining entitlements. Recognized unsigned 1.x daemons remain unsigned. `device.lock.json` records the input/output hashes and the actual recognized operation: strategy, ISA, file offset, original bytes and replacement bytes. Earlier records without this extra report remain readable. Unsupported or ambiguous code still fails without writing.

After boot, Light Touch uses its existing isolated lockdown helper to finish the guest's activation protocol. For an activated iPod running 1.x–3.x it sets and reads back `iTunesHasConnected`, independently of timezone and clock settings; an exposed true `BrickState` is a failure. Other activated devices set and read back `ActivationStateAcknowledged`. Missing or unactivated state causes no writes. Repeated completion does not rewrite matching values. Startup failures retry, and a failed completion leaves the next connection check eligible. A result from a previous boot cannot mark the current boot complete.

Known activation states are `Activated`, `FactoryActivated` and `WildcardActivated`. Arbitrary strings containing “Activated” no longer pass the state check. The existing compatibility exception for usable legacy devices whose services answer despite an Unactivated string remains.

## Prior art and boundaries

Legacy iOS Kit combines lockdownd patches with a cached FactoryActivated state for selected releases; its implementation is not a universal cached-state fix. We do not add that cache fallback without testing the affected stock daemon and reboot behavior. [Implementation](https://github.com/LukeZGD/Legacy-iOS-Kit/blob/main/restore.sh#L10826).

libideviceactivation separates the old iPod first-connection flag from activation acknowledgement. This implementation uses those guest protocol operations locally; it does not contact an activation server or import another device's records. [Protocol operations](https://github.com/libimobiledevice/libideviceactivation/blob/master/tools/ideviceactivation.c).

The additional should_hactivate patch in prior art remains a candidate for future firmware coverage, not a silently enabled byte-signature fallback. Current supported stock binaries already have a recognized path. [Patcher](https://github.com/overcast302/legacy-lockdownd-patch/blob/main/patch_lockdownd.py).

## Validation, 2026-09-29

Run `tests/activation/run.sh` with libimobiledevice/libplist available through pkg-config. It exercises the real plist protocol values with a simulated lockdown, sanitizer-backed binary recognition, the native signature/corpus tests, old-record decoding, and app boot retries. The protocol tests cover successful writes without successful readback, write failure, repeated application, unknown state and clock independence. Four Swift tests pass over the 12 local stock daemon fixtures. LightTouchMac Debug builds successfully.

Real guest checks use private overlays under `/private/tmp/activation-research/`:

- iPod 2.1.1: Activated; completion succeeds and iTunesHasConnected reads true. BrickState is not exposed by this daemon, so this does not claim a direct readback of that key.
- iPad 5.1.1: Activated; acknowledgement reads true; paired AFC round trip matches; Setup Assistant reaches Home. After a cold reboot of the same overlay, ActivationState remains Activated, ActivationStateAcknowledged remains true, and the 70,029-byte AFC marker matches exactly. A guest restart request did not establish a verified clean reboot; this is a cold-reboot persistence check. This image was originally prepared by the other agent's scratch hook. The current native recognizer finds the exact same branch and uses an equivalent NOP encoding, and its signature refresh passes the corpus test.
- Native 9B206 preparation applies built-in activation successfully, but full preparation is still blocked by unrelated integration gaps: the default AppSync signature matcher rejects the 9B206 function entry; with AppSync disabled in a disposable test entry, preparation reaches activation and then rejects the bundled armv7.itpack because it has no package for 9B206. The shipped catalog has not been weakened to hide either failure. The merged graphics sources also needed rebuilding; old helper artifacts cannot render 5.x correctly.

No additional firmware release is declared supported solely because its daemon matches. A release needs fresh offline preparation, usable UI, paired services and reboot persistence checks. A pre-existing image passing the host protocol test is not a fresh native preparation pass.
