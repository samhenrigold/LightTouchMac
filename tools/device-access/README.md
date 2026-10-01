# Conventional developer access

Enable developer SSH for a supported instance from a development checkout:

```sh
./tools/device-access/enable.sh INSTANCE-UUID
```

This fetches pinned historical upstream tools into private host state and opts
in the selected instance. Restart it; the app composes its developer offer and
creates unique private host/client keys automatically. Supported live-tested
profiles: K48 iOS 3.2.2/7B500 and N72 iOS 3.1.3/7E18. Release bundling is gated by the source/license audit in
[the payload notes](../developer-packages/README.md).

Compile the host wrapper once:

```sh
swiftc tools/device-access/main.swift -o /tmp/ltm-device-access
/tmp/ltm-device-access ssh --instance INSTANCE-UUID
/tmp/ltm-device-access sftp --instance INSTANCE-UUID
/tmp/ltm-device-access sftp --instance INSTANCE-UUID --batch /absolute/batch-file
```

The app writes `DeveloperSSH/<UUID>/connection.json` during an active session and
retires its own profile on stop. The wrapper checks the instance identity and
uses that private usbmuxd endpoint, bundled inetcat, generated `id_ecdsa`, and
pinned `known_hosts`. It never changes the process-global endpoint. Standard
OpenSSH owns authentication and remote-shell semantics; `-- COMMAND` passes a
remote command. The separate QEMU debugger uses `gdb --instance UUID` when its
endpoint is included, or `gdb --instance UUID --gdb 127.0.0.1:PORT`.

`disable --instance UUID` removes the opt-in; restart to stop sshd and revert its
package hooks. The app's built-in safe mode bypasses all developer augmentation.
State defaults to `~/Library/Application Support/Light Touch/DeveloperSSH`.
`--state`, `--usbmux`, `--inetcat`, and `--identity` remain explicit diagnostic
overrides. A manually configured server without generated pinning follows
normal OpenSSH first-contact host-key confirmation.

`config` emits standard SSH configuration for other clients. SSHFS/Finder needs
a separately installed compatible filesystem; this helper does not mount raw
live NAND. Keys are isolated per instance, and session endpoints are refreshed
each boot. The deprecated historical shell bootstrap and shared keys are not
used.
