// Device ▸ Play on Phone…: a phone's browser shows the device's screen, takes its touches and Home button, and tilts
// it with the phone's own gravity. One HTTPS port on the Mac's .local name serves the page (phone-remote.html) and its
// WebSocket under a self-signed certificate the phone accepts once (browsers give motion only to secure pages). Under
// Network.framework's WebSocket, a framer answers each connection's request (LightTouchCore's PhoneRemoteRequest, which
// checks the token the QR code carries) and then steps aside. The math is LightTouchCore's PhoneRemote.

import Cocoa
import CoreImage
import DeviceRuntime
import LightTouchCore
import Network
import SystemConfiguration
import os

@MainActor final class PhoneRemoteController {
    /// The device window; the QR code and errors go on it as sheets.
    weak var window: NSWindow?
    var isRunning: Bool { listener != nil || starting }

    private static let port: NWEndpoint.Port = 9741
    /// More than a phone and its page loads ever need at once.
    private static let maxConnections = 8
    private weak var device: DeviceSession?
    private var starting = false
    private var listener: NWListener?
    private var connections = 0
    private var client: NWConnection?
    private var timer: Timer?
    /// The frame and turn last sent, so a still screen sends nothing.
    private var sent: (serial: UInt64, turns: Int)?
    private var sending = false
    private var turns = 0
    /// Where the fingers down are (0, and 1 for the emulator's second finger), to lift them if the phone goes away.
    private var fingers: [Int: CGPoint] = [:]

    private var screen: DisplayView? { device?.workspace.deviceVC.screen }

    /// Play on Phone… starts serving `session`, the selected device, until it stops, and shows the QR code; Stop
    /// Playing on Phone stops.
    func toggle(_ session: DeviceSession?) {
        guard !isRunning else { return stop() }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let (url, fingerprint) = try await start(session)
                if let window {
                    makeAlert(url: url, fingerprint: fingerprint).beginSheetModal(for: window, completionHandler: nil)
                }
            } catch {
                show(error)
            }
        }
    }

    /// The QR code's address (this session's token in its fragment) and the certificate's fingerprint.
    private func start(_ session: DeviceSession?) async throws -> (URL, String) {
        Analytics.signal("Remote.started")
        // Each session has its own token; builds before kept one across launches.
        UserDefaults.standard.removeObject(forKey: PhoneRemoteRequest.storedTokenKey)
        let token = PhoneRemoteRequest.newToken()
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?,
            let url = URL(string: "https://\(name).local:\(Self.port)/#\(token)")
        else { throw PhoneRemoteError.noNetwork }
        let (tls, fingerprint) = try await Self.tlsOptions(host: "\(name).local")
        let parameters = NWParameters(tls: tls)
        // The WebSocket above the framer, its handshake skipped: the framer answers the request.
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.skipHandshake = true
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: PhoneRemoteFramer.definition),
            at: 0
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // Wi-Fi and Ethernet, where the phone is (and loopback, which only this Mac reaches): not VPNs or virtual
        // machines' bridges.
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        let listener = try NWListener(using: parameters, on: Self.port)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        // The port can turn out to be taken only once listening starts; the error follows the QR code.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed(let error) = state else { return }
            MainActor.assumeIsolated {
                Analytics.failure("Remote.failed", error)
                stop()
                show(error)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        device = session
        PhoneRemoteFramer.token.withLock { $0 = token }
        // In the common modes, so an open menu or a live resize doesn't freeze the phone's picture.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return (url, fingerprint)
    }

    func stop() {
        PhoneRemoteFramer.token.withLock { $0 = "" }
        disconnect()
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        listener = nil
    }

    private func show(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard connections < Self.maxConnections else { return connection.cancel() }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { connection.cancel() }
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated { self?.connections -= 1 }
        }
        connection.start(queue: .main)
        receive(connection)
        // A request and its page take well under this; whatever hasn't become the phone by then is closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            MainActor.assumeIsolated {
                if let connection, connection !== self?.client { connection.cancel() }
            }
        }
    }

    /// The phone's WebSocket messages: only a socket's arrive, the framer below answered everything else.
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return connection.cancel() }
            MainActor.assumeIsolated {
                guard error == nil,
                    let socket = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata, socket.opcode != .close
                else { return connection === client ? disconnect() : connection.cancel() }
                // Pings are answered by the protocol (autoReplyPing) but still arrive here.
                if socket.opcode == .text, let content {
                    // The page's first message (it's ready for a frame) makes it the phone; the newest wins.
                    if connection !== client {
                        disconnect()
                        client = connection
                        device?.workspace.deviceVC.phoneShowsScreen = true
                    }
                    handle(content)
                }
                receive(connection)
            }
        }
    }

    // MARK: - The phone

    /// `{"gravity":[x,y,z]}` (accelerationIncludingGravity, pointing down), `{"touch":[phase,x,y,finger]}`
    /// (TouchPhase; normalized on the picture, y down; finger 0 or 1), `{"home":true}` or `{"drawn":true}` (the last frame is on the screen).
    private struct Message: Decodable {
        var gravity: [Double]?
        var touch: [Double]?
        var home: Bool?
        var drawn: Bool?
    }

    private func handle(_ payload: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: payload), let emulator = device?.emulator
        else { return }
        if message.drawn == true { sending = false }
        if let g = message.gravity, g.count == 3, g.allSatisfy(\.isFinite), emulator.acceptsInput, !emulator.isSleeping
        {
            emulator.link?.send(PhoneRemote.attitude(x: g[0], y: g[1], z: g[2]))
        }
        if let touch = message.touch, touch.count == 4, [0, 1, 2].contains(touch[0]), [0, 1].contains(touch[3]),
            touch.allSatisfy(\.isFinite)
        {
            let p = PhoneRemote.surfacePoint(
                CGPoint(x: min(max(touch[1], 0), 1), y: min(max(touch[2], 0), 1)),
                turns: turns
            )
            send(finger: Int(touch[3]), Int32(touch[0]), at: p)
        }
        if message.home == true { emulator.pressHome() }
    }

    /// The first finger is the emulator's touch, the second qemu_ios_ui_touch2's, as the Mac's pinch sends them.
    private func send(finger: Int, _ phase: Int32, at p: CGPoint) {
        fingers[finger] = phase == TouchPhase.end ? nil : p
        if finger == 0 {
            screen?.sendVisualTouch(0, phase, p.x, p.y)
        } else {
            screen?.sendVisualTouch2(phase, p.x, p.y)
        }
    }

    /// Stops with the device; otherwise sends the phone the newest frame, turned the way the device is held, when it
    /// changed and the phone has drawn the last one.
    private func tick() {
        guard let emulator = device?.emulator, !emulator.isDead, emulator.state != .poweredOff else { return stop() }
        guard let client, !sending, let screen, let surface = screen.currentFrame() else { return }
        turns = PhoneRemote.quarterTurns(guestTurn: screen.guestTurn)
        guard sent?.serial != screen.shownSerial || sent?.turns != turns,
            let image = DisplayView.image(surface, colorSpace: screen.colorSpace)
        else { return }
        sent = (screen.shownSerial, turns)
        sending = true
        let turns = turns
        // Turning and encoding off the main thread; only the copy out of the surface stays on it.
        Self.encoder.async { [weak self] in
            guard let turned = PanelCapture.rotated(image, clockwiseQuarterTurns: turns),
                let jpeg = NSBitmapImageRep(cgImage: turned)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else {
                // Nothing went out to be drawn.
                Task { @MainActor in self?.sending = false }
                return
            }
            let frame = NWConnection.ContentContext(
                identifier: "frame",
                metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)]
            )
            // A dead connection shows in receive(), not here.
            client.send(content: jpeg, contentContext: frame, completion: .idempotent)
        }
    }

    private static let encoder = DispatchQueue(label: "PhoneRemote.encoder")

    /// Drops the phone; its fingers lift, the device's gravity goes back to rest and its helper may slow down again.
    private func disconnect() {
        guard let client else { return }
        // A touch that never ends leaves the guest believing a finger is down (DisplayView.emit).
        for (finger, p) in fingers { send(finger: finger, TouchPhase.end, at: p) }
        client.cancel()
        self.client = nil
        sent = nil
        sending = false
        device?.workspace.deviceVC.phoneShowsScreen = false
        screen?.resetMotion()
    }

    // MARK: - Setup

    /// The sheet: the QR code on a white tile (scannable in Dark Mode too) above the steps, centered in the alert.
    private func makeAlert(url: URL, fingerprint: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Play on Your Phone"
        alert.informativeText = "Use a phone on the same network as this Mac."

        let code = NSImageView()
        if let qrCode = CIFilter(
            name: "CIQRCodeGenerator",
            parameters: ["inputMessage": Data(url.absoluteString.utf8)]
        )?
        .outputImage {
            // Whole pixels per module keep its edges sharp.
            let scale = (156 / qrCode.extent.width).rounded(.down)
            let rep = NSCIImageRep(ciImage: qrCode.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
            code.image = NSImage(size: rep.size)
            code.image?.addRepresentation(rep)
        }
        let tile = NSBox()
        tile.boxType = .custom
        tile.fillColor = .white
        tile.borderWidth = 0
        tile.cornerRadius = 16
        tile.contentView = code

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        paragraph.headIndent = 16
        paragraph.paragraphSpacing = 4
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString(
            string: "1.\tScan the code with the phone’s camera.\n"
                + "2.\tIn the warning that the connection isn’t private, check that the certificate’s SHA-256 "
                + "fingerprint is\n",
            attributes: [.font: small, .paragraphStyle: paragraph]
        )
        text.append(
            NSAttributedString(
                string: "\t\(fingerprint)\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .paragraphStyle: paragraph
                ]
            )
        )
        text.append(
            NSAttributedString(
                string: "\tthen continue past it.\n3.\tTap Start.",
                attributes: [.font: small, .paragraphStyle: paragraph]
            )
        )
        let steps = NSTextField(labelWithAttributedString: text)
        steps.maximumNumberOfLines = 0
        steps.isSelectable = true

        // As wide as the alert, so what it centers is centered in the alert.
        let stack = NSStackView(views: [tile, steps])
        stack.orientation = .vertical
        stack.spacing = 16
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 380),
            tile.widthAnchor.constraint(equalToConstant: 180),
            tile.heightAnchor.constraint(equalToConstant: 180),
            steps.widthAnchor.constraint(equalToConstant: 260)
        ])
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        return alert
    }

    nonisolated private static let passphrase = "light-touch"

    /// TLS with this Mac's self-signed identity for `host`, made with the system's openssl (off the main thread) the
    /// first time and again before it runs out: Apple's rules for server certificates (at most 825 days, serverAuth)
    /// are why it says what it says. With the certificate's fingerprint (PhoneRemoteRequest.fingerprint).
    private static func tlsOptions(host: String) async throws -> (NWProtocolTLS.Options, String) {
        let folder = Bundled.stateDirectory.appendingPathComponent("phone-remote", isDirectory: true)
        let p12 = folder.appendingPathComponent("identity.p12")
        let created = try? p12.resourceValues(forKeys: [.creationDateKey]).creationDate
        if created.map({ -$0.timeIntervalSinceNow > 800 * 86400 }) ?? true {
            try await Task.detached { try makeIdentity(p12, host: host) }.value
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        // Before macOS 15 SecPKCS12Import can only add the identity to the login keychain.
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        // Swift can't cast to a CF type conditionally: its type ID says it is a SecIdentity.
        guard SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items) == errSecSuccess,
            let found = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String] as CFTypeRef?,
            CFGetTypeID(found) == SecIdentityGetTypeID(),
            let identity = sec_identity_create(unsafeDowncast(found, to: SecIdentity.self))
        else { throw PhoneRemoteError.noCertificate }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(unsafeDowncast(found, to: SecIdentity.self), &certificate) == errSecSuccess,
            let certificate
        else {
            throw PhoneRemoteError.noCertificate
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return (tls, PhoneRemoteRequest.fingerprint(certificate: SecCertificateCopyData(certificate) as Data))
    }

    /// RSA, not EC: macOS 27's SecPKCS12Import raises an exception (a NULL key in SecIdentityCreate) on LibreSSL's EC
    /// key bags.
    nonisolated private static func makeIdentity(_ p12: URL, host: String) throws {
        let folder = p12.deletingLastPathComponent()
        try StorageLocations.privateDirectory(folder)
        let key = folder.appendingPathComponent("key.pem").path
        let certificate = folder.appendingPathComponent("certificate.pem").path
        defer { for path in [key, certificate] { try? FileManager.default.removeItem(atPath: path) } }
        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "825", "-subj", "/CN=\(host)",
            "-addext", "subjectAltName=DNS:\(host)", "-addext", "extendedKeyUsage=serverAuth",
            "-keyout", key, "-out", certificate
        ])
        try? FileManager.default.removeItem(at: p12)
        try openssl([
            "pkcs12", "-export", "-inkey", key, "-in", certificate, "-passout", "pass:\(passphrase)", "-out", p12.path
        ])
    }

    nonisolated private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PhoneRemoteError.noCertificate }
    }
}

/// Under the WebSocket on each connection: writes PhoneRemoteRequest's answer to the request (the page, or the socket's
/// 101), then passes everything through to the WebSocket, whose handshake is skipped. Prepending the
/// WebSocket once the request is read would be tidier, but prependApplicationProtocol refuses it (EINVAL, macOS 27).
nonisolated final class PhoneRemoteFramer: NWProtocolFramerImplementation {
    static let label = "PhoneRemote"
    // nonisolated(unsafe): made once, then only read; Network.framework holds definitions across its own queues.
    nonisolated(unsafe) static let definition = NWProtocolFramer.Definition(implementation: PhoneRemoteFramer.self)
    /// The running session's token (PhoneRemoteController.start); empty, which opens nothing, while stopped.
    static let token = OSAllocatedUnfairLock(initialState: "")
    static let page =
        Bundle.main.url(forResource: "phone-remote", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
        ?? Data()

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var request = PhoneRemoteRequest.incomplete
        var available = 0
        // A peek: nothing is consumed until the request is known.
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: PhoneRemoteRequest.maxLength) { buffer, _ in
            if let buffer {
                available = buffer.count
                request = PhoneRemoteRequest(Data(buffer), token: Self.token.withLock { $0 }, page: Self.page)
            }
            return 0
        }
        switch request {
        case .incomplete:
            return available + 1
        case .refused:
            framer.markFailed(error: .posix(.EBADMSG))
        case .page(let response):
            framer.writeOutput(data: response)
            // Closes the connection once the page is out.
            framer.markFailed(error: nil)
        case .socket(let length, let response):
            _ = framer.parseInput(minimumIncompleteLength: length, maximumLength: length) { _, _ in length }
            framer.writeOutput(data: response)
            framer.passThroughInput()
            framer.passThroughOutput()
        }
        return 0
    }

    /// Before the 101 the WebSocket above has nothing to send; after it, output passes through without this.
    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
}

nonisolated enum PhoneRemoteError: LocalizedError {
    case noNetwork, noCertificate
    var errorDescription: String? {
        switch self {
        case .noNetwork: "Light Touch couldn’t find this Mac’s name on the local network."
        case .noCertificate: "Light Touch couldn’t make the certificate the phone connects with."
        }
    }
}
