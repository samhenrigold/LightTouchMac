import Foundation

/// Owns work which must never outlive one boot. The halt transaction itself
/// belongs to the controller, so retiring a boot cannot cancel its cleanup.
@MainActor
final class BootSessionScope {
    enum Work: CaseIterable {
        case foreground, readiness, recovery, watchdog, timeZone, orientation
        case guestPackage, activation, staging, powerOn, reset, usbReconnect
    }
    private(set) var id = UUID()
    private(set) var generation = 0
    private(set) var retired = false
    private var tasks: [Work: Task<Void, Never>] = [:]
    private var observer: NSObjectProtocol?

    subscript(work: Work) -> Task<Void, Never>? {
        get { tasks[work] }
        set {
            tasks[work]?.cancel()
            guard !retired else { newValue?.cancel(); return }
            tasks[work] = newValue
        }
    }
    var timeZoneObserver: NSObjectProtocol? {
        get { observer }
        set {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard !retired else {
                if let newValue { NotificationCenter.default.removeObserver(newValue) }
                observer = nil
                return
            }
            observer = newValue
        }
    }
    func retire() {
        guard !retired else { return }
        retired = true
        generation += 1 // invalidate suspended completions before another boot
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        timeZoneObserver = nil
    }
    func renew() {
        retire()
        id = UUID()
        retired = false
    }
}
