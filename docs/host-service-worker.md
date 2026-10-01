# Host device-service ownership

`LightTouchServices` runs the existing libimobiledevice AFC, lockdown,
installation-proxy, SpringBoard and notification-proxy engines outside the GUI.
It does not load QEMU or manipulate NAND. The GUI retains interaction policy and
media identity; it sends typed commands over a private child-process stdin/stdout
channel. No library engine falls back into the shipping GUI when the worker is
missing.

Each worker has an immutable usbmux socket, optional UDID and boot UUID.
`HostServiceWorkers` owns one command child per endpoint plus independent
notification subscription children. A command deadline or cancellation kills
and reaps its child before returning; queued work starts in a fresh process.
`stopWorker()` retires that boot scope, cancels subscriptions and waits for every
child. Old requests cannot reopen it. QEMU is a separate process and survives a
service-worker restart. A child also exits when its owning parent disappears.

The narrow Foundation wire types are shared source files compiled into both
targets. Existing C error types survive encoding, so reconnection and install
queue policy continue to see the original errors. Host downloads land in a
private temporary directory and are published by the caller after a successful
response and cancellation check. Killing a transfer can leave guest temporary
staging files; the existing startup staging sweep handles known orphan names.
This is not a filesystem transaction or a guarantee that a cancelled guest
installation has rolled back.

Xcode embeds `LightTouchServices` beside `LightTouchDevice`. `package.sh` checks
its architecture/deployment target and signs it with the other host executables.
It reuses the already packaged libimobiledevice/libplist dynamic libraries and
Swift Subprocess; existing dependency license/provenance collection applies.
There is no new third-party implementation or separately configured hook.

The standalone session harness builds the same production worker by default.
`--service-worker PATH` verifies an explicitly supplied packaged executable;
release verification uses this option. `LTM_HOST_SERVICE_WORKER` is an internal
test override. `check-host-service-workers.py` exercises a genuinely blocked
native C factory, independent device routing, PID replacement, cancellation,
notification teardown and retired-scope rejection. C-engine fixtures still
inject their local engines to test service-specific races independently.
