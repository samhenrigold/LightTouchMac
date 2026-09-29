import AudioToolbox

/// The same system effects used by WireView for explicit capture actions.
enum CaptureSound: SystemSoundID {
    case screenshot = 1393
    case recordingStarted = 1113
    case recordingStopped = 1114

    func play() {
        guard CapturePreferences.shared.soundEffectsEnabled else { return }
        AudioServicesPlaySystemSound(rawValue)
    }
}
