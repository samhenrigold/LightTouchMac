// Device ▸ Accessibility: the guest's own VoiceOver, Zoom, White on Black (Invert Colors from 6.0), Mono Audio and
// Speak Auto-text, switched the way iTunes' Configure Universal Access did and read back from the guest.
//
// From iPhone OS 3.0 every board with the `accessibility` capability (the S5L8920 and A4 ones: iPhone 3GS, iPod touch
// 3rd and 4th generation, iPad, iPhone 4; never the S5L8900/S5L8720 ones, on any version) has these five, through
// 7.1.2. A switch is a boolean in lockdown's com.apple.Accessibility domain (the "ByiTunes" keys) and the
// com.apple.accessibility.status.itunes notification (LightTouchServices lockdown-ax); SpringBoard answers it
// (AccessibilitySettingsLoader to 5.1.1, SBAXServer on 6.x, the shared cache on 7.x) with the libAccessibility setter
// Settings itself calls, live. That setter keeps the feature's own key in mobile's com.apple.Accessibility
// preferences, which is what the menu's check marks read. Settings ▸ General ▸ Accessibility writes the same lockdown keys, so the two never disagree.

import Foundation
import HostRuntime
import HostServiceWire

public nonisolated enum AccessibilityFeature: Int, CaseIterable, Sendable {
    case voiceOver, zoom, invertColors, monoAudio, speakAutoText

    /// Settings' own name for it on `version`.
    public func title(version: String) -> String {
        switch self {
        case .voiceOver: "VoiceOver"
        case .zoom: "Zoom"
        case .invertColors:
            version.compare("6.0", options: .numeric) == .orderedAscending ? "White on Black" : "Invert Colors"
        case .monoAudio: "Mono Audio"
        case .speakAutoText: "Speak Auto-text"
        }
    }

    /// The key iTunes set in lockdown's com.apple.Accessibility domain.
    var iTunesKey: String {
        switch self {
        case .voiceOver: "VoiceOverTouchEnabledByiTunes"
        case .zoom: "ZoomTouchEnabledByiTunes"
        case .invertColors: "InvertDisplayEnabledByiTunes"
        case .monoAudio: "MonoAudioEnabledByiTunes"
        case .speakAutoText: "SpeakAutoCorrectionsEnabledByiTunes"
        }
    }

    /// The key libAccessibility's setter writes in mobile's com.apple.Accessibility preferences.
    var preferenceKey: String {
        switch self {
        case .voiceOver: "VoiceOverTouchEnabled"
        case .zoom: "ZoomTouchEnabled"
        case .invertColors: "InvertColorsEnabled"
        case .monoAudio: "MonoAudioEnabled"
        case .speakAutoText: "SpeakCorrectionsEnabled"
        }
    }

    /// Why a device can't have it, or nil where it can.
    public static func unavailableReason(board: Board, version: String) -> String? {
        guard board.soc == .s5l8920 || board.soc == .s5l8930 else {
            return "The \(board.preferredName) has no accessibility features."
        }
        if version.compare("3.0", options: .numeric) == .orderedAscending {
            return "Accessibility features arrived with iPhone OS 3.0."
        }
        return nil
    }
}

extension GuestServices {
    /// The features that are on: mobile's com.apple.Accessibility preferences, as libAccessibility keeps them.
    public func accessibility() async throws -> Set<AccessibilityFeature> {
        guard let data = try await agent.get("\(Self.preferences)/com.apple.Accessibility.plist", limit: 1 << 20),
            !data.isEmpty
        else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw DeviceToolsError.failed("The device’s accessibility preferences aren’t readable.") }
        return Set(AccessibilityFeature.allCases.filter { plist[$0.preferenceKey] as? Bool == true })
    }
}

extension DeviceServices {
    /// Turns `feature` on or off as iTunes did (the lockdown-ax child, like lockdown-tz). `tool`: LightTouchServices,
    /// the bundle's by default.
    public func setAccessibility(
        _ feature: AccessibilityFeature,
        on: Bool,
        tool: String? = servicesHelper
    ) async throws {
        guard let tool else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        let result = try await Self.lockdownChild(
            tool,
            ["lockdown-ax", "\(feature.iTunesKey)=\(on ? 1 : 0)"],
            socket: clientSocket
        )
        guard result.status == 0 else {
            throw DeviceToolsError.failed("The device didn’t take the accessibility change: \(result.error)")
        }
    }

    /// What is on: `guest`'s preferences, except White on Black before 3.2, whose handler inverts the display through
    /// SpringBoard and leaves the preference alone: there its lockdown key says (lockdown-ax --get).
    public func accessibility(
        guest: GuestServices,
        version: String,
        tool: String? = servicesHelper
    ) async throws -> Set<AccessibilityFeature> {
        var on = try await guest.accessibility()
        guard version.compare("3.2", options: .numeric) == .orderedAscending else { return on }
        guard let tool else { throw DeviceToolsError.toolMissing("LightTouchServices") }
        let key = AccessibilityFeature.invertColors.iTunesKey
        let result = try await Self.lockdownChild(tool, ["lockdown-ax", "--get", key], socket: clientSocket)
        guard result.status == 0 else { throw DeviceToolsError.failed("Lockdown didn’t answer: \(result.error)") }
        on.remove(.invertColors)
        if result.output.hasPrefix("1") { on.insert(.invertColors) }
        return on
    }
}
