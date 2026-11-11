import Foundation

// What the guest agent says of the guest (qemu-ios contrib/it-agent/README.md, "State report"): `key value` lines it
// sends with each of its polls, four times a second, so the app is told of a change instead of asking for it. An
// agent before v6 sends none, and the app asks it as before (GuestAgent's ops).
//
// The guest wrote the text: every value is checked, and a key this doesn't know is skipped.

/// One report, read. A field is nil where the report doesn't say.
public nonisolated struct GuestReport: Sendable, Equatable {
    /// The agent's protocol; 6 is the first that reports.
    public var agent = 0
    /// The SpringBoard that answered the agent, by its process ID (a respring's is another; 1 when the agent
    /// couldn't tell which); 0 when none is up, nil before the agent first asked.
    public var springBoard: Int?
    /// SpringBoard has held the agent's last question for two seconds or more (it is starting, restarting or
    /// hung): the fields below are what it last answered.
    public var isStalled = false
    public var isLocked: Bool?
    public var hasPasscode: Bool?
    /// The frontmost app's bundle identifier; nil on the Home or lock screen.
    public var frontmost: String?
    /// Its localized name.
    public var name: String?
    /// The interface's orientation as SpringBoard tells it, in whichever form the firmware's SpringBoardServices
    /// has: its content degrees (0, 90, 180, -90; iPhone OS 3.1.3's SBGetUIOrientation, the agent's `orientation`
    /// op), or a UIInterfaceOrientation (1...4; SBGetInterfaceOrientation from 3.2, what lockdown's
    /// springboardservices relay answers).
    public var uiDegrees: Int?
    public var interfaceOrientation: Int?

    /// nil for a text that isn't a report: the empty one a session's end leaves, or one without the agent's line.
    public init?(_ text: String) {
        var agent: Int?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "agent": agent = Int(value)
            case "springboard": springBoard = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            case "stalled": isStalled = value == "1"
            case "locked": isLocked = Self.flag(value)
            case "passcode": hasPasscode = Self.flag(value)
            case "front": frontmost = value.isEmpty ? nil : String(value.prefix(255))
            case "name": name = value.isEmpty ? nil : String(value.prefix(255))
            case "uidegrees": uiDegrees = Int(value).flatMap { [0, 90, 180, -90].contains($0) ? $0 : nil }
            case "interface": interfaceOrientation = Int(value).flatMap { (1...4).contains($0) ? $0 : nil }
            default: break
            }
        }
        guard let agent, agent >= 6 else { return nil }
        self.agent = agent
    }

    private static func flag(_ value: String) -> Bool? { value == "1" ? true : value == "0" ? false : nil }

    /// A SpringBoard is up and answered the agent's last question: the other fields are the guest's state now.
    public var isAnswering: Bool { (springBoard ?? 0) > 0 && !isStalled }

    /// What the agent's `frontmost` op answers, from the report: the lock screen and the Home screen are
    /// SpringBoard's, under the names the op gives them. nil unless SpringBoard is answering.
    public var foreground: (bundleID: String, name: String)? {
        guard isAnswering, let isLocked else { return nil }
        if isLocked { return ("com.apple.springboard", "Lock Screen") }
        guard let frontmost else { return ("com.apple.springboard", "Home Screen") }
        return (frontmost, name ?? frontmost)
    }
}
