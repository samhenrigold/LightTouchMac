# AppSync cleanup (2026-09-30)

QEMU helper source: `0be1499f24bc0e34d83eb35292130893020a5f83`, pinned in
`build-support/sources.json`. Both repositories use `appsync-upstream`.

This change keeps automatic installation-service injection and removes the
shared-cache MIS patch and unused SpringBoard swizzle. Stock installd,
SpringBoard and libmis remain intact. Kernel execution policy remains the
emulator recipe's existing AMFI boot arguments.

The helper calls MISValidateSignatureAndCopyInfo first and preserves any
original signing dictionary, including unknown fields. It synthesizes only the
legacy two-field fallback when no dictionary is returned. Security certificate
fallback applies only to the exact embedded DER, after Apple's parser rejects
it, inside installd/mobile_installation_proxy. The old metadata-free verifier
continues to return success in those installation services for 2.x compatibility.
The CoreFoundation callback exports were incorrectly declared as pointers;
correcting them fixes SignerCertificate ownership in the fallback dictionary.

Reference packages were extracted for inspection, never executed or shipped.
See qemu-ios `contrib/appsync/prior-art.md` for package URLs, verified SHA-256s,
the two-instruction 3.1.3 comparison, the incompatible 3.2 replacement binary,
and the 4.0 patcher's conditional destructive shell-command path. Upstream
AppSync Unified supplies the original-first metadata and narrow certificate
fallback precedent; its iOS 8+ metadata expansion is not needed here.

## Validation

Native helper tests use real CoreFoundation with ASan/UBSan and mock original
verifiers to check retained dictionary values, complete original metadata,
Copy ownership, certificate scope, and process scope. FirmwareKit's
EarlyAppSyncTests and SharedCacheTests pass (7 tests; the installation test
covers both services with and without a cache), including byte-for-byte
unchanged standalone libmis and opaque shared-cache fixtures. Both guest ARM
slices build successfully. Python compilation, shell syntax and diff checks pass.

Acceptance uses a decrypted ARMv6/ARMv7 IPA, `org.lighttouch.AppSyncSmoke`, the
native DeviceSession driver, fresh prepared images, and stock shared caches.
Foreground success requires three guest-agent samples naming the smoke app,
visible screenshots, and clean shutdown. Diagnostic run directories below are
local temporary artifacts, not repository dependencies. The Setup harness now
waits for the Terms button highlight to settle and retries Agree when the page
remains unrecognised, rather than mistaking the highlight for navigation. Its
retry/fingerprint self-tests pass.

| Firmware | Result with stock cache | Run directory under /private/tmp |
| --- | --- | --- |
| iPod 3.1.3 (7E18) | Install, foreground launch, clean shutdown | appsync-upstream-local31-run |
| iPad 3.2.2 (7B500) | Install, visible launch, clean shutdown | appsync-upstream-local32-verified |
| iPad 4.2.1 (8C148) | Install, visible launch, clean shutdown | appsync-upstream-local4-verified |
| iPad 5.1.1 (9B206) | Install, visible launch, clean shutdown | appsync-upstream-local5-retry |
| iPad 3.2.2, AppSync disabled | Same IPA rejected: ApplicationVerificationFailed, code -13 | appsync-upstream-off32-control |

Early adapters remain in place. On fresh 2.1.1 (5F138), both the previous helper
and this helper stop at Connect to iTunes and refuse installation-service
connections with -256 before the hook runs. That activation/service issue is
not a successful AppSync acceptance result. On 3.0 (7A341), installation passes,
but the fixture's display/launch automation does not establish a foreground
smoke-app result. Neither result is represented as complete coverage. Other
catalog builds, including iOS 5 betas, need their own guest acceptance runs.

Prepared images must be rebuilt to remove an earlier shared-cache patch;
updating the helper alone cannot undo it. The historical cache matcher remains
available for research/oracle comparisons, but preparation and AppSync fit
checks no longer depend on a firmware-specific instruction pattern.
