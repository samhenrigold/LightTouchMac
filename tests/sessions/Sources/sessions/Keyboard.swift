import Foundation
import SessionKit

/// `sessions keyboard BASE [--overlay DIR]` (an n81ap or n90ap base): the Mac's keyboard types into the guest (the
/// app's key path: .key -> key_mac -> the usb-kbd the boot attaches): a new note in Notes takes a word typed as Mac
/// keys, and the guest agent reads it back from Notes' store. A 5.x-7.x base sits in Setup on its first boot: prepare
/// it with --skip-setup, or pass --overlay, the overlay of a boot that walked Setup, cloned.
func keyboardCheck(_ args: KeyboardCheck) -> Never {
    let base = Base(args.base, args.inputs)
    // ponytail: the iPad (k48ap) has the keyboard too, but where its Notes puts + is unmeasured.
    guard ["n81ap", "n90ap"].contains(base.board) else { die("keyboard boots an n81ap or n90ap base") }
    let work = workDirectory(args.inputs, "keyboard")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    if let source = args.overlay {
        let overlay = work.appendingPathComponent("keyboard/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    } else if base.bootsIntoSetup {
        die("a \(base.version) base is in Setup on its first boot: prepare it with --skip-setup or pass --overlay")
    }
    let slide = "dragshown 0.18 0.9 0.92 0.9"
    let word = "lighttouch"
    let d = HelperDriver(
        "keyboard",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "keyboard",
            steps: [
                // As rotation: Home (two slides; on Home the second is a page swipe). Notes' + (top right) opens a
                // new note with the insertion point in it; Home saves it, and the agent reads Notes' store back.
                "boot", "lit 0.03 300", "wait 5", "button 0", "wait 2", slide, "wait 4", "button 0", "wait 2", slide,
                "wait 4", "agentop launch com.apple.mobilenotes", "wait 10", "tapshown 0.92 0.088", "wait 4",
                "keys \(word)", "wait 2", "button 0", "wait 6",
                "agentget notes.sqlite /var/mobile/Library/Notes/notes.sqlite",
                "agentget notes.sqlite-wal /var/mobile/Library/Notes/notes.sqlite-wal",
                "quit", "expectExit 60"
            ]
        )
    )
    r.check(d.finish(600) == 0, "keyboard: scenario completed")
    let typed = ["notes.sqlite", "notes.sqlite-wal"].contains {
        (try? Data(contentsOf: d.dir.appendingPathComponent($0)))?.range(of: Data(word.utf8)) != nil
    }
    r.check(typed, "keyboard: a new note holds \"\(word)\" typed as Mac keys (Notes' store in \(d.dir.path))")
    finish(r, work: work)
}
