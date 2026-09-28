// IPSW downloads from Apple's CDN (docs/multi-device-plan.md, D).
//
// A background URLSession, so a download goes on while the app is quit: the
// next launch makes the session again under the same identifier and its
// delegate picks the task back up. Tasks are named by the IPSW's sha1. A
// cancel or a failure keeps the resume data in <sha1>.resume and the next
// start resumes from it. A finished file is size- and SHA1-checked before it
// becomes <sha1>.ipsw.

import Foundation

nonisolated final class FirmwareDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case progress(Double)
        /// Resumed from saved data at this offset.
        case resumed(offset: Int64)
        case finished(URL)
        case failed(FirmwareError)
        /// Cancelled; the resume data is saved.
        case cancelled
    }

    static let identifier = "\(StorageLocations.bundleIdentifier).ipsw"

    let store: IPSWStore
    private let expectedBytes: @Sendable (String) -> Int64?
    private let onEvent: @Sendable (String, Event) -> Void
    private let lock = NSLock()
    private var cancelling: Set<String> = []
    private var session: URLSession!

    /// `expectedBytes` gives the catalog's size for a sha1, also for a task
    /// a previous launch started. Events arrive on a private serial queue.
    init(store: IPSWStore, configuration: URLSessionConfiguration = .background(withIdentifier: identifier),
         expectedBytes: @escaping @Sendable (String) -> Int64?, onEvent: @escaping @Sendable (String, Event) -> Void) {
        self.store = store
        self.expectedBytes = expectedBytes
        self.onEvent = onEvent
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// The sha1s of downloads in flight, including ones a previous launch started.
    func active(_ completion: @escaping @Sendable ([String]) -> Void) {
        session.getAllTasks { tasks in
            completion(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
        }
    }

    /// Starts or resumes the download of `url`, which must hash to `sha1`.
    func start(sha1: String, url: URL) throws {
        try StorageLocations.privateDirectory(store.downloads)
        lock.withLock { _ = cancelling.remove(sha1) }
        let saved = store.resumeData(sha1)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: saved) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: saved)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = sha1
        task.resume()
    }

    /// Stops the download and keeps its resume data; `.cancelled` follows.
    func cancel(sha1: String) {
        lock.withLock { _ = cancelling.insert(sha1) }
        session.getAllTasks { [self] tasks in
            let matching = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter { $0.taskDescription == sha1 }
            if matching.isEmpty { onEvent(sha1, .cancelled) }
            for task in matching {
                task.cancel { [self] data in
                    if let data { saveResumeData(data, sha1: sha1) }
                    onEvent(sha1, .cancelled)
                }
            }
        }
    }

    /// Tests: stop the session without touching the tasks' saved state.
    func invalidate() { session.invalidateAndCancel() }

    private func saveResumeData(_ data: Data, sha1: String) {
        try? StorageLocations.privateDirectory(store.downloads)
        try? data.write(to: store.resumeData(sha1), options: .atomic)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        guard let sha1 = downloadTask.taskDescription else { return }
        onEvent(sha1, .resumed(offset: fileOffset))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let sha1 = downloadTask.taskDescription else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes(sha1) ?? 0
        if total > 0 { onEvent(sha1, .progress(min(1, Double(totalBytesWritten) / Double(total)))) }
    }

    /// The file at `location` is deleted when this returns, so it moves out
    /// first; checking it is quick enough for the delegate queue (about 1 s for 500 MB).
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let sha1 = downloadTask.taskDescription else { return }
        let partial = store.partial(sha1)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            guard (200..<300).contains(status) else { throw FirmwareError.failed("The download failed (HTTP \(status)).") }
            try StorageLocations.privateDirectory(store.downloads)
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            onEvent(sha1, .finished(try store.install(partial, sha1: sha1, bytes: expectedBytes(sha1))))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            onEvent(sha1, .failed(error as? FirmwareError ?? .failed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let sha1 = task.taskDescription else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { saveResumeData(data, sha1: sha1) }
        // A cancel reports through its own completion.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
           lock.withLock({ cancelling.contains(sha1) }) { return }
        onEvent(sha1, .failed(.failed("The download stopped: \(error.localizedDescription)")))
    }
}
