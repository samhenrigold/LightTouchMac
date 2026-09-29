import AppKit

final class InlineActionButton: NSButton {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func pressed() { perform() }
}
