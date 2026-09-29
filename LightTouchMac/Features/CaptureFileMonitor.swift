import Foundation

/// Watches the captured file itself so a Finder move to Trash dismisses its banner.
@MainActor
final class CaptureFileMonitor {
    private var source: (any DispatchSourceFileSystemObject)?

    init?(url: URL, onRemoval: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke], queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.source != nil else { return }
                // Renaming or moving the file also invalidates the banner's URL.
                guard !FileManager.default.fileExists(atPath: url.path) else { return }
                self.cancel()
                onRemoval()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
    deinit { source?.cancel() }
}
