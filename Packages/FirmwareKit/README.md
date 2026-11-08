# Firmware preparation tools

The package provides the catalog-driven `firmwarekit` CLI and two additional
drivers for image preparation and guest-tool provisioning. The drivers call
the same FirmwareKit library used by the main CLI.

```sh
swift build --package-path Packages/FirmwareKit --product firmwarekit-prepare
swift build --package-path Packages/FirmwareKit --product firmwarekit-provision-guest-tools
```

## firmwarekit-prepare

This executable exposes image preparation stages and filesystem inspection.
Its default invocation prepares an iPhone 4 image:

```sh
firmwarekit-prepare IPSW ENTRY HELPERS NEW-OUT
```

`ENTRY` is the matching firmware-entry JSON, `HELPERS` contains source-built
guest helpers, and `NEW-OUT` must not exist. The output includes the NAND,
KBoot bundle, identity and provenance. Native keybag initialization is a
separate preparation stage; producing those files alone does not complete it.

N42 preparation uses the stage commands below. The qualified builds are
6.0/10A405, 7.0/11A465, 8.0/12A365, 9.0/13A344 and 10.3.4/14G61.

| Command | Inputs after the command | Output |
| --- | --- | --- |
| `--decrypt` | `IPSW ENTRY NEW-OUT --rootfs` | Decrypted components and root filesystem |
| `--a6-volumes` | `IPSW DECRYPTED HELPERS NEW-OUT` | Prepared System/Data images and preparation records |
| `--a6-initial-restore` | `SYSTEM DATA OUTPUT` | Allocated-block native restore stream |
| `--a6-factory-nand` | `NEW-NAND HEADER` | Sparse factory NAND and factory header |
| `--a6-restore` | `WORK INITIALIZER [OPTIONS]` | Temporary native restore boot bundle |
| `--a6-kboot` | `DECRYPTED OUTPUT [ROOT] [OPTIONS]` | Normal boot bundle and identity |

For `--a6-restore`, `WORK` contains `decrypted/`, `initial.a6di`, and
`factory.header` from the preceding stages. Use `--factory-format`,
`--data-seed DATA`, `--seed-base-system SYSTEM`, and the generated
`--activation-plan PLAN` when present. The source-built initializer and its
capability-cache worker must be available together. For iOS 9 and 10, both
restore and normal KBoot preparation also use `--guest-assets-system SYSTEM`.
Use the same `--seed SEED` for both boot bundles; normal KBoot preparation uses
`--guest-support` and root device `disk0s1` for this layout.

The calling host runs the temporary native initializer, which formats the
device, restores the filesystems, initializes the keybag, seeds Data, and
generates the capability cache using matching System libraries. Accept the
device only after `A6RESTORE DONE`, the native keybag completion marker, and
guest shutdown. Then use the normal boot bundle. Keep temporary preparation
files until completion has been verified and remove them afterwards.

The N42 layout is 16 GB, with a 3 GiB System partition and the remaining Data
partition. Guest helpers, activation/setup records and build-specific
first-boot preparation are installed through FirmwareKit. The
[restore helper documentation](https://github.com/samhenrigold/qemu-ios/tree/main/contrib/it-restore)
describes the native initialization protocol.

## firmwarekit-provision-guest-tools

```sh
firmwarekit-provision-guest-tools SNAPSHOT-NAND HELPERS NEW-OUT EPOCH
```

This prepares an existing, stopped legacy NAND copy to support guest app
installation. It exports volumes, recovers their HFS journals on staging
images, installs the agent and installation-service helper configuration
through `SideloadTools`, and writes a rebuilt NAND under `NEW-OUT`. `EPOCH` is
the NAND signature epoch used by the N72 output route. The iPad output route
uses its existing NAND rebuild implementation. This driver does not implement
the N42 NAND output route; fresh N42 preparation provisions its helpers in
`A6Preparation.volumes`.

User applications are installed after boot by native MobileInstallation onto
Data. This tool provisions the supporting services; it does not install an
IPA. Operate on a stopped snapshot and keep the source device intact.

## Why these are separate executables

The current catalog recipe dispatcher does not select an N42 board, and the
N42 creation path needs a native restore initialization sequence before its
first normal boot. The stage driver exposes that working sequence without
changing the existing recipe, helper lifecycle, progress, cancellation or
device-lock contracts. It also exposes individual filesystem inspection
operations. The provisioning driver serves the separate case of upgrading
an existing legacy image with guest-service support.

The firmware transformations and shared service configuration live in the
library. The remaining integration boundary is host orchestration: selecting
the N42 recipe, supplying exported guest helpers, running and supervising
initialization, and recording the prepared device. These entry points can be
kept or incorporated into the main CLI according to the consuming project's
preferred integration. No choice of that interface is required by the image
or emulator contracts.
