# Console split: Xcode's debug area, read from IDEKit

The main pane (between the sidebar and the inspector) is a vertical split: the device, or its prepare placeholder, on top; the console below; and a bar between them that stays when the console is hidden. This is Xcode's editor/debug-area split. The source is in `LightTouchMac/UI/ConsoleSplit.swift`, and `tests/offline/check-console-split.py` checks it.

## How Xcode builds it (Xcode 27.0 RC, static reading)

Sources: `nm -m`, `strings`, `llvm-objdump -d` on `Frameworks/IDEKit.framework`, `SharedFrameworks/DVTUserInterfaceKit.framework`, and `PlugIns/IDEConsoleKit.framework`, plus `IDEKit.xcplugindata` (the command and menu definitions). Only names and constants are read; no code is copied.

### The pieces

| Piece | Class / member | What it does |
|---|---|---|
| Split owner | `IDEEditorArea`, ivars `_debuggerSplitView` (a `DVTSplitView`), `_editorSplitViewItem`, `_debugAreaSplitViewItem`, `_bottomBar`, `_heightToReturnToDebuggerArea` | editor on top, debug area below; it's the split's delegate |
| Split view | `DVTSplitView` (DVTUserInterfaceKit) | an `NSSplitView` that forwards every delegate call to `dvt_delegate`. `-splitView:constrainSplitPosition:ofSubviewAt:` floors the position (`frintm`) and skips dividers that are animating (`_skipDividerIndexDuringAnimation:`). State is saved under `DVTSplitViewItems` (`commitStateToDictionary:`) |
| Pane | `DVTSplitViewItem`: `setVisible:`, `toggleVisibilityUsingAnimation`, `savedViewMagnitude`, `recordCurrentFrameSize`, `collapseExpandStyle` | hiding a pane saves its size; showing it again restores that size |
| Animation | `DVTSplitViewAnimation` (`_computeStartFrames`, `_computeStopFrames`, `setCurrentProgress:`) | frame animation between the two layouts |
| The bar | `IDEBottomBar` (Swift, `IDEKit/Editor/Views/BottomBar/IDEBottomBar.swift`), items from `…BottomBarItemProvider` classes: `IDEBottomBarVisibilityButtonProvider`, `IDEPauseResumeBottomBarItemProvider`, `IDESteppingControlsBottomBarItemProvider`, `IDEBreakpointActivationBottomBarItemProvider`, `IDEStackFrameBottomBarItemProvider`, `IDESimulatedLocationBottomBarItemProvider`, `IDEDebugOverridesBottomBarItemProvider` | the debug bar. Items show by context keys (`IDEBottomBarContextKeyDebugSessionActive`, …); with no debug session only the visibility toggle is left |
| Bar height | `static DVTControlBar.defaultBarHeight` | 36 pt in the new design, 27 pt otherwise (`mov #0x4042…` = 36.0, `fmov #27.0`, chosen by a design check) |
| Console footer | IDEConsoleKit: `filterField` / `filterFieldItem` ("Filter Console"), `clearItem` / `clearConsole:`, `metadataPicker` | the console's own filter field and clear button |

### Constraints, grab area, double-click

- `-[IDEEditorArea splitView:constrainMinCoordinate:ofSubviewAt:]`: the lowest divider position is the primary editor's `minimumContentViewFrameSize.height` plus the bottom bar's frame height, so the bar belongs to the divider.
- `-[IDEEditorArea splitView:constrainMaxCoordinate:ofSubviewAt:]`: the highest position is the split's height minus `activeDebuggerArea.preferredMinimumSize.height`. `-[IDEDefaultDebugArea preferredMinimumSize]` returns a height of **100.0** (`mov x8, #0x4059000000000000`).
- `-[IDEEditorArea splitView:canCollapseSubview:]` returns YES. The collapse is AppKit's: a collapsible pane collapses once the drag passes half of its minimum, so the debug area collapses below **50 pt**.
- `-[IDEEditorArea splitView:constrainSplitPosition:ofSubviewAt:]` changes no positions. It clears `_heightToReturnToDebuggerArea` (`str xzr`): a user drag replaces any height the window took away.
- `-[IDEEditorArea splitView:additionalEffectiveRectsOfDividerAtIndex:]`: the bar is the grab area. It takes the bar's bounds, a 4 pt strip at its top edge (`fadd y, -2.0`, `fmov height, #4.0`), and the rects from `IDEBottomBar.additionalGrabRectsForSplitViewDivider()` (the empty stretches between the bar's items). When the debug area is hidden, the rect is clipped to the window's content inset by 3 pt.
- `-[IDEEditorArea splitView:doubleClickedOnDividerAtIndex:]`: if the editor is hidden, `showEditor`; else if the debug area is hidden, `showDebuggerArea`; else `hideDebuggerArea`. It returns YES.

### Snapping detents (where Xcode snaps)

- `-[DVTTheme splitViewDividerSnappingTolerance]` returns **10.0**. Three places read it:
  - `-[IDEWorkspaceDesignAreaSplitViewController splitView:constrainSplitPosition:ofSubviewAt:]`, divider 0: if `|proposed − (navigatorAreaDefaultWidth [+ 8])| < tolerance`, it returns the default width. This is a detent at the pane's default size.
  - `-[IDESplitViewDebugArea splitView:constrainSplitPosition:ofSubviewAt:]` (the variables|console split inside the debug area): `mid = rint((minPossiblePositionOfDividerAtIndex + maxPossiblePositionOfDividerAtIndex) × 0.5)`. A proposal inside `(mid − tol, mid + tol)` becomes `mid`. This is a detent at the middle of the range; the tolerance is cached once in a `dispatch_once` block.
  - `-[IDEEditorGeniusMode splitView:constrainSplitPosition:ofSubviewAt:]`, for the assistant editor.
- The editor/debug split has no snap of its own. Its rest points are the collapse (below half the minimum), the 100 pt minimum, and the editor's minimum.

### Show/hide and resizing

- `-[IDEEditorArea toggleDebuggerVisibility:]` → `_setShowDebuggerArea:!visible animate:DVTTheme.currentTheme.shouldUseMotionAnimations`. With animation it calls `DVTSplitViewItem toggleVisibilityUsingAnimation`; without, `setVisible:`. Either way it then calls `stateToken.stateChanged` (autosave).
- `-[IDEEditorArea _updateDebuggerBarSplitPane]`: moves the bottom bar between the editor container (`setBottomBar:`) and the debug area, so the bar sits at the divider in both states. It sets the bar's `borderSides` by visibility, then `invalidateCursorRectsForView:`.
- `-[IDEEditorArea splitView:resizeSubviewsWithOldSize:]` → `_resizeSubviewsForHeightDecrease:` / `…Increase:`. When the window shrinks, the editor gives up height down to its minimum (plus the bar), then the debug area shrinks, and the shortfall adds to `_heightToReturnToDebuggerArea`. When it grows, the debug area gets that height back first (`min(delta, heightToReturn)`) and the editor takes the rest.
- Command: `Xcode.IDEKit.CmdDefinition.DebuggerToggleVisibility` in `IDEKit.xcplugindata`: action `toggleDebuggerVisibility:`, title "Show Debug Area", key `y` with `useCommandKey` and `useShiftKey` (**⇧⌘Y**), symbol `inset.filled.bottomthird.square`, in the View ▸ Debug Area menu after "Activate Console".
- Persistence: `DVTSplitView` and `IDESplitViewDebugArea` implement `commitStateToDictionary:` / `revertStateWithDictionary:` with a `stateToken`. This is the workspace state saving that brings each window's layout back.

## What Light Touch does

| Xcode | Light Touch (`ConsoleSplit.swift`) |
|---|---|
| debug area minimum 100 pt; collapse past half of it | `ConsoleSplitLayout.minimumHeight = 100`, `collapseThreshold = 50`; between 50 and 100 the drag clamps to 100 |
| snap tolerance 10, strict | `snapTolerance = 10`, `abs(clamped − detent) < 10` |
| detent at the pane's default size (navigator) | detent at `defaultHeight = 200`, which is also where a fresh console opens |
| detent at the rounded middle of the range (debug area) | detent at `rint((100 + maximum) / 2)`, where the maximum leaves the device 160 pt. Detents above the maximum are dropped |
| position floored | `.rounded(.down)` |
| drag replaces `_heightToReturnToDebuggerArea`; a shorter window squeezes the debug area and gives the height back | the chosen height is a `.defaultHigh` constraint, and the device's 160 pt minimum is priority 999; the saved height doesn't change when the window resizes |
| collapsing keeps `savedViewMagnitude` | hiding keeps `height`; a drag that ends collapsed keeps the height the drag started from |
| bar is the grab area; resize cursor on the empty stretches | `ConsoleBar` handles drags on its background; `resetCursorRects` covers the gaps between controls |
| double-click on the divider toggles | a double-click on the bar toggles |
| toggle animates unless motion is off | 0.2 s constraint animation unless Reduce Motion is on |
| bar stays when hidden, only the toggle without a session; `borderSides` by visibility | collapsed: the bar alone, only the toggle; expanded: log picker, Filter, Clear; a top line always, a bottom line while the console shows |
| ⇧⌘Y "Show Debug Area" | View ▸ Show Console / Hide Console, ⇧⌘Y (no other menu item uses it) |
| `stateToken` per window | `UserDefaults` key `ConsoleSplit <name>` (`main` for the device window): height and collapsed state |

Not carried over, because the app has no counterpart: the variables|console split and its layout modes, the debug bar's session controls (pause, step, breakpoints, which need a debugger), the metadata picker, and the 4 pt grab strip above the bar (the bar's own 36 pt is the grab area). Light Touch uses a constraint layout rather than an `NSSplitView`, because the bar is the divider: there is no pane to collapse, only a height between zero and the maximum.

The console is the Device Logs window's view (`LogTextView`, shared with `LogWindowController`). It shows a live, selectable 64 KB tail, pauses while text is selected, and polls only while the console is open. The picker offers the selected device's `serial.log` and `usbmuxd.log` and the app's `app.log` and `native.log` (Device Logs also has the rotated `.1` copies). Clear hides what the file held so far, as Xcode's `clearConsole:` does, and leaves the file alone. Filter keeps the lines that contain the text, ignoring case.
