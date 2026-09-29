# Smoke: anomalies worked around or unexplained

Sam, 2026-09-28: "I really hope they are treating them as 'this is broken because our emulator has a gap' and not just
'a hurdle to hack around at skin-deep level'. Where there's smoke, there's fire."

Every workaround, instrument, or unexplained anomaly goes here with its fidelity class (see fidelity-ledger.md) and the
fire we suspect behind it. An entry leaves this list only when the cause is modelled faithfully or shown to be
real-hardware behaviour. New entries are added by whoever ships a workaround; none is closed by deleting it.

| # | Where | Smoke | Suspected fire | Class today | Plan |
|---|---|---|---|---|---|
| 1 | iPod 1G, iPhone OS 1.1 (`ipod-1g`) | USB wrangler `phyRegistered` NULL deref: the PHY announces itself before the wrangler stores its notifier; worked around by failing the nub early | Real silicon never hits this ordering, so our timing differs: PHY power-up/PLL-lock completes instantly, CPU/VIC latency, or IOKit matching order driven by a clock/timer rate we model wrong (the 1G timer rate was already found wrong once) | P (documented quirk) | After SpringBoard: measure real-hardware ordering from the 1.1 kernel's own delays; model the PHY's ready latency or the timer/clock that gates matching |
| 2 | iPad 4.3.x (`iop-v3`) | EmbeddedIOP-20/33 layout table in the HLE | The HLE is the fire: Apple's firmware should run | H (instrument) | Delete when `iop-core` passes the 4.3 shutdown gate |
| 3 | iPad 4.3.5 on the IOP core | First fsck reads wrong data under 4.3's access pattern; no NAND error, no erase issued | H2FMI read fidelity: ECC/blank reporting for holes under FTL restore, or ring-0 completion ordering | R (being fixed) | `iop-core` next milestone; page-content diff HLE vs core |
| 4 | iPod 4.0 betas 8A230m/8A260b, 4.2 betas | First-boot clean shutdown takes ~30 s (release 8A293: 0.8 s); over the driver's 50 s budget right after an install | Something in 4.0-beta shutdown waits on a timeout: a service the emulator never answers (Wi-Fi/location/sync?) rather than "betas are slow" | unclassified | Serial-log the shutdown of 8A230m; find what it waits for; model it |
| 5 | iPod 4.0 beta 8A248c | One AFC "unknown error (code 1)" listing the Media root on the matrix's boot 2, never again. Not a readiness race: the "0.3 s" was boot 2's lockdown-after-lit; the listing ran 8+ s after lockdown answered, and AFC is ready at lockdown's first answer (34 boots on a fresh 8A248c, AFC 0.2-1.2 s after the first answer polled at 100 ms: handshake, StartService, connect, first request all 0; `check-sessions.py --single --afc-race`). What preceded it: boot 1's clean shutdown missed the driver's 50 s after the install (#4), so it was Stopped mid-shutdown | Two fires. (a) The code was opaque by construction: `afc_client_start_service` returns AFC_E_UNKNOWN_ERROR for a failed lockdown handshake or StartService, so "1" could have been three steps; fixed, the app now starts AFC as it starts installation_proxy, each step's error kept (`IMobileDevice.startService`). (b) Whatever failed after a Stop mid-shutdown: not reproduced in 13 install+upload+halt boots stopped 20-45 s into the shutdown | app (a fixed); (b) unclassified | Rerun `--afc-race N --afc-race-dirty` with #4's shutdown; a recurrence now names its step (lockdown error N vs AFC code). Closes with #4 or a reproduction |
| 6 | iPad 4.2.1 GL fixture | `shim:ca:nextbuffer` 0–2 per run under host load: CoreAnimation declines the fixture layer's first buffers | Probably a surface/buffer-ownership race between our present path and CA's triple buffering that real hardware's timing hides | P/H | Capture the CA buffer state on the refusal; fix ordering, not the counter |
| 7 | iPad, real iBoot path | POWER_ID security epoch synthesised as 1; iBoot-1072+ wants 2 | The `iboot=` shortcut skips LLB, which sets it on hardware | P | Read SEPO off the image (as `it_iboot_find_epoch`), or boot from the ROM |
| 8 | iPod 4.2.1 | With the IOP core on the iPad, "SDIO In Reset": the SDIO task drives a stub SDHCI | Stub host controller | S | Real SDHCI model (`iop-core` last milestone) |
| 9 | Both boards | `amfi_allow_any_signature`, `cs_enforcement_disable` boot-args; AppSync dylib | Code signing bypassed because the guest can't verify our shim/packages; a faithful device would run only signed code | P | Long-term: sign the guest tools with a key the device trusts (own root in the trust store + AMFI trust cache), or keep as declared P |
| 10 | iPod 2.x/3.0 | No guest tools: dyld refuses LC_DYLD_INFO_ONLY | Not smoke: a real linker limit; the fix is building the tools for that dyld (legacy link), as it_boot already is | P | Legacy-link the agent/shim for 2.x (GPU research in flight) |

Closed:
- iPod 4.2.1 "No Wi-Fi": card reported chip number 0 → real chip id word (R). 2026-09-28.
- iPod 4.2.1 screen only dims: PMU regulator-enable bit now honoured (R). 2026-09-28.
- iPad 4.3 DSI assert at display-off: StopStateClk semantics corrected (R). 2026-09-28.
- iPad 4.3.5 "epoch roll wait": NAND signature epoch read off the kernel (pipeline, generic). 2026-09-28.
- iPod 3.0 never printed: direct-iboot epoch hard-coded → found by pattern per iBoot (R). 2026-09-28.
