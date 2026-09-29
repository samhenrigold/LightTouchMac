# Device × firmware matrix

Every public build for the two emulated boards and, for the record, the iPod touch 1G (no board yet). Sources:
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
| iPod1,1 | 1.1 | 3A101a | hosted | `9b0d83c7f8b4328174a3f31e0e93f60e591ae143` | 157,890,186 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 1.1.1 | 3A110a | hosted | `84bbc6ea8bf29745195bc9926c1874f7c2a36f32` | 157,906,686 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 1.1.2 | 3B48b | hosted | `108d8ffe9ea75e61cd5e57170ad388b7fa00d923` | 165,567,897 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 1.1.3 | 4A93 | hosted | `8dca23eec69d5ae58fbf3d4a23276e46cbb2e3c6` | 173,511,411 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 1.1.4 | 4A102 | hosted | `c148d1eb1c979bb6434175411d4a372103a4fdd2` | 173,519,589 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 1.1.5 | 4B1 | hosted | `1b818911316e4248ee01d3ec67f9d39afc3db240` | 173,519,637 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.0 | 5A347 | mirror (sha1 verified), Apple never hosted | `ae82798e85f9953b0f4798bad36187cb020c9d22` | 233,409,573 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.0.1 | 5B108 | mirror (sha1 verified), Apple never hosted | `a81b6e7af4b85ef436d047f9da57c0f694d8964a` | 258,660,321 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.0.2 | 5C1 | mirror (sha1 verified), Apple never hosted | `c8b6f9fefa3f3777c56285dfe4c735b1e08a81a2` | 258,201,218 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.1 | 5F137 | mirror (sha1 verified), Apple never hosted | `fc7f6d0972927df502ffca47438ca75dcccffaf3` | 251,155,156 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.2 | 5G77 | mirror (sha1 verified), Apple never hosted | `081a7de363230fb38d0ce092cbbe42f2a50c8a5f` | 260,186,851 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 2.2.1 | 5H11 | mirror (sha1 verified), Apple never hosted | `fc69be9e421bc0630567184506ab771f6b7ef68b` | 260,166,688 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 3.0 | 7A341 | mirror (sha1 verified), Apple never hosted | `dff2bd14931225908a360fb8e60a336f17d2dd6d` | 242,458,552 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 3.1.1 | 7C145 | mirror (sha1 verified), Apple never hosted | `c6270780c166db4c9f4f0a7fa945754a1f9fe7e8` | 249,755,862 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 3.1.2 | 7D11 | mirror (sha1 verified), Apple never hosted | `7367dd9ba58a3b9777307368a0128e696fdfc9a6` | 249,780,497 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod1,1 | 3.1.3 | 7E18 | mirror (sha1 verified), Apple never hosted | `5f897990f19d2f093b35e0813d7d77806404fb1f` | 235,678,189 | n/a (1.x: only the rootfs is encrypted) | no board |
| iPod2,1 | 2.1.1 | 5F138 | hosted | `c3c700be49ad227d1152188e7c1e46b8958fd1e4` | 282,083,944 | 14 keys, wiki lacks iBEC, iBSS | coming_soon |
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
- iPad1,1 4.3.1–4.3.5: the wiki has no ramdisk keys (checked again 2026-09-28 through the MediaWiki API: the
  RestoreRamdisk/UpdateRamdisk rows do not exist on the `Keys:` pages); the k48 recipe's data-protection keybag step
  needs a restore ramdisk. `firmwarekit create --keybag-ramdisk` boots a sibling build's decrypted ramdisk instead
  (8F190's, keys known; only it_keybag runs on it, under this build's kernel): 8G4 and 8L1 both get their keybag that
  way (matrix-results.md). Catalog proposal: `recipe.keybag_ramdisk_from: "k48ap-8F190"` so the app resolves the
  sibling entry's IPSW and key itself.
- iPod2,1 2.2 / 2.2.1: the wiki has no iBSS/iBEC keys; neither recipe needs those two components.
- iPod2,1 4.0 (8A293) and iPad1,1 5.0 (9A334): no Update-ramdisk key on the wiki.
- iPod1,1: only the root filesystem is encrypted on 1.x; listed for the record, no board is emulated.
