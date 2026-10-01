import Cocoa

/// Light Touch Help: Help.txt's task topics (a "# " line starts one) in a
/// sidebar, the chosen topic beside it. "[Device]" reads as the selected
/// device's name.
final class HelpWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    struct Topic: Equatable { let title: String; let body: String }

    static func topics(_ text: String) -> [Topic] {
        text.components(separatedBy: "\n# ").compactMap { chunk in
            let lines = chunk.drop { $0 == "#" || $0 == " " }.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let title = lines.first, !title.isEmpty else { return nil }
            return Topic(title: String(title), body: lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
    }

    private let source: [Topic]
    private var topics: [Topic] = []
    private let list = NSTableView()
    let text = NSTextView()

    init(text helpText: String) {
        source = Self.topics(helpText)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Light Touch Help"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 300)
        WindowRestorationPolicy.configure(window)
        super.init(window: window)

        list.addTableColumn(NSTableColumn(identifier: .init("topic")))
        list.headerView = nil
        list.style = .sourceList
        list.dataSource = self
        list.delegate = self
        list.setAccessibilityLabel("Help topics")
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.usesFindBar = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 24, height: 20)
        text.setAccessibilityLabel("Light Touch Help")
        let textScroll = NSScrollView()
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true

        let split = NSSplitViewController()
        let sidebar = NSViewController(); sidebar.view = listScroll
        let detail = NSViewController(); detail.view = textScroll
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 300
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        show(deviceName: "iPod")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Re-reads "[Device]" as `deviceName`, keeping the chosen topic.
    func show(deviceName: String) {
        topics = source.map { Topic(title: $0.title.replacingOccurrences(of: "[Device]", with: deviceName),
                                    body: $0.body.replacingOccurrences(of: "[Device]", with: deviceName)) }
        let row = max(list.selectedRow, 0)
        list.reloadData()
        select(topic: min(row, topics.count - 1))
    }

    func select(topic row: Int) {
        guard topics.indices.contains(row) else { return }
        list.selectRowIndexes([row], byExtendingSelection: false)
        showSelection()
    }

    private func showSelection() {
        guard topics.indices.contains(list.selectedRow) else { return }
        let topic = topics[list.selectedRow]
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        let body = NSMutableAttributedString(string: topic.title + "\n", attributes: [.font: NSFont.preferredFont(forTextStyle: .title2),
                                                                                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        body.append(NSAttributedString(string: topic.body.replacingOccurrences(of: "\n\n", with: "\n"), attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
                                                                        .paragraphStyle: paragraph]))
        text.textStorage?.setAttributedString(body)
        text.scrollToBeginningOfDocument(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { topics.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: topics[row].title)
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
}
