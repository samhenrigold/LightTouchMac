import Cocoa
import SwiftUI

/// Transient feedback shares Device Hub's thumbnail/title/subtitle/accessory banner layout.
final class CaptureStatusView: NSView {
    enum Appearance { case neutral, recording, success, warning }
    private let state = CaptureBannerState()
    private var hosting: NSHostingView<CaptureBanner>!
    private var dismissal: Task<Void, Never>?
    private var dismissalAnimation: Task<Void, Never>?
    private var fileMonitor: CaptureFileMonitor?
    private var presentationID = UUID()
    private var dismissesAutomatically = false
    /// How long a capture banner stays up unhovered (check-capture-status holds it up while it removes files).
    static var autoDismissal: Duration = .seconds(5)
    var fileURL: URL? { state.fileURL }
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 48) }
    var isWindowActive: Bool {
        get { state.isWindowActive }
        set { state.isWindowActive = newValue }
    }
    override var isHidden: Bool {
        didSet {
            if isHidden {
                dismissal?.cancel()
                dismissalAnimation?.cancel()
                fileMonitor?.cancel()
                fileMonitor = nil
                state.isPresented = false
            }
        }
    }

    init() {
        super.init(frame: .zero)
        hosting = NSHostingView(rootView: CaptureBanner(state: state,
            primary: { [weak self] in self?.onPrimary?() },
            secondary: { [weak self] in self?.onSecondary?() },
            dismiss: { [weak self] in self?.dismissBanner() },
            hovering: { [weak self] hovered in
                self?.dismissal?.cancel()
                if !hovered { self?.scheduleDismissal() }
            }))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(title: String, detail: String = "", busy: Bool = false, primary: String? = nil,
                secondary: String? = nil, dismissible: Bool = false, appearance: Appearance = .neutral) {
        dismissal?.cancel()
        dismissalAnimation?.cancel()
        fileMonitor?.cancel()
        fileMonitor = nil
        presentationID = UUID()
        dismissesAutomatically = false
        state.title = title
        state.detail = detail
        state.busy = busy
        state.primary = primary
        state.secondary = secondary
        state.dismissible = dismissible
        state.warning = appearance == .warning
        state.image = nil
        state.fileURL = nil
        isHidden = false
        alphaValue = 1
        state.isPresented = true
    }

    func showCapture(title: String, image: NSImage, fileURL: URL?) {
        update(title: title, dismissible: true, appearance: .success)
        state.image = image
        state.fileURL = fileURL
        let id = presentationID
        if let fileURL {
            fileMonitor = CaptureFileMonitor(url: fileURL) { [weak self] in
                guard let self, self.presentationID == id else { return }
                self.dismissBanner()
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) { dismissBanner(); return }
        }
        dismissesAutomatically = true
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        guard dismissesAutomatically, !isHidden else { return }
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: Self.autoDismissal) } catch { return }
            self?.dismissBanner()
        }
    }

    private func dismissBanner() {
        dismissal?.cancel()
        dismissesAutomatically = false
        fileMonitor?.cancel()
        fileMonitor = nil
        state.isPresented = false
        let id = presentationID
        dismissalAnimation?.cancel()
        dismissalAnimation = Task { [weak self] in
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let self, self.presentationID == id else { return }
            self.onDismiss?()
            self.isHidden = true
            self.onVisibilityChange?()
        }
    }
}

@Observable
private final class CaptureBannerState {
    var title = ""
    var detail = ""
    var busy = false
    var warning = false
    var primary: String?
    var secondary: String?
    var dismissible = false
    var image: NSImage?
    var fileURL: URL?
    var isWindowActive = true
    var isPresented = false
}

private struct CaptureBanner: View {
    let state: CaptureBannerState
    let primary: () -> Void
    let secondary: () -> Void
    let dismiss: () -> Void
    let hovering: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accessoryHeight: CGFloat = 24

    private var shape: AnyShape {
        state.image == nil ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 14))
    }

    var body: some View {
        ZStack {
            if state.isPresented {
                banner.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isPresented)
    }

    private var banner: some View {
        HStack(spacing: 6) {
            if let image = state.image {
                CaptureBannerThumbnail(image: image, fileURL: state.fileURL)
            } else if state.busy {
                ProgressView().controlSize(.small).frame(width: 28)
            } else if state.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title).fontWeight(.medium).lineLimit(1)
                if !state.detail.isEmpty {
                    Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(state.detail)
            if state.fileURL != nil {
                accessory("Open in Finder", symbol: "chevron.right", action: secondary)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoryHeight = $0 }
            } else if let title = state.primary {
                Button(title, action: primary).controlSize(.small)
            }
            if let title = state.secondary {
                Button(title, action: secondary).controlSize(.small)
            }
            if state.dismissible {
                accessory("Dismiss", symbol: "xmark", action: dismiss)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .padding(.trailing, max(8, (48 - accessoryHeight) / 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CaptureGlassSurface(shape: shape))
        .contentShape(shape)
        .onTapGesture { if state.fileURL != nil { secondary() } }
        .onHover(perform: hovering)
        .environment(\.controlActiveState, state.isWindowActive ? .key : .inactive)
        .accessibilityElement(children: .contain)
    }

    private func accessory(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote).bold()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .foregroundStyle(.gray)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct CaptureBannerThumbnail: View {
    let image: NSImage
    let fileURL: URL?
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(2)
            .onDrag {
                if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) { return provider }
                return NSItemProvider(object: image)
            } preview: {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 160)
            }
            .accessibilityLabel("Capture thumbnail")
            .help("Drag into another app or the Finder")
    }
}

#Preview("Saved Capture") {
    let state = CaptureBannerState()
    let _ = {
        state.title = "Screenshot saved"
        state.detail = "Open in Finder"
        state.image = NSImage(named: "gradient")
        state.fileURL = URL(filePath: "/tmp/Preview.png")
        state.dismissible = true
        state.isPresented = true
    }()
    CaptureBanner(state: state, primary: {}, secondary: {}, dismiss: {}, hovering: { _ in })
        .frame(width: 300, height: 48)
        .frame(width: 400, height: 160)
        .background { Image("gradient").resizable().scaledToFill() }
        .clipped()
}

/// DeviceKit uses regular, non-interactive SwiftUI glass; the button style handles interaction.
private struct CaptureGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

