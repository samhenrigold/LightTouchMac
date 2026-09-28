# Device Hub capture interface — September 20, 2026

Reference binary: Xcode 27 Release Candidate’s `DeviceKit.framework`. Inspected its Swift metadata with `swift-section` and its implementation through Hopper MCP. Addresses below are unslid offsets in this binary, not runtime dependencies. Light Touch uses public SwiftUI/AppKit APIs; it does not load DeviceKit.

**Superseded control layout:** the later September 20 request removes the floating action bar and adopts WireView's capture actions in the native toolbar. The findings below document the earlier Device Hub comparison. Only transient saved-capture feedback retains this banner design; current commands and shortcuts are in [Command organization](../Command-organization.md).

## Recovered implementation

| Element | Evidence | Applied behavior |
| --- | --- | --- |
| Action bar groups | `ActionBar`, `0x62744`, `0x62e8c` | Regular SwiftUI glass with capsule shape, 36-point height, 4-point interior padding, 2-point spacing between grouped buttons. Separate rotation group. |
| Buttons | `ActionBarButtonStyle`, `0x63398`, `0x636e4`, `0x63acc` | 32-point grouped width, title3 regular symbols, secondary color at 10% on hover and primary at 15% when pressed. No interactive-glass modifier. |
| Recording | `0x76394`, `0x77374` | Black elapsed time; 28-point red Stop circle, caption2 symbol, 15% red background, 12-point spacing. |
| State animation | `ActionBar.body`, `0x615c8` | SwiftUI default animation for the changing controls. |
| Banner container | `AnimatedBannerContainer`, `0xcc6d0`, `0xc8b18` | 48-point height, 6-point content spacing; trailing inset calculated from accessory height. |
| Saved banner shape | `BuiltInBannerProviders.bannerProviders`, `0x6179fc`; constant `0x743c28` | Saved feedback uses a rounded rectangle with a **14-point** corner radius; ordinary progress uses the default capsule. |
| Banner type | `0xcb7bc` | Subheadline text with medium-weight title. |
| Banner animation | `0xcac8c` | 0.2-second ease-out visibility change; opacity transition. |
| Thumbnail and actions | `0xfce28`, `0xfe6d0`, `0xfeab0`, `0xcc4e4` | 28-point thumbnail with 5-point corners and 2-point padding, drag preview, circular bordered chevron and dismiss actions. |

The saved banner replaces the previous large Open/Reveal button strip and permanent thumbnail bubble. Recording thumbnails use the recording’s first captured frame. Light Touch retains a bounded 300-point banner width for its smaller supported windows; Device Hub sizes its generic banner content dynamically and adds trailing space to the saved-capture subtitle.

## File lifecycle

Each saved banner watches its own file with a filesystem event source. Deleting it or moving/renaming it (including Finder’s move to Trash) fades out the banner because its saved URL is no longer usable. Clipboard captures have no file watcher. A presentation identifier and canceled event source prevent an older capture from dismissing a replacement. Watchers and timers are released on replacement or dismissal.

Saved feedback disappears after five seconds, pauses while hovered, and respects Reduce Motion when dismissing. Controls remain in a nonactivating child panel excluded from the canvas capture, with room for the native glass shadow. The gradient and device extend beneath the bar when zoomed.

## Verification

- Built and launched with Xcode MCP. No compiler errors.
- Inspected the production SwiftUI controls in a temporary native review window, including idle, recording, busy, and saved-thumbnail states. Inspected the live app’s bottom controls over its gradient.
- Native checks cover 360/500/720-point windows, recording width, 12-point bottom placement, rapid hide/show, activation recovery, automatic dismissal, PNG/MOV deletion and moves, and replacement while an older file event is queued.
- Recording lifecycle checks cover first-frame thumbnail retention/reset alongside stop during startup, discard, save collisions, retry, and partial-file recovery.
- Xcode’s RenderPreview service failed with an XPC connection error; the native review window supplied the visual check instead. This is not a claim of a pixel-by-pixel comparison of the entire Device Hub application.
