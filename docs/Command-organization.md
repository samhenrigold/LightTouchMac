# Command organization

The default experience has two command surfaces:

- **Toolbar:** Home Screen, Lock/Wake/Power On, Rotate, Zoom, Open Screenshot, Save Screenshot, Copy Screenshot, Record, app search, and inspector visibility. Files, Motion, Save Screenshot As, and Capture Options are optional items. Existing customized arrangements are preserved; capture actions are added once on migration. Rotate toggles portrait/landscape; Option reverses the next turn. Its icon, help, and accessible label follow that action. Record shows elapsed time and Stop during recording, then progress while saving. The floating bar is removed.
- **Menu bar:** the complete command directory, including keyboard equivalents and infrequent actions. Context menus contain only actions relevant to their target.

## Simplification

Capture follows WireView: Save Screenshot, Save Screenshot As, Copy Screenshot, Open Screenshot in the selected app; Start/Stop Recording and Discard Recording; Capture Screen Only and Capture Options. It stays flat. Options group save location, screenshot app, automatic copy/reveal, sound, Space action, and optional recording notifications. Defaults preserve Desktop and guest Space input. Captures include the canvas by default. Recording failures offer another destination and retain the take if cancelled. Launch recovery salvages playable older movies; Help contains Show Unfinished Recordings.

Device has Home Screen, Lock, three shallow groups (Orientation, Input, Network), and Pause, Restart, Power Off, Erase. Orientation includes Upright, Flat, and Reset Tilt; Input contains Shake, volume, and keyboard options. SSH, Restart SpringBoard, and boot-debugging toggles no longer appear in the ordinary menus. General Settings stays removed; Capture Options contains only capture choices.

Apps uses concise selection-based Open, Uninstall, Install, and Choose Version commands. Installed apps do not offer a redundant disabled Install command. Copy Bundle Identifier is removed. Import Media describes the one-way import accurately. External catalog links consistently say View on Legacy Store.

## Command homes and shortcuts

| Menu | Responsibility | Main shortcuts |
| --- | --- | --- |
| File | Files-window transfers, refresh, close | Close ⌘W |
| Edit | Native editing, Find, device text selection and paste | Find ⌘F; Search Apps ⌥⌘F; Paste Text to iPod/iPad ⌃⌘V |
| View | Zoom, inspector, finger dots, hidden files, toolbar | Physical Size ⌘0; Fit ⌘9; Zoom ⌘+/−; Inspector ⌥⌘I; Toolbar ⌥⌘T |
| Device | Physical input, orientation, network, device state | Home ⇧⌘H; Lock ⌘L; Rotate ⌘[/]; Volume ⌥⌘↑/↓ |
| Apps | Install/import and actions on the selected app | Install ⇧⌘I |
| Capture | Take, copy, record, and choose output | Save ⌘S; Save As ⇧⌘S; Open ⌘O; Record ⌘R; Discard ⌘. |
| Window | Open and manage app windows | Device ⌘1; Files ⌘2; Minimize ⌘M |
| Help | Instructions, recording recovery, logs, diagnostics | Help ⌘? |

Native text editing keeps its usual shortcuts. Standard Copy (⌘C) copies a screenshot only when the device screen has focus and Live Text is inactive. Configured Space actions also require the device screen, no sheet, and no modifiers; Space defaults to guest input. Find searches apps in the device window and text in Help/Logs. Rotation avoids reserved Command-arrow keys. Context menus omit shortcut labels. Files commands follow the active window's responder chain; explicitly targeted Apps commands disable when another window is main.

## HIG rationale

Source: the supplied *OS X Human Interface Guidelines*, October 16, 2014, printed page numbers:

- **49–51, 75–83:** short action labels, meaningful groups, ellipses for required input or confirmation, checkmarks for attributes, and Show/Hide for visibility. Disabled commands keep their positions; Discard Recording remains discoverable between takes.
- **91–102:** standard File/Edit/View/Window/Help responsibilities. Window orders Minimize and Zoom before app-window commands, Bring All to Front, and AppKit's open-window list.
- **105–110:** shallow menus and relevant contextual actions. Frequent capture commands need no submenu traversal.
- **137–141:** a small, customizable default toolbar with menu equivalents. The toolbar is the sole persistent control surface; the canvas reserves no space for a separate bar.
- **297–308:** preserve reserved keys and standard editing. Use Command-S for saving, recommended inspector/toolbar/search shortcuts, and no arbitrary shortcuts for infrequent device tools.

Modern native AppKit controls and Liquid Glass remain in use; this document applies the older HIG's organization principles, not its visual styling.

## Verification

Xcode MCP build passes. Focused native checks pass for menu organization and shortcuts, portrait/landscape toggling and Option reversal, app selection and window scope, capture layout and deletion/move dismissal, capture destinations, and Help. The capture banner exposes its current file so a newer screenshot's Reveal action cannot open an earlier recording. A copied screenshot has no saved-file target.

Live checks confirmed the Orientation/Input grouping and that Find focuses the attached app search field. The search toolbar item is now attached only when inserted; customization previews no longer take ownership of the live search field. Recording lifecycle checks verify one start/stop sound per take, with no sound for failed startup or save retries. Screenshot, start and stop use the same system sound IDs as WireView.

The toolbar-only pass was built with Xcode MCP and inspected in the running Debug app. Command-R started recording and displayed elapsed time beside Stop. Command-period showed Discard, Stop and Save, and Cancel; cancelling left the take running, and Command-R saved it directly to Desktop. The 37-second MOV has H.264 video and AAC audio. A decoded frame contains the full canvas and excludes toolbar, inspector, and feedback. Capture Options was visually checked with Desktop, Preview, guest Space input, and notifications off by default. Native checks cover recording button sizing/progress, menu shortcuts, Copy responder routing, Space ownership across repeats/focus/modifier changes, cancellation and fallback saves, real-MOV recovery, file-deletion feedback, and device geometry/input.

The September 20 pass also checks that confirmed removals wait behind installs, remain represented while waiting, and keep Quit aware of pending work. Unchanged sidebar polls retain native row controls, so another app's progress does not replace the button being clicked. Open wakes a sleeping iPod; a locked iPod gets a short unlock instruction rather than raw command output.

The remaining Diner Dash visual check is tracked in [UX-emulator-followups.md](archive/UX-emulator-followups.md). Google Search's legacy-browser rejection and proxy-panel verification are tracked in [Proxy-compatibility.md](archive/Proxy-compatibility.md).
