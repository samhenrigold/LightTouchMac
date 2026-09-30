# Conventional developer access

This opt-in tool delegates to the host's OpenSSH/SFTP clients and libusbmuxd's
`inetcat`; it implements no guest file, command or debugger protocol. It does
not modify NAND, provision an SSH server, enable QEMU's GDB stub, or change the
app's USB endpoint. Compile once:

```sh
swiftc tools/device-access/main.swift -o /tmp/ltm-device-access
```

Supply the selected device's instance UUID and its **current private usbmuxd
client endpoint** (`USBMux.Session.clientSocket`). The endpoint changes when a
new session starts. Use the client endpoint, not the guest TCP USB endpoint;
never substitute the system usbmuxd socket. The app does not yet publish these
values as a developer connection profile.

```sh
/tmp/ltm-device-access ssh \
  --instance 7DCECEB7-1B4C-4F12-9F9D-3B4F93F5BA45 \
  --usbmux 127.0.0.1:27017 --inetcat /opt/homebrew/bin/inetcat \
  --identity /absolute/path/to/developer-key
```

Replace `ssh` with `sftp` for interactive file access. After SSH options, `--`
passes a remote command with standard OpenSSH remote-shell semantics. `config`
emits a conventional SSH configuration; save it and use `ssh -F FILE HOST`,
`sftp -F FILE HOST`, or SSHFS's `ssh_command` option. SSHFS/Finder mounting needs
a compatible separately installed filesystem implementation; this tool does
not mount a live raw NAND image. Regenerate saved profiles after restarting the
session.

The tool pins the loopback endpoint inside each ProxyCommand and uses
`HostKeyAlias=lighttouch-<instance UUID>` with a separate known-hosts file in
`~/Library/Application Support/Light Touch/DeveloperSSH/<UUID>/`. Normal host-key
verification remains enabled. Confirm a first key against the provisioned
instance; a changed key must be investigated. `--identity` restricts auth to the
specified key. Without it, standard SSH authentication applies. There are no
embedded passwords or shared keys. `--state /absolute/private/directory`
overrides the known-hosts location.

For system debugging, enable a **loopback-only** QEMU stub explicitly when
running a development emulator, for example `-gdb tcp:127.0.0.1:1234`. Add `-S`
only if you want the CPU initially stopped. This command emits a standard GDB
command for the supplied stub:

```sh
/tmp/ltm-device-access gdb \
  --instance 7DCECEB7-1B4C-4F12-9F9D-3B4F93F5BA45 \
  --gdb 127.0.0.1:1234
# target remote 127.0.0.1:1234
```

The UUID here is an explicit user-selected association; unauthenticated QEMU
GDB has no instance-identity handshake. This is kernel/ROM/system debugging,
not an automatically provisioned guest `debugserver` or LLDB session. The GUI
helper currently does not expose a GDB launch setting.

## Guest provisioning still required

A supported developer package needs a compatible `sshd`, SFTP server, shell and
runtime dependencies, a dedicated launchd job, per-instance generated host keys,
and the developer's authorized public key. Test each supported old dyld/ABI and
use the project's existing signing/guest-package policy. Do not copy the old
`qemu-ios-files/ssh` image's shared keys, default password, disabled ownership
checks, fixed boot-args address or cache patches. The current guest package does
not contain SSH; OpenSSH sources were not present to build a verified package.
