#!/usr/bin/env python3
"""Execute the production boot owner: retirement cancels every task/observer."""
import pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = r'''import Foundation
@main struct Probe {
    @MainActor static func main() async throws {
        let owner = BootSessionScope()
        let oldID = owner.id
        let oldGeneration = owner.generation
        var completions = 0
        var observations = 0
        for key in BootSessionScope.Work.allCases {
            owner[key] = Task {
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
                completions += 1
            }
        }
        let name = Notification.Name("scope-probe")
        owner.timeZoneObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { observations += 1 }
        }
        NotificationCenter.default.post(name: name, object: nil)
        precondition(observations == 1)
        owner.retire()
        NotificationCenter.default.post(name: name, object: nil)
        owner[.foreground] = Task {
            guard !Task.isCancelled else { return }
            completions += 100
        }
        try await Task.sleep(for: .milliseconds(120))
        precondition(completions == 0 && observations == 1)
        precondition(owner.generation > oldGeneration && owner.retired)
        owner.renew()
        precondition(owner.id != oldID && !owner.retired)
        owner[.foreground] = Task { completions += 1 }
        await owner[.foreground]?.value
        precondition(completions == 1)
        owner.retire()
        print("PASS: all boot work cancelled, observer removed, retired additions refused, next boot isolated")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-boot-scope-") as temporary:
    folder = pathlib.Path(temporary)
    main = folder / "main.swift"
    main.write_text(SOURCE)
    executable = folder / "probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(ROOT / "LightTouchMac/Device/BootSessionScope.swift"), str(main), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
