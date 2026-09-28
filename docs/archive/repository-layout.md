> Archived 2026-09-28: written 2026-09-11 for the Python-pipeline, bundled-firmware build. The current layout and repo contract are in [../../README.md](../../README.md).

# Source, inputs and generated files

LightTouchMac owns the product build. Run `scripts/build-release.py` here to
assemble the app, QEMU, utilities and bundled device. See the README for the
command and supported tools. The existing source repositories retain their
history and can be developed independently.

| Location | Ownership and use |
| --- | --- |
| `LightTouchMac/` | Mac app, shared Xcode configuration, dependency manifest, build recipes, packaging and product tests |
| `qemu-ios/` | QEMU fork, its app bridge, host utilities and guest helper source under `contrib/`; the product builds the required tools from here |
| Actual `usbmuxd` checkout | Transport fork; pass this checkout to `--usbmuxd-source`, including when it is inside the old `usbmuxd-qemu/` wrapper |
| `qemu-ios-files/` | Private, existing firmware inputs; the builder reads only the selected boot assets and NAND directory |
| `ipod2g-re/` | Research archive; its SDK can be an explicit `--sdk` input, but the archive is not a product source or payload directory |
| `qemu-ios-deps12/` | Historical installed prefix; the new build regenerates dependencies from the product manifest |
| `LightTouchMac/.build/` | Ignored local builds, prefixes, guest tools, DerivedData, archives and build records; generated and disposable |
| `LightTouchMac/dist/` | Optional ignored destination for generated release artifacts |

The default input paths are sibling directories. Every source/input location
can be overridden, and generated guest tools are built in a separate work
directory. Ordinary Xcode builds only compile the app; they do not run the
product pipeline.

## Versioning

Commit app/build changes in this repository and emulator/helper changes in
QEMU. Commit transport changes in the actual usbmuxd fork. Do not add firmware,
SDKs, installed prefixes or build output to any of these source repositories.

`build-support/dependencies.json` pins downloaded archives by version and
SHA-256. `Package.resolved` pins Swift packages. Each product build records
source revisions, current source content (including dirty work and initialized
QEMU submodules), toolchain versions, native/guest provenance and the resulting
bundle inventory. Reuse requires matching recorded inputs. These records
describe the selected local checkouts; they are not a source-checkout manager
or a substitute for committing and tagging a release.

The existing usbmuxd wrapper and its nested Git repository have not been
rewritten. The builder selects the real source directory directly and does
not consume the wrapper's runtime configuration. Before retiring or flattening
the wrapper, preserve its useful fixtures/docs and the nested fork's local
changes and unpublished commits. Existing remotes, branches and tags remain
available.

## Retiring old material

New product builds no longer require the old dependency prefix, another
previously built app, compiled helpers beside their source, or packaging
scripts in the firmware/research archives. Those files have not been deleted:
some are historical evidence, device backups or inputs to other workflows.
Keep them until their separate owners and recovery requirements are resolved.

Keep each active device's original base and overlay together. An old NAND
directory or snapshot is not safe to remove merely because a newer one exists.
The app's storage ownership and cleanup rules are described in
[storage-layout.md](../storage-layout.md).

User-supplied IPSW/boot ROM setup is a later change. This pipeline continues to
produce one app containing the selected existing firmware. Public release
licensing, complete corresponding-source delivery and notarization remain
separate release requirements; an ad-hoc local build is not a published release.
