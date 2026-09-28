# Transfers, connection feedback, and fresh windows

September 20, 2026.

## Media imports

Photos and music already joined the app-install queue, but their rows were invisible in Store mode and when the inspector was closed. An accepted external import now opens the inspector, selects Installed, and reveals its progress. Ready media waits behind active transfers with “Waiting for other transfers…”; downloads and preparation do not reserve the guest connection. Cancellation, failure, and Retry remain attached to the row. Drops recheck readiness at release, and mixed drops identify unsupported files instead of silently omitting them.

MP4, M4V, and MOV inputs now use Apple's iPod export preset before entering the same transfer path. Prepared videos use the guest's existing movie-library import API. A private, atomic conversion cache preserves exact output bytes across retries because repeated H.264 encodes are not necessarily identical. The original file is never rewritten.

## Connection handling

Queued removals no longer suppress health reads when the transfer queue is paused. Only active work, boot preparation, or connection recovery holds those reads back. Cancellation and an installation service reporting “operation in progress” do not declare the device dead or restart its management service.

USB attachment and app-service readiness are checked separately. Failure feedback distinguishes connection loss, app-service interruption, missing libraries, pairing, a locked iPod, and activation. Persistent diagnostics record the operation, underlying error, elapsed time, guest-agent availability, and outstanding blocked requests. Repeated eligible management failures retain the existing bounded recovery and cooldown. A single failed list refresh no longer claims the filesystem is damaged or recommends erasing the device.

The notification-session and installation-connection corrections, their library-source evidence, and the limits of the historical logs are described in [UX-emulator-followups.md](UX-emulator-followups.md). The old logs do not establish the initial trigger for every earlier warning.

## Window restoration

Each launch creates a fresh Mac interface. The application declines state encoding and decoding, ignores old saved UI state, disables snapshot restoration for its windows, and no longer restores window frames or split positions. Guest device storage, toolbar configuration, and capture preferences are independent of this policy.

## Verification

- Native regression fixtures cover media FIFO ordering behind installs, progress visibility, mixed-file drops, readiness changing during a drag, cancellation, pause/resume, video preparation, and exact retry bytes.
- Health fixtures cover queued reads, cancellation, shutdown, busy-service classification, boot/transfer guards, and bounded automatic recovery.
- Notification and service-connection fixtures exercise the production Swift code against controlled native service behavior, including disconnects and late cleanup.
- Installation startup fixtures cover the ten-second deadline, cancellation at handoff, late connection cleanup, and reuse of the device gate after a timeout.
- A disposable guest accepted a converted video into Videos. Three imports reconciled to one library item, and the guest shut down cleanly. The stale development media helper was rebuilt and replaced after this check.
- The Xcode MCP build was launched and inspected. Files was open before quitting; the next launch opened only the device window. Starting an import with the inspector hidden revealed Installed immediately. An intentionally unreadable test image retained a failure row with Retry; the test row was then dismissed without changing guest media.
- The final build was launched again after confirmed guest power-off. Only the main window opened, installed apps loaded, and startup completed without a connection warning.
