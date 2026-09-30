// The Apps pane's centred message (empty, loading, error) and its status caption.

import Cocoa

extension NSTextField {
    /// A message that wraps to the width it is given, however long: pinned to a pane's edges it never
    /// widens the pane (the inspector jumped between widths on an error) and never truncates mid-word.
    static func paneMessage() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// The one-line caption under the pane's mode control: it truncates in the middle rather than widen the pane.
    static func paneCaption() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
