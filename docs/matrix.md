# Device × firmware matrix

Every public build for the three emulated boards (iPad 1, iPod touch 2G, iPod touch 1G). Sources:
build ids, Apple CDN URLs, SHA-1s and sizes from api.ipsw.me (plus The Apple Wiki's firmware tables for the builds
ipsw.me lacks: the paid-update series Apple served through iTunes only, and the pulled 4.2 GM); "hosted" is a HEAD
request against Apple's URL on the date below. The paid updates (iPod touch 1G 2.x/3.x, iPod touch 2G 3.x) come from
a third-party mirror, https://invoxiplaygames.uk/ipsw/ (Sam's pick): each file was downloaded in full and its SHA-1
measured against the wiki's; "mirror (sha1 verified)" means they matched. Keys from The Apple Wiki's `Keys:` pages,
verified by decrypting each keyed component from the IPSW (`firmwarekit verify-keys`). Status is the catalog
entry's (`LightTouchMac/Resources/firmware-catalog.json`). Results of running the matrix: [matrix-results.md](matrix-results.md).
Runner: `tests/matrix.py`.

Checked 2026-09-28.

| Device | iOS | Build | Apple CDN | SHA-1 | Bytes | Keys | Catalog status |
|---|---|---|---|---|---|---|---|
| iPad1,1 | 3.2 | 7B367 | hosted | `172e8297af74b91971a802e6ad137c891f553099` | 478,959,325 | 19 keys | available |
| iPad1,1 | 3.2.1 | 7B405 | hosted | `de0a2b64cd335d48fb4abc9ed8700f5dbdf768ca` | 479,012,625 | 19 keys | untested |
| iPad1,1 | 3.2.2 | 7B500 | hosted | `68b613f78581d36eab96aa5a007001dff142baa3` | 479,001,595 | 19 keys | available |
| iPad1,1 | 4.2.1 | 8C148 | hosted | `8717b3bedc925b587566442ad375aa65d857e79a` | 578,084,840 | 18 keys | experimental |
| iPad1,1 | 4.3 | 8F190 | hosted | `fc97d5959a1e29d707586871004ea12e95815237` | 625,814,678 | 18 keys | untested |
| iPad1,1 | 4.3.1 | 8G4 | hosted | `6615b368d665630e80da975232567daf87a042b6` | 621,768,387 | 16 keys, wiki lacks RestoreRamdisk, UpdateRamdisk | untested |
| iPad1,1 | 4.3.2 | 8H7 | hosted | `2c86c5915a8f9e56776deba22dc048c2f42db8b7` | 622,148,907 | 16 keys, wiki lacks RestoreRamdisk, UpdateRamdisk | untested |
| iPad1,1 | 4.3.3 | 8J3 | hosted | `e2906ef04d5991663cd6ea8b19548ec190144d46` | 622,048,364 | 16 keys, wiki lacks RestoreRamdisk, UpdateRamdisk | untested |
| iPad1,1 | 4.3.4 | 8K2 | hosted | `3c38b8c3792141484f6a8cffae0a38c25947ec28` | 622,279,895 | 16 keys, wiki lacks RestoreRamdisk, UpdateRamdisk | untested |
| iPad1,1 | 4.3.5 | 8L1 | hosted | `66a114630a457dea3565cf99b9285b2fe3d56d62` | 622,255,612 | 16 keys, wiki lacks RestoreRamdisk, UpdateRamdisk | untested |
| iPad1,1 | 5.0 | 9A334 | hosted | `c7f6d2d94b1f9f67103343e001f85be7111f6df0` | 734,262,118 | 17 keys, wiki lacks UpdateRamdisk | untested |
| iPad1,1 | 5.0.1 | 9A405 | hosted | `732fc3ca3f5654e6f0df787c817ca16054dfb8da` | 751,358,387 | 18 keys | untested |
| iPad1,1 | 5.1 | 9B176 | hosted | `f6b19779d2fe4242f87d55701e049291c978e3b3` | 761,232,912 | 18 keys | untested |
| iPad1,1 | 5.1.1 | 9B206 | hosted | `ad9b607439250f2337fe132890dadc4c487beca8` | 761,323,675 | 18 keys | untested |
| iPod1,1 | 1.1 | 3A101a | hosted | `9b0d83c7f8b4328174a3f31e0e93f60e591ae143` | 157,890,186 | rootfs key verified | untested |
| iPod1,1 | 1.1.1 | 3A110a | hosted | `84bbc6ea8bf29745195bc9926c1874f7c2a36f32` | 157,906,686 | rootfs key verified | untested |
| iPod1,1 | 1.1.2 | 3B48b | hosted | `108d8ffe9ea75e61cd5e57170ad388b7fa00d923` | 165,567,897 | rootfs key verified | untested |
| iPod1,1 | 1.1.3 | 4A93 | hosted | `8dca23eec69d5ae58fbf3d4a23276e46cbb2e3c6` | 173,511,411 | rootfs key verified | untested |
| iPod1,1 | 1.1.4 | 4A102 | hosted | `c148d1eb1c979bb6434175411d4a372103a4fdd2` | 173,519,589 | rootfs key verified | untested |
| iPod1,1 | 1.1.5 | 4B1 | hosted | `1b818911316e4248ee01d3ec67f9d39afc3db240` | 173,519,637 | rootfs key verified | untested |
| iPod1,1 | 2.0 | 5A347 | mirror (sha1 verified), Apple never hosted | `ae82798e85f9953b0f4798bad36187cb020c9d22` | 233,409,573 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 2.0.1 | 5B108 | mirror (sha1 verified), Apple never hosted | `a81b6e7af4b85ef436d047f9da57c0f694d8964a` | 258,660,321 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 2.0.2 | 5C1 | mirror (sha1 verified), Apple never hosted | `c8b6f9fefa3f3777c56285dfe4c735b1e08a81a2` | 258,201,218 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 2.1 | 5F137 | mirror (sha1 verified), Apple never hosted | `fc7f6d0972927df502ffca47438ca75dcccffaf3` | 251,155,156 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 2.2 | 5G77 | mirror (sha1 verified), Apple never hosted | `081a7de363230fb38d0ce092cbbe42f2a50c8a5f` | 260,186,851 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 2.2.1 | 5H11 | mirror (sha1 verified), Apple never hosted | `fc69be9e421bc0630567184506ab771f6b7ef68b` | 260,166,688 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 3.0 | 7A341 | mirror (sha1 verified), Apple never hosted | `dff2bd14931225908a360fb8e60a336f17d2dd6d` | 242,458,552 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 3.1.1 | 7C145 | mirror (sha1 verified), Apple never hosted | `c6270780c166db4c9f4f0a7fa945754a1f9fe7e8` | 249,755,862 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 3.1.2 | 7D11 | mirror (sha1 verified), Apple never hosted | `7367dd9ba58a3b9777307368a0128e696fdfc9a6` | 249,780,497 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod1,1 | 3.1.3 | 7E18 | mirror (sha1 verified), Apple never hosted | `5f897990f19d2f093b35e0813d7d77806404fb1f` | 235,678,189 | n/a (1.x: only the rootfs is encrypted) | not in catalog (no 2.x/3.x n45 recipe) |
| iPod2,1 | 2.1.1 | 5F138 | hosted | `c3c700be49ad227d1152188e7c1e46b8958fd1e4` | 282,083,944 | 14 keys, wiki lacks iBEC, iBSS | experimental |
| iPod2,1 | 2.2 | 5G77a | hosted | `34a0a489605f34d6cc6c9954edcaaf9a050deedc` | 291,123,491 | 14 keys, wiki lacks iBEC, iBSS | untested |
| iPod2,1 | 2.2.1 | 5H11a | hosted | `9af5625ea34acdd8abeb6fce71a72651d0c815d5` | 291,140,244 | 14 keys, wiki lacks iBEC, iBSS | untested |
| iPod2,1 | 3.0 | 7A341 | mirror (sha1 verified), Apple never hosted | `0f7fc76d9b9aa826b5ab14be9821a315d3d9dc42` | 270,315,364 | 19 keys | untested |
| iPod2,1 | 3.1.1 | 7C145 | mirror (sha1 verified), Apple never hosted | `e0d8800a4fc7cc5be6976ddbceb43c2d2a7120d7` | 277,753,989 | 19 keys | untested |
| iPod2,1 | 3.1.2 | 7D11 | mirror (sha1 verified), Apple never hosted | `e7c83d4a5baec0e81816ae1cd1caf9a4dc38ebf0` | 277,794,671 | 19 keys | untested |
| iPod2,1 | 3.1.3 | 7E18 | mirror (sha1 verified), Apple never hosted | `5f4f5c01eda2f811f73167e7d1f82dbeed82367b` | 263,275,211 | 19 keys | user_ipsw |
| iPod2,1 | 4.0 | 8A293 | hosted | `c026c373bc535496a6f901de2ba37d4a487413bf` | 330,278,777 | 17 keys, wiki lacks UpdateRamdisk | untested |
| iPod2,1 | 4.0.2 | 8A400 | hosted | `06a42297d94461264eb64d7c8640cc5d1c19edeb` | 344,248,876 | 18 keys | untested |
| iPod2,1 | 4.1 | 8B117 | hosted | `97abde6207660bd876fd476275dd526d0dcf3d19` | 348,027,174 | 18 keys | untested |
| iPod2,1 | 4.2 | 8C134 | hosted | `cd4bb233a54f35f765ce12625f00b20ef31a777f` | 363,581,294 | 18 keys | not in catalog (GM, pulled before 4.2.1) |
| iPod2,1 | 4.2.1 | 8C148 | hosted | `b9efddc7bb4350c237a8d3846af61bbfc8a2f647` | 363,553,480 | 18 keys | experimental |

Notes:
- iPod2,1 3.0–3.1.3 were the paid "iPod touch Software Update" series: no Apple CDN URL ever existed; the catalog
  points at the third-party mirror (status note says so). 7E18 keeps `user_ipsw` (the bundled image's build).
- iPod2,1 4.2 (8C134) was the 4.2 GM Apple pulled a week before 4.2.1; it is not in the catalog.
- iPad1,1 4.3.1–4.3.5: the wiki has no ramdisk keys (checked again 2026-09-29 through the MediaWiki API: the
  RestoreRamdisk/UpdateRamdisk rows do not exist on the `Keys:` pages, last edited 2024-01-23; every other component key
  on them matches the catalog); the k48 recipe's data-protection keybag step
  needs a restore ramdisk. Those entries carry `recipe.keybag_ramdisk_from: "k48ap-8F190"`: a sibling build's
  ramdisk (same iOS major, keys known; only it_keybag runs on it, under this build's kernel) boots the keybag
  one-shot. The app (FirmwareJobs) and `tests/matrix.py` resolve the sibling entry's IPSW and pass
  `firmwarekit create --sibling-entry/--sibling-ipsw`; firmwarekit decrypts just that ramdisk with the sibling's key.
  The app queues the sibling IPSW's download beside the entry's own. All five get their keybag this way
  (matrix-results.md). All six take the iBoot chain (the default strategy): 8K2/8L1's iBoot-1072 is security epoch 2 and the
  emulator reads it off the staged image (smoke.md #7, closed); 8F190–8J3 are epoch 1. 8K2/8L1 were on
  `recipe.boot: "kboot"` until then.
- iPod2,1 2.2 / 2.2.1: the wiki has no iBSS/iBEC keys; neither recipe needs those two components. They boot only with
  qemu-ios `ipod-2x` (the LLB's 0x38100000 block, smoke #18); `experimental` since the merge and pin bump (qemu-ios ipad1, 2026-09-29).
- iPod2,1 2.x and 3.0 with AppSync (catalog on since `legacy-activation-appsync`): the app's pipeline installs a Legacy
  Store game and it launches — PAC-MAN Lite (Legacy Store ipa 145757, min OS 2.0, decrypted armv6) on 5F138, 5G77a and
  5H11a; on 7A341 Labyrinth 2 Lite (ipa 257098) installs and launches but draws nothing (no GL on 3.0, smoke #47). The install needed an app fix: iPhone OS
  2.x's installation_proxy silently drops an Install without ClientOptions (libimobiledevice omits the key for NULL
  options), so the app now always sends an empty dictionary (`legacy-gate`). Neither 2.x nor 3.0 has
  com.apple.springboardservices (it arrives in 3.1), so the app no longer waits for it at boot and the matrix taps the
  icon where the firmware puts it (`--launch-at`). The first install raises SpringBoard's Edit Home Screen tip (smoke #45).
- iPod2,1 2.x: no guest agent (smoke #10); SpringBoard composites through the GL front end (the
  seed package's `n72-ios2` OpenGLES hook, guest package serial 5+; the GL column is regress.py's gles leg). Hold locks;
  the machine's hold-and-slide shuts all three down cleanly (~15 s) since qemu-ios dc2794f46f (smoke #19 closed): a
  tethered 2.x halt waits for the cable to come out, so the gesture unplugs once the screen is dark. The app's Stop is
  a flush + halt and persist passes either way.
- iPod2,1 4.0 (8A293) and iPad1,1 5.0 (9A334): no Update-ramdisk key on the wiki.
- iPod1,1 1.1–1.1.5: in the catalog since `legacy-gate` (09-29), `untested`: the six Apple URLs/SHA-1s from api.ipsw.me,
  release dates and the rootfs VFDecrypt keys from The Apple Wiki (`Keys:Snowbird 3A101a (iPod1,1)` … `Keys:LittleBear 4B1
  (iPod1,1)`), each verified by `firmwarekit verify-keys` (only the rootfs is encrypted on 1.x; the 8900 images use the fixed
  key). Board `n45ap`, recipe `n45`; they list between the iPad and the iPod touch 2G. The app boots them
  (`DeviceProfile.iPodTouch1G`: bootrom_s5l8900 from the device assets, the base's iBoot.bin, a private pflash NOR), but
  the machine has no USB link or app-reachable buttons yet (smoke #43), so lockdown, AFC, installs and Shut Down fail and
  none is `experimental`. 3A101a: prepare, lit, the loader's package report, persist through Stop's hard halt; activation
  and the Hold → slider power-off pass only under QMP (lockdownd's own log; `pmu go stdby`). 4B1 never lights: its
  iBoot-204.3.16 wants security epoch 3, the machine gives 2 (smoke #44). 3A110a–4A102: prepared by no one yet.
- iPod1,1 2.0–3.1.3 (the paid updates): listed for the record; no n45 recipe for 2.x/3.x.

## Betas

Sam (2026-09-28): "i think it would be cool if you let me run beta iOS versions". Every developer beta and golden
master the [iOS Firmware Exhibit Collection](https://archive.org/download/iOS_Firmware_Exhibit_Collection) on
archive.org holds for the two boards (its metadata API gives size and SHA-1; each download is checked against it).
Third-party: Apple never hosted the betas (8C134b and the iPod 8C134 GM it still does; the catalog points at the
archive for all of them so one source answers). Keys from The Apple Wiki's `Keys:` pages (the *Vail codenames),
verified with `firmwarekit verify-keys`. Release dates from the wiki's Beta Firmware tables.

Catalog: `prerelease` (`beta`/`gm`) with `prerelease_number` gives the sidebar its badge, always numbered ("Beta 1",
"Beta 3", "GM 2"; a missing number is 1). Every entry carries `released` (a release's Apple date, a developer build's
from this table), the listings' primary order: 4.1 beta 1–3, then 4.1; the iPad's 5.0 beta 1 (2011-06-07) between
4.3.3 and 4.3.4. Untested entries, betas included, download from `source.url` and prepare like any other, with an
"Untested" note (Sam, 0928d); only `coming_soon` stays shut.
Beta expiry was never observed on iOS 4 betas with the Mac's date (every 4.0/4.1/4.2 beta booted to its home screen
in 2026, no "This version of iOS has expired"); if an iOS 5 beta refuses to run past its expiry, a per-entry clock
pin is the planned fix (lockdown-tz already takes an optional epoch; the app would set it instead of the Mac's clock
once per boot). Sam (2026-09-28): no fussing with the device date unless it is required.

| Device | iOS | Build | Released | SHA-1 | Bytes | Keys | Catalog status |
|---|---|---|---|---|---|---|---|
| iPad1,1 | 4.2 beta | 8C5091e | 2010-09-15 | `bb685f022c6267dd77d4ce4c6bff8b60ad84c5d5` | 538,847,283 | 18/18 verified | untested |
| iPad1,1 | 4.2 beta 2 | 8C5101c | 2010-09-28 | `b9c9c84b312d61a77413e8d71d1231a3d3899b96` | 545,646,316 | 18/18 verified | untested |
| iPad1,1 | 4.2 beta 3 | 8C5115c | 2010-10-12 | `ff01b907cc170648405224dd72311c9eabc29105` | 576,124,370 | 18/18 verified | untested |
| iPad1,1 | 4.2 GM | 8C134 | 2010-11-01 | `edc2374ea39a029a943b345c43a8c2f2ab4bb504` | 575,667,008 | 18/18 verified | untested |
| iPad1,1 | 4.2 GM 2 | 8C134b | 2010-11-12 | `57b9bef53d56bfb81c107847b62da97d5fb207ae` | 578,020,841 | 18/18 verified | untested |
| iPad1,1 | 4.3 beta | 8F5148b | 2011-01-12 | `7fb2f13a47282ee22938ccea1b8f6cf762c20da3` | 639,846,333 | 18/18 verified | untested |
| iPad1,1 | 4.3 beta 2 | 8F5153d | 2011-01-19 | `5624814e59d7a56279df1e19823d228c0b26ad88` | 636,269,961 | 18/18 verified | untested |
| iPad1,1 | 4.3 beta 3 | 8F5166b | 2011-02-01 | `246e5a2f33f3cd14e97b37003a7c2a1f47aa8bf2` | 624,729,345 | 18/18 verified | untested |
| iPad1,1 | 5.0 beta | 9A5220p | 2011-06-07 | `006bd8859e534e6cf68d6a72e7c7086dbb675dae` | 702,191,668 | 17/17 verified, wiki lacks UpdateRamDisk | untested |
| iPad1,1 | 5.0 beta 5 | 9A5288d | 2011-08-06 | `383ec353c779168aa60a1e3110037a81929785e9` | 759,078,534 | 17/17 verified, wiki lacks UpdateRamDisk | untested |
| iPod2,1 | 4.0 beta | 8A230m | 2010-04-08 | `30ab55a8ad3788af70c8bc3b036adb94fa274836` | 320,899,292 | 18/18 verified, wiki lacks UpdateRamDisk | untested |
| iPod2,1 | 4.0 beta 2 | 8A248c | 2010-04-20 | `02631ccd3a847a66b870f8f9078c97f801c51f61` | 324,553,033 | 17/17 verified, wiki lacks UpdateRamDisk | untested |
| iPod2,1 | 4.0 beta 3 | 8A260b | 2010-05-04 | `fd65a731d0764ca6e1fac145d792aa21b787102d` | 330,073,091 | 17/17 verified, wiki lacks UpdateRamDisk | untested |
| iPod2,1 | 4.0 beta 4 | 8A274b | 2010-05-18 | `e95696a965f16b8cba70a647da73338422653e1b` | 324,314,892 | 17/17 verified, wiki lacks UpdateRamDisk | untested |
| iPod2,1 | 4.1 beta | 8B5080c | 2010-07-14 | `4a44df7abad161cc5ac3d1a9a54e692b65c5d375` | 343,163,477 | 18/18 verified | untested |
| iPod2,1 | 4.1 beta 2 | 8B5091b | 2010-07-27 | `01e2bfbbd54558c3a2546234e848da958ec651d5` | 349,571,734 | 18/18 verified | untested |
| iPod2,1 | 4.1 beta 3 | 8B5097d | 2010-08-03 | `12ebb29c9ff04007b218232a6690ec6830f73c52` | 345,660,363 | 18/18 verified | untested |
| iPod2,1 | 4.2 beta | 8C5091e | 2010-09-15 | `711597af361f003d5f3d2ec865ada3fb5e2bbb1d` | 363,496,695 | 18/18 verified | untested |
| iPod2,1 | 4.2 beta 2 | 8C5101c | 2010-09-28 | `ccd8249250491f6b7783c67e71b492e201138aba` | 366,143,810 | 18/18 verified | untested |
| iPod2,1 | 4.2 beta 3 | 8C5115c | 2010-10-12 | `c1113a43303b99ba2bed9333477df162c6d043e1` | 364,755,569 | 18/18 verified | untested |
| iPod2,1 | 4.2 GM | 8C134 | 2010-11-01 | `cd4bb233a54f35f765ce12625f00b20ef31a777f` | 363,581,294 | 18/18 verified | untested |

- iPad1,1 4.3 and 5.0 betas: blocked as their releases are (8F190's IOP startup ping, docs/matrix-results.md); listed, not run.
- iPod2,1 4.0 betas and iPad1,1 5.0 betas: no Update-ramdisk key on the wiki (as 8A293 / 9A334).
