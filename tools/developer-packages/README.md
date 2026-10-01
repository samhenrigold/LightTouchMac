# Historical developer payload

`fetch.sh` produces four files for standard developer SSH/SFTP: OpenSSH6.7p1's
sshd/SFTP server, OpenSSL0.9.8zg libcrypto, and a minimal source-built Bash4.0.40.
It pins Legacy-iOS-Kit revision `2f818780e5c808b09c3497f1745dde1bdce8e372` and two
archive hashes for the BSD/OpenSSL binaries. FirmwareKit independently pins each
file hash; a modified download manifest cannot authorize modified binaries.
No freeze bootstrap, readline/history/ncurses dylibs, old activation/libmis
patches, shared-cache edits, boot-address installers, package manager, or
pre-generated keys are included. Fetch failure never publishes a destination.

Bash is built from the official GNU4.0 source and all40 official patches, with
readline/history/NLS disabled. `bash-source.sha256` pins every input.
`build-shell.sh` retains the complete source archive, patches, port/build
recipes, toolchain receipts and GPL notice beside its output. GNU's old build
host recognizer needs one arm64 `config.sub` entry. C89 compiler mode and
historical SDK headers avoid introducing newer libc APIs. A private SDK libgcc
link input is annotated with the IOS platform tag modernld requires; the guest
uses its unchanged stock libgcc. The SDK's stock ARMv6 crt1.3.1 startup object is
used, rather than linking custom QEMU startup C into the GPLv3 Bash executable.
A standard linker symbol alias selects this startup; modernld otherwise ignores
its reserved raw `start` name and enters `main` without environment setup. The compiler reserves r9, which iOS2.x uses as its thread pointer. The
non-PIE classic bindings are checked by `mkold.py --legacy` before its redundant
LC_DYLD_INFO_ONLY command is removed; 2.x dyld rejects that newer command. No
QEMU startup or 1.x stat/readdir implementation is linked into Bash. GNU's
build identifier is fixed at2 so retries do not change the qualified bytes.
QEMU's link/subtype scripts are build tools and retained with their source notice.
SDK binaries/headers themselves are not copied into the redistribution sources.

Verified fresh output dependencies are only stock `libSystem.B.dylib` and
`libgcc_s.1.dylib`. The adapter pins the qualified output hash, so a different
compiler/SDK result requires explicit qualification rather than automatically
trusting a new local checksum. Build prerequisites are Xcode, autoconf, ldid,
and the historical iPhoneOS3.1.3 SDK. The recipe also accepts `LTM_BASH_LOCAL_SOURCES` for already-cached GNU inputs,
verified against the same source hashes. It takes `LTM_QEMU_SOURCE_DIR` and
`LTM_BASH_SDK` overrides; both default to the project's existing developer paths.
The end-user app can bundle the already qualified payload and its notices/sources.

The normal guest-package loader installs canonical binaries and a launchd job.
Unique ECDSA host and client keys are generated per instance and retained in
private host state. Authorized keys go to the root account's
`.ssh/lighttouch_authorized_keys`, because OpenSSH StrictModes rejects permissive
filesystem root modes when checking a key under `/usr/local`. The daemon binds
only guest loopback, requires public keys, and keeps StrictModes on. The host
uses standard OpenSSH/SFTP over libusbmuxd inetcat; no custom SSH protocol exists.
The app's explicit built-in safe mode bypasses developer augmentation.

Live coverage is clean K48, iOS3.2.2 build7B500, using the monotonic package
loader: modern macOS public-key SSH and byte-exact binary SFTP roundtrip passed,
including wrapper discovery of generated keys and the private session profile.
N72 iOS3.1.3 build7E18 also passes clean native public-key SSH and binary SFTP,
using distinct generated instance keys and the same source-built shell.
Native iPod2.1.1/5F138, 3.0/7A341 and 4.2.1/8C148 qualification uses the same
minimal-v2 shell, public-key SSH and byte-exact stock SFTP. Recipe revision2
ensures existing developer offers receive the updated shell. GUI and composition
share one qualified-build predicate; broader versions still need native proof.
No support is claimed for 1.x, other firmware, SSHFS/Finder mounting, debugserver,
or native SGX. Root filesystem writes use the guest's filesystem and mount
interfaces; the access tool does not edit raw NAND. QEMU's separate GDB stub can
be selected through the host access wrapper when enabled.

## Licenses and provenance

| Component | Notice/source | Provenance limit |
| --- | --- | --- |
| OpenSSH6.7p1 | `licenses/OpenSSH-6.7p1-LICENCE.txt`; [official portable source](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-6.7p1.tar.gz) SHA256 `b2f8394eae858dabbdef7dac10b99aec00c95462753e80342e530bbb6f725507` | Binary is the pinned Legacy Kit archive; exact iOS port build recipe was not reconstructed |
| OpenSSL0.9.8zg | `licenses/OpenSSL-0.9.8zg-LICENSE.txt`; [official source](https://www.openssl.org/source/old/0.9.x/openssl-0.9.8zg.tar.gz) SHA256 `06500060639930e471050474f537fcd28ec934af92ee282d78b52460fbe8f580` | Binary is the pinned Legacy Kit archive; exact iOS port build recipe was not reconstructed |
| GNU Bash4.0.40 | `licenses/Bash-GPL-3.txt`; complete `Sources` from recipe | Source-built here; no opaque historical GPL shell is redistributed |
| QEMU build adapters | retained scripts/source and QEMU COPYING | Build tools only; no QEMU startup implementation linked into Bash |

The earlier seven-file exploration used `freeze.tar.gz`; its GPL binary build
provenance could not be established from version strings/Telesphoreo recipes.
That payload has been replaced. The final payload's `Sources` and `Licenses`
directories must accompany release packaging; copying only executable files is
insufficient. Do not claim byte-for-byte source reproduction of the historical
BSD/OpenSSL binaries merely because their versions match official source.
