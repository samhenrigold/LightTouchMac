// What the emulator's GL bridge refused, dropped or degraded of the guest's GL calls, as the reports send it
// (Guest.glRefused): the helper passes on each refusal whose count moved (qemu_ios_gles_refusals, LinkEvent
// .glesRefusals, at most once a second), and each name is reported once per front app per device launch, so the
// rendering gaps people's own apps hit show up without a bug report. Only the call's name and numbers go: a name
// that could carry anything else (a guest shim's names are the guest's text) is dropped whole.
// Pure Foundation; LightTouchCoreTests' GLESRefusalsTests.

import Foundation

public nonisolated struct GLESRefusals {
    /// The most reports for one front app, and for one device launch: an app that hits a new name with every frame
    /// (a size or an enum in it) sends no more than these.
    static let perApp = 8, perLaunch = 32

    private var sent: Set<String> = []
    private var sentFor: [String: Int] = [:]

    public init() {}

    /// The parameters of each refusal in `lines` ("NAME\tCOUNT\tCALL" lines, each a name refused again since the last
    /// ones) not yet reported with `frontApp` in front, within the limits. The app in front when the helper's poll saw
    /// the count move: across a switch, a refusal can go with the app before it.
    public mutating func reports(_ lines: String, frontApp: String?) -> [[String: String]] {
        let app = frontApp ?? ""
        var reports: [[String: String]] = []
        for line in lines.split(separator: "\n") {
            guard sent.count < Self.perLaunch, sentFor[app, default: 0] < Self.perApp else { break }
            guard let parameters = Self.parameters(line), let name = parameters["refusal"],
                sent.insert("\(app)\t\(name)").inserted
            else { continue }
            sentFor[app, default: 0] += 1
            reports.append(parameters)
        }
        return reports
    }

    /// One line's parameters: `refusal`, the name ("glerror:174:0x500"); `kind`, its first field; `call`, the GL
    /// function it is about, where the emulator named one; `error`, a glerror's GL error; `enum`, the first hex
    /// value of any other kind's. nil for a line that isn't one, or a name or call that is more than names and numbers.
    static func parameters(_ line: Substring) -> [String: String]? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 3, UInt64(columns[1]) != nil else { return nil }
        let name = columns[0]
        let call = columns[2]
        let fields = name.split(separator: ":", omittingEmptySubsequences: false)
        guard name.count <= 96, fields.count >= 2,
            fields.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_\-]{1,40}(\/[A-Za-z0-9_\-]{1,40})?/) != nil }),
            call.isEmpty || call.wholeMatch(of: /gl[A-Za-z0-9_]{1,62}/) != nil
        else { return nil }
        var parameters = ["refusal": String(name), "kind": String(fields[0])]
        if !call.isEmpty { parameters["call"] = String(call) }
        let hex = fields.dropFirst().first { $0.wholeMatch(of: /0x[0-9a-fA-F]{1,8}/) != nil }.map(String.init)
        parameters[fields[0] == "glerror" ? "error" : "enum"] = hex
        return parameters
    }
}
