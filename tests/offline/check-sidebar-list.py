#!/usr/bin/env python3
"""The sidebar's list (SidebarList): which entries it shows, in what order, what each row says, and what persists.

Compiles SidebarList.swift with the real FirmwareCatalog and DeviceRow against the shipped catalog, on a throwaway
UserDefaults suite. Checks:
- titles: one kind of device -> "iOS 4.1" (Beta tag beside it); several -> the product name over the version; a
  custom name -> the name over "iPod touch 2G, iOS 4.1";
- rename: saved and read back by a fresh load; an empty name or the default title clears it; removing forgets it;
- migration: no saved list -> the entries the user owns (prepared / downloaded / in flight), else first_run;
  a saved list (even empty) is kept as saved, entries the catalog dropped are skipped;
- order: whatever order entries are added in, rows list per board in version order, betas before their release;
- removal: a prepared device's row says Delete Device… and asks through delete; others say Remove Device; nothing
  running or in flight can leave.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from firmwarekit_leaf import schema_sources
import subprocess, tempfile

app = Path(__file__).resolve().parents[2] / 'LightTouchMac'

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let suite = "ltm-check-sidebar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Migration: a fresh install gets first_run, saved at once.
        var list = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(list.ids == ["k48ap-7B500"], "fresh install: \(list.ids)")
        precondition(defaults.stringArray(forKey: SidebarList.entriesKey) == ["k48ap-7B500"], "fresh install not saved")
        // An updating user keeps what they own, in catalog order; first_run isn't forced in.
        defaults.removeObject(forKey: SidebarList.entriesKey)
        let owned: Set = ["n72ap-7E18", "n72ap-8B117", "k48ap-8C148"]
        list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
        precondition(list.entries(in: catalog).map(\.id) == ["k48ap-8C148", "n72ap-7E18", "n72ap-8B117"], "migration: \(list.ids)")
        // Once saved, the list rules: owned entries the user removed don't return on the next launch.
        list.remove("n72ap-7E18")
        list.save(defaults)
        list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
        precondition(Set(list.ids) == ["k48ap-8C148", "n72ap-8B117"], "reload after remove: \(list.ids)")
        // An empty list stays empty (the sidebar shows Add Device…); ids the catalog lost are dropped.
        SidebarList(ids: []).save(defaults)
        precondition(SidebarList.load(defaults, catalog: catalog) { _ in true }.ids.isEmpty, "empty list refilled")
        SidebarList(ids: ["n72ap-gone", "n72ap-8C148"], names: ["n72ap-gone": "Old"]).save(defaults)
        list = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(list.ids == ["n72ap-8C148"] && list.names.isEmpty, "stale ids: \(list)")

        // Order: added backwards and interleaved, listed per board in version order, betas before the release.
        list = SidebarList()
        list.add(["n72ap-8C148", "n72ap-8B117", "k48ap-7B500", "n72ap-8B5080c", "n72ap-5F138", "k48ap-7B367"])
        precondition(list.add(["n72ap-8B117"]) == false, "added twice")
        let order = list.entries(in: catalog).map(\.id)
        precondition(order == ["k48ap-7B367", "k48ap-7B500", "n72ap-5F138", "n72ap-8B5080c", "n72ap-8B117", "n72ap-8C148"], "order: \(order)")

        // Titles: one kind of device.
        list = SidebarList(ids: ["n72ap-8B117", "n72ap-8B5080c"])
        precondition(list.label(for: entry("n72ap-8B117"), in: catalog) == .init(title: "iOS 4.1"), "same kind")
        precondition(list.label(for: entry("n72ap-8B5080c"), in: catalog) == .init(title: "iOS 4.1", badge: "Beta 1"), "same kind beta")
        // Several kinds: the product name the app uses, the version under it.
        list.add(["k48ap-7B500"])
        precondition(list.label(for: entry("n72ap-8B117"), in: catalog) == .init(title: "iPod touch 2G", subtitle: "iOS 4.1"), "mixed: \(list.label(for: entry("n72ap-8B117"), in: catalog))")
        precondition(list.label(for: entry("n72ap-8B5080c"), in: catalog) == .init(title: "iPod touch 2G", subtitle: "iOS 4.1 Beta 1"), "mixed beta")
        precondition(list.label(for: entry("k48ap-7B500"), in: catalog) == .init(title: "iPad", subtitle: "iOS 3.2.2"), "mixed iPad")
        list.add(["n45ap-4B1"])
        precondition(list.label(for: entry("n45ap-4B1"), in: catalog) == .init(title: "iPod touch 1G", subtitle: "iOS 1.1.5"), "mixed 1G")
        list.remove("n45ap-4B1")

        // Rename, and the subtitle a custom name gets, in either mode.
        list.rename("n72ap-8B117", to: "  Test Rig ", defaultTitle: "iPod touch 2G")
        precondition(list.label(for: entry("n72ap-8B117"), in: catalog) == .init(title: "Test Rig", subtitle: "iPod touch 2G, iOS 4.1"), "renamed")
        list.remove("k48ap-7B500")
        precondition(list.label(for: entry("n72ap-8B117"), in: catalog) == .init(title: "Test Rig", subtitle: "iPod touch 2G, iOS 4.1"), "renamed, one kind")
        list.save(defaults)
        var reloaded = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(reloaded.names == ["n72ap-8B117": "Test Rig"] && reloaded == list, "names not persisted: \(reloaded)")
        reloaded.rename("n72ap-8B117", to: "iOS 4.1", defaultTitle: "iOS 4.1")
        precondition(reloaded.names.isEmpty, "the default title became a custom name")
        reloaded.rename("n72ap-8B5080c", to: "Beta", defaultTitle: "iOS 4.1")
        reloaded.rename("n72ap-8B5080c", to: "   ", defaultTitle: "iOS 4.1")
        precondition(reloaded.names.isEmpty, "an empty name kept")
        reloaded.rename("n72ap-8B117", to: "X", defaultTitle: "iOS 4.1")
        reloaded.remove("n72ap-8B117")
        reloaded.add(["n72ap-8B117"])
        precondition(reloaded.names.isEmpty, "a removed row kept its name")

        // Removal: prepared -> Delete Device… (asks, through delete); nothing on disk -> Remove Device.
        let e = entry("n72ap-8B117")
        func row(_ instance: UUID?, session: SessionPhase? = nil, job: FirmwareJob? = nil, downloaded: Bool = false) -> DeviceRow {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, failure: nil, downloaded: downloaded)
        }
        let prepared = row(UUID())
        precondition(prepared.removeTitle == "Delete Device…" && prepared.canRemoveFromSidebar, "prepared")
        precondition(row(nil).removeTitle == "Remove Device" && row(nil).canRemoveFromSidebar && row(nil, downloaded: true).canRemoveFromSidebar, "not prepared")
        precondition(!row(UUID(), session: .running).canRemoveFromSidebar, "a running device left the sidebar")
        precondition(!row(nil, job: .downloading(fraction: 0.3)).canRemoveFromSidebar, "a download in flight left the sidebar")
        precondition(!row(nil, job: .preparing(Preparation(name: "x"))).canRemoveFromSidebar, "a preparation in flight left the sidebar")
        print("PASS: sidebar list: migration, catalog order, titles and subtitles, rename persistence, removal")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-sidebar-list-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), *schema_sources(), '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceRow.swift'), str(app / 'Library/SidebarList.swift'),
                    str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json')], check=True, timeout=60)
