import Foundation
import Testing

@testable import LightTouchCore

/// The GL bridge's refusals as the reports send them: the emulator's lines decoded into the call, the enum or the
/// error, each name once per front app per device launch, a misbehaving app capped, and nothing but names and numbers.
struct GLESRefusalsTests {
    static let lines = """
        clientstate:0x86ad\t3\t
        glerror:174:0x500\t1\tglMatrixMode
        slot:807\t12\tglCurrentPaletteMatrixOES
        shim:unimpl:glFogxv\t4\tglFogxv

        """

    @Test func eachLineGivesItsCallAndItsEnumOrError() {
        var refusals = GLESRefusals()
        #expect(
            refusals.reports(Self.lines, frontApp: "com.example.game") == [
                ["refusal": "clientstate:0x86ad", "kind": "clientstate", "enum": "0x86ad"],
                ["refusal": "glerror:174:0x500", "kind": "glerror", "call": "glMatrixMode", "error": "0x500"],
                ["refusal": "slot:807", "kind": "slot", "call": "glCurrentPaletteMatrixOES"],
                ["refusal": "shim:unimpl:glFogxv", "kind": "shim", "call": "glFogxv"]
            ]
        )
    }

    @Test func aNameIsReportedOncePerFrontApp() {
        var refusals = GLESRefusals()
        #expect(refusals.reports(Self.lines, frontApp: "com.example.game").count == 4)
        // the same app refused the same calls again
        #expect(refusals.reports(Self.lines, frontApp: "com.example.game").isEmpty)
        // another app, and the Home screen (no app known in front), each hit them too
        #expect(refusals.reports("slot:807\t13\tglCurrentPaletteMatrixOES\n", frontApp: "com.example.other").count == 1)
        #expect(refusals.reports("slot:807\t14\tglCurrentPaletteMatrixOES\n", frontApp: nil).count == 1)
        #expect(refusals.reports("slot:807\t15\tglCurrentPaletteMatrixOES\n", frontApp: nil).isEmpty)
        // a new device launch starts over
        var next = GLESRefusals()
        #expect(next.reports("slot:807\t1\tglCurrentPaletteMatrixOES\n", frontApp: "com.example.game").count == 1)
    }

    @Test func aMisbehavingAppIsCapped() {
        var refusals = GLESRefusals()
        let flood = (0..<100).map { "present:size:\($0)x\($0)\t1\t" }.joined(separator: "\n")
        #expect(refusals.reports(flood, frontApp: "com.example.flood").count == GLESRefusals.perApp)
        #expect(refusals.reports(flood, frontApp: "com.example.flood").isEmpty)
        // other apps still report, until the launch's limit
        var total = GLESRefusals.perApp
        for app in 0..<10 { total += refusals.reports(flood, frontApp: "com.example.app\(app)").count }
        #expect(total == GLESRefusals.perLaunch)
        #expect(refusals.reports("slot:807\t1\tglCurrentPaletteMatrixOES\n", frontApp: "com.example.late").isEmpty)
    }

    @Test func aNameThatCouldCarryMoreThanNamesAndNumbersIsDropped() {
        var refusals = GLESRefusals()
        let bad = [
            // a guest shim's name is the guest's own text: a path, words
            "shim:/private/var/mobile/Applications/0F1E/Game.app/Game\t1\t",
            "shim:unimpl:/var/mobile/Library/x\t1\t",
            "shim:Users/someone/Documents\t1\t",
            "shim:unimpl:gl Fog with spaces\t1\t",
            // a call that isn't a GL function's name
            "slot:807\t1\t/Users/someone/qemu",
            "shim:unimpl:x\t1\tnot-a-gl-call",
            // not a line of the table
            "slot:807", "slot:807\tmany\tglFoo", "\t1\t", "slot\t1\t", "slot::807\t1\t",
            String(repeating: "a", count: 90) + ":1234567\t1\t"
        ]
        #expect(refusals.reports(bad.joined(separator: "\n"), frontApp: "com.example.game").isEmpty)
        // what does go is names and numbers only, with no path and no space in any value
        let good = refusals.reports(Self.lines + "teximage:0x1906/0x8033\t2\t\n", frontApp: "com.example.game")
        #expect(good.count == 5)
        for report in good {
            #expect(Set(report.keys).isSubset(of: ["refusal", "kind", "call", "error", "enum"]))
            for value in report.values {
                #expect(!value.hasPrefix("/") && !value.contains(" ") && value.filter { $0 == "/" }.count <= 1)
            }
        }
    }
}
