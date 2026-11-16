import AppKit
import UniformTypeIdentifiers

/// The downloads popover, laid out like Safari's: a centred title with Clear on the
/// right, then one short row per file with its icon, name over size, and a button that
/// is Pause, Resume or Show in Finder.
///
/// Plain views rather than `NSTableView`: the list is tiny and fixed-shape, so there is
/// no data source, no cell reuse and no column machinery to pay for. Nothing exists
/// until the popover is first opened, and closing it releases this whole tree.
final class DownloadsPopoverController: NSViewController {

    private enum Metrics {
        static let width: CGFloat = 520
        static let header: CGFloat = 44
        static let row: CGFloat = 52
        /// Nine rows fill the popover; anything beyond that scrolls.
        static let visibleRows = 9
    }

    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let clearButton = NSButton()
    private let divider = HairlineView()
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    private var rows: [DownloadRowView] = []
    private var shownIDs: [UUID] = []
    /// Which row is picked out, the way a list marks one item. nil until a click.
    private var selectedID: UUID?
    /// nil until the first style pass, so the button is titled even when nothing has
    /// finished yet.
    private var clearEnabled: Bool?
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Metrics.width,
                                             height: Metrics.header + Metrics.row))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        root.addSubview(titleLabel)

        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        root.addSubview(clearButton)

        root.addSubview(divider)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView
        root.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        root.addSubview(emptyLabel)

        view = root

        // The list is the only thing that ever changes: every row already refreshes
        // itself from its item, so one notification is enough for the whole popover.
        observer = NotificationCenter.default.addObserver(
            forName: .downloadsDidChange, object: Downloads.shared, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContents()
    }

    // MARK: - Content

    /// Shown below the header, capped so a long list scrolls instead of growing the
    /// popover off the screen.
    private var listHeight: CGFloat {
        rows.isEmpty ? Metrics.row
                     : CGFloat(min(rows.count, Metrics.visibleRows)) * Metrics.row
    }

    private func reload() {
        let items = Downloads.shared.items
        let ids = items.map(\.id)
        if let id = selectedID, !ids.contains(id) { selectedID = nil }

        var rebuilt = false
        if ids != shownIDs {
            shownIDs = ids
            rebuildRows(items)
            rebuilt = true
        } else {
            rows.forEach { $0.refresh() }
        }
        styleClearButton()
        emptyLabel.isHidden = !items.isEmpty

        // A progress tick changes only the labels each row already owns; the frames and
        // the popover's height are touched only when the list itself changes.
        let height = Metrics.header + listHeight
        if rebuilt || abs(preferredContentSize.height - height) > 0.5 {
            preferredContentSize = NSSize(width: Metrics.width, height: height)
            layoutContents()
        }
    }

    /// Rows are only rebuilt when the set of downloads changes; a progress tick just
    /// refreshes what is already on screen.
    private func rebuildRows(_ items: [DownloadItem]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = DownloadRowView(item: item)
            row.isSelected = item.id == selectedID
            row.onAction = { [weak self] in self?.performAction(for: item) }
            row.onSelect = { [weak self] in self?.select(item) }
            listView.addSubview(row)
            return row
        }
    }

    private func select(_ item: DownloadItem) {
        guard selectedID != item.id else { return }
        selectedID = item.id
        for row in rows { row.isSelected = row.itemID == item.id }
    }

    private func styleClearButton() {
        let enabled = Downloads.shared.hasFinished
        guard enabled != clearEnabled else { return }
        clearEnabled = enabled
        clearButton.isEnabled = enabled
        clearButton.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ])
    }

    private func performAction(for item: DownloadItem) {
        switch item.state {
        case .downloading, .paused:
            Downloads.shared.togglePause(item)
        case .finished, .failed:
            Downloads.shared.reveal(item)
        }
    }

    @objc private func clearFinished() {
        // Running transfers stay put; only what has ended leaves the list.
        Downloads.shared.clearFinished()
    }

    // MARK: - Layout

    /// Everything is positioned by hand, so the popover needs no Auto Layout pass and
    /// no constraint bookkeeping for a layout that never reflows.
    private func layoutContents() {
        let w = max(Metrics.width, view.bounds.width)
        let clearSize = clearButton.attributedTitle.size()

        // Centred across the whole bar, with Clear sitting over the right end, the way
        // Safari's header reads.
        titleLabel.frame = NSRect(x: 0, y: 14, width: w, height: 16)
        clearButton.frame = NSRect(x: w - clearSize.width - 18, y: 13,
                                   width: clearSize.width + 2, height: 18)
        divider.frame = NSRect(x: 0, y: Metrics.header - 1, width: w, height: 1)

        let listH = listHeight
        scrollView.frame = NSRect(x: 0, y: Metrics.header, width: w, height: listH)
        listView.frame = NSRect(x: 0, y: 0, width: w, height: max(listH, CGFloat(rows.count) * Metrics.row))
        emptyLabel.frame = NSRect(x: 0, y: Metrics.header, width: w, height: listH)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * Metrics.row, width: w, height: Metrics.row)
        }
    }
}

/// One download: its icon, name over size, and a single button that means Pause,
/// Resume or Show in Finder. Hovering tints the row; clicking picks it out, the way a
/// list does. The progress bar is drawn rather than built from views.
final class DownloadRowView: NSView {

    private enum Layout {
        static let icon = NSRect(x: 26, y: 9, width: 30, height: 34)
        static let textX: CGFloat = 74
        static let textRight: CGFloat = 78
        static let actionWidth: CGFloat = 26
        static let actionInset: CGFloat = 60
        static let highlightInset: CGFloat = 8
    }

    private let item: DownloadItem
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private var isHovered = false { didSet { needsDisplay = true } }
    var onAction: (() -> Void)?
    var onSelect: (() -> Void)?
    /// The button glyph and icon follow the row's state, not its progress ticks:
    /// both are rebuilt only when the state or the file type actually changes.
    private var lastActionState: DownloadItem.State?
    private var lastIconKey: String?

    var itemID: UUID { item.id }

    /// Picked out: accent fill, white text, exactly like a selected list row.
    var isSelected = false {
        didSet { if isSelected != oldValue { refresh() } }
    }

    init(item: DownloadItem) {
        self.item = item
        super.init(frame: .zero)
        // Its own layer: a bar drawn while the transfer ran cannot survive into the
        // finished state, because the layer is redrawn from scratch.
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.usesSingleLineMode = true
        addSubview(nameLabel)

        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.cell?.usesSingleLineMode = true
        addSubview(sizeLabel)

        actionButton.isBordered = false
        actionButton.imageScaling = .scaleProportionallyDown
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.target = self
        actionButton.action = #selector(act)
        addSubview(actionButton)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    // Hover is tracked so the row tints the way Safari's do. It costs one tracking
    // area per visible row and nothing while the popover is closed.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    func refresh() {
        if nameLabel.stringValue != item.name { nameLabel.stringValue = item.name }
        let detail = item.detail
        if sizeLabel.stringValue != detail { sizeLabel.stringValue = detail }
        let nameColor: NSColor = isSelected ? .white : .labelColor
        if nameLabel.textColor != nameColor { nameLabel.textColor = nameColor }
        let sizeColor: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        if sizeLabel.textColor != sizeColor { sizeLabel.textColor = sizeColor }

        if lastActionState != item.state {
            lastActionState = item.state
            switch item.state {
            case .downloading:
                actionButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
                actionButton.toolTip = "Pause"
            case .paused:
                actionButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")
                actionButton.toolTip = "Resume"
            case .finished, .failed:
                actionButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder")
                actionButton.toolTip = "Show in Finder"
            }
        }
        let buttonColor: NSColor = isSelected ? .white : .secondaryLabelColor
        if actionButton.contentTintColor != buttonColor { actionButton.contentTintColor = buttonColor }
        // By content type, never by opening the file: reading the Downloads folder is
        // exactly what makes macOS ask for permission.
        let iconKey = item.destination.pathExtension.lowercased()
        if lastIconKey != iconKey {
            lastIconKey = iconKey
            iconView.image = DownloadRowView.icon(for: item)
        }
        needsDisplay = true
    }

    @objc private func act() { onAction?() }

    private func layoutContents() {
        let w = bounds.width
        iconView.frame = Layout.icon
        let textWidth = max(0, w - Layout.textX - Layout.textRight)
        nameLabel.frame = NSRect(x: Layout.textX, y: 8, width: textWidth, height: 17)
        sizeLabel.frame = NSRect(x: Layout.textX, y: 26, width: textWidth, height: 14)
        actionButton.frame = NSRect(x: w - Layout.actionInset, y: 13,
                                    width: Layout.actionWidth, height: Layout.actionWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = bounds.insetBy(dx: Layout.highlightInset, dy: 3)
        if isSelected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        }

        guard item.state == .downloading || item.state == .paused else { return }
        let track = NSRect(x: Layout.textX, y: bounds.height - 6,
                           width: max(0, bounds.width - Layout.textX - Layout.textRight), height: 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

        let done = NSRect(x: track.minX, y: track.minY,
                          width: track.width * CGFloat(item.fraction), height: track.height)
        guard done.width > 0.5 else { return }
        (item.state == .paused ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: done, xRadius: 1, yRadius: 1).fill()
    }

    private static func icon(for item: DownloadItem) -> NSImage {
        let ext = item.destination.pathExtension.lowercased()
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}
