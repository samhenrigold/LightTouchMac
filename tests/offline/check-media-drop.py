#!/usr/bin/env python3
"""Native file-drop acceptance and immediate visibility of non-Store transfers."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
display = (root / 'LightTouchMac/UI/DisplayView.swift').read_text()
inspector = (root / 'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()
drop = display[display.index('    override func draggingEntered('):display.index('\n}\n\n/// The shell\'s home button:')]
a = inspector.index('    @objc private func installStarted(')
started = inspector[a:inspector.index('\n    }', a) + 6].replace('private func', 'func')
code = r'''import Cocoa
nonisolated let device = UUID()
struct DeviceInstance { let id = device }
@MainActor final class EmulatorController { var canQueueInstall = true; let instance = DeviceInstance() }
struct CatalogApp: Codable { let id: Int }
@MainActor final class FirmwareJobs {
 static let shared = FirmwareJobs(); var imported: [String] = []
 func importIPSW(_ url: URL, for entry: Int?) { precondition(entry == nil); imported.append(url.lastPathComponent) }
}
enum PreparedMedia { static let extensions: Set<String> = ["png", "jpg", "mp3", "m4a", "mp4", "mov", "m4v"] }
extension NSPasteboard.PasteboardType { static let ltmCatalogApp = Self("test.catalog.app") }
@MainActor final class DropView: NSView {
 let emulator: EmulatorController? = EmulatorController()
 var onDropUnsupportedFiles: (([URL]) -> Void)?
 var onDropIPA: ((URL) -> Void)?, onDropMedia: ((URL) -> Void)?, onDropCatalogApp: ((CatalogApp) -> Void)?
''' + drop + r'''
}
@MainActor final class Drag: NSObject, NSDraggingInfo {
 let draggingPasteboard = NSPasteboard.withUniqueName()
 var draggingSource: Any?
 var draggingDestinationWindow: NSWindow? { nil }
 var draggingSourceOperationMask: NSDragOperation { .copy }
 var draggingLocation: NSPoint { .zero }
 var draggedImageLocation: NSPoint { .zero }
 nonisolated var draggedImage: NSImage? { nil }
 var draggingSequenceNumber: Int { 1 }
 var draggingFormation = NSDraggingFormation.default
 var animatesToDestination = false
 var numberOfValidItemsForDrop = 0
 var springLoadingHighlight = NSSpringLoadingHighlight.none
 func slideDraggedImage(to screenPoint: NSPoint) {}
 override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
 func resetSpringLoading() {}
 func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                             classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                             using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
 func files(_ names: [String]) {
  draggingPasteboard.clearContents()
  precondition(draggingPasteboard.writeObjects(names.map { URL(fileURLWithPath: "/tmp/" + $0) as NSURL }))
 }
}
@MainActor final class InstallJob { var catalogIpaID: Int?; let deviceID = device }
@MainActor final class TransferTable: NSTableView {
 var lastVisibleRow: Int?
 override func scrollRowToVisible(_ row: Int) {
  precondition(row >= 0 && row < numberOfRows, "accepted transfer must exist before scrolling")
  lastVisibleRow = row
  super.scrollRowToVisible(row)
 }
}
@MainActor final class Inspector: NSViewController, NSTableViewDataSource {
 enum PaneMode { case store, installed }
 var mode = PaneMode.store
 let emulator = EmulatorController()
 var pending: [InstallJob] = []
 let tableView = TransferTable()
 override func loadView() { view = NSView(); view.addSubview(tableView); tableView.dataSource = self }
 func setMode(_ mode: PaneMode) { guard self.mode != mode else { return }; self.mode = mode; reloadTablePreservingSelection() }
 func numberOfRows(in tableView: NSTableView) -> Int { mode == .installed ? pending.count : 0 }
 func reloadTablePreservingSelection() { tableView.reloadData() }
 func updateButtons() {}
 func showInstalledPlaceholder(_ text: String?) {}
''' + started + r'''
}
@main struct Check {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let view = DropView(), drag = Drag()
  defer { drag.draggingPasteboard.releaseGlobally() }
  var apps: [String] = [], media: [String] = [], catalog: [Int] = [], omitted: [String] = []
  view.onDropIPA = { apps.append($0.lastPathComponent) }
  view.onDropMedia = { media.append($0.lastPathComponent) }
  view.onDropCatalogApp = { catalog.append($0.id) }
  view.onDropUnsupportedFiles = { omitted.append(contentsOf: $0.map(\.lastPathComponent)) }
  drag.files(["App.IPA", "Photo.PNG", "Song.mp3", "Movie.MOV", "Notes.txt"])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 4)
  precondition(view.performDragOperation(drag))
  precondition(apps == ["App.IPA"] && media == ["Photo.PNG", "Song.mp3", "Movie.MOV"] && omitted == ["Notes.txt"])
  // The install queue remains an acceptable destination while another job
  // owns the device; readiness is rechecked if it goes away during a drag.
  precondition(view.draggingEntered(drag) == .copy)
  view.emulator!.canQueueInstall = false
  precondition(view.draggingUpdated(drag).isEmpty && !view.performDragOperation(drag))
  precondition(apps.count == 1 && media.count == 3)
  view.emulator!.canQueueInstall = true
  view.onDropMedia = nil
  drag.files(["Photo.png"])
  precondition(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
  // An IPSW goes to the library (matched by its SHA1), whatever the device is doing.
  view.emulator!.canQueueInstall = false
  drag.files(["iPad1,1_3.2.2_7B500_Restore.IPSW", "Notes.txt"])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
  precondition(view.performDragOperation(drag) && FirmwareJobs.shared.imported == ["iPad1,1_3.2.2_7B500_Restore.IPSW"])
  view.emulator!.canQueueInstall = true
  drag.files(["App.ipa"])
  drag.draggingSource = NSTableView()
  precondition(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
  // Explicit Store payloads remain accepted from inside the app.
  drag.draggingPasteboard.clearContents()
  let item = NSPasteboardItem()
  item.setData(try JSONEncoder().encode(CatalogApp(id: 42)), forType: .ltmCatalogApp)
  drag.draggingPasteboard.writeObjects([item])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
  precondition(view.performDragOperation(drag) && catalog == [42])

  let split = NSSplitViewController(), inspector = Inspector()
  split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
  let itemView = NSSplitViewItem(inspectorWithViewController: inspector)
  split.addSplitViewItem(itemView)
  let window = NSWindow(contentViewController: split)
  window.setContentSize(NSSize(width: 640, height: 480))
  _ = inspector.view
  itemView.isCollapsed = true
  let store = InstallJob(); store.catalogIpaID = 42
  inspector.installStarted(Notification(name: .init("start"), object: store))
  precondition(inspector.mode == .store && itemView.isCollapsed, "ordinary Store installs must not change the current view")
  let imported = InstallJob()
  inspector.installStarted(Notification(name: .init("start"), object: imported))
  precondition(inspector.mode == .installed && !itemView.isCollapsed)
  precondition(inspector.pending.last === imported && inspector.tableView.numberOfRows == 2)
  let queued = InstallJob()
  inspector.installStarted(Notification(name: .init("start"), object: queued))
  precondition(inspector.tableView.numberOfRows == 3 && inspector.tableView.lastVisibleRow == 2)
  print("PASS: mixed Finder drops queue supported files, recheck readiness, reject missing handlers/internal IPA drags, route IPSWs to the library, preserve Store drags, and reveal external transfer progress")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-media-drop-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
