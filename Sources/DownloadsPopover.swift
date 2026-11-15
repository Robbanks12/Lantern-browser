import AppKit
import UniformTypeIdentifiers

/// The downloads popover: a header, a short list, and one button per row.
///
/// Plain views rather than `NSTableView`: the list is tiny and fixed-shape, so there is
/// no data source, no cell reuse and no column machinery to pay for. Nothing exists
/// until the popover is first opened, and closing it releases this whole tree.
final class DownloadsPopoverController: NSViewController {

    private enum Metrics {
        static let width: CGFloat = 320
        static let header: CGFloat = 38
        static let row: CGFloat = 54
        /// Five rows is about a screenful of hands-on downloads; the rest scroll.
        static let visibleRows = 5
    }

    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let clearButton = NSButton()
    private let divider = HairlineView()
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    private var rows: [DownloadRowView] = []
    private var shownIDs: [UUID] = []
    /// nil until the first style pass, so the button is titled even when nothing has
    /// finished yet.
    private var clearEnabled: Bool?
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Metrics.width,
                                             height: Metrics.header + Metrics.row))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
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
            row.onAction = { [weak self] in self?.performAction(for: item) }
            listView.addSubview(row)
            return row
        }
    }

    private func styleClearButton() {
        let enabled = Downloads.shared.hasFinished
        guard enabled != clearEnabled else { return }
        clearEnabled = enabled
        clearButton.isEnabled = enabled
        clearButton.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: enabled ? NSColor.linkColor : NSColor.tertiaryLabelColor,
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
        titleLabel.frame = NSRect(x: 14, y: 11, width: w - 90, height: 16)
        clearButton.frame = NSRect(x: w - clearSize.width - 16, y: 10,
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
/// Resume or Show in Finder. The progress bar is drawn rather than built from views.
final class DownloadRowView: NSView {

    private let item: DownloadItem
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    var onAction: (() -> Void)?

    init(item: DownloadItem) {
        self.item = item
        super.init(frame: .zero)
        // Its own layer: a bar drawn while the transfer ran cannot survive into the
        // finished state, because the layer is redrawn from scratch.
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 12)
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

    func refresh() {
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.detail
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
        // By content type, never by opening the file: reading the Downloads folder is
        // exactly what makes macOS ask for permission.
        iconView.image = DownloadRowView.icon(for: item)
        needsDisplay = true
    }

    @objc private func act() { onAction?() }

    private func layoutContents() {
        let w = bounds.width
        iconView.frame = NSRect(x: 14, y: 11, width: 32, height: 32)
        let textX: CGFloat = 56
        nameLabel.frame = NSRect(x: textX, y: 9, width: max(0, w - textX - 44), height: 16)
        sizeLabel.frame = NSRect(x: textX, y: 26, width: max(0, w - textX - 44), height: 14)
        actionButton.frame = NSRect(x: w - 40, y: 15, width: 26, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard item.state == .downloading || item.state == .paused else { return }
        let track = NSRect(x: 14, y: bounds.height - 7, width: max(0, bounds.width - 28), height: 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

        let done = NSRect(x: track.minX, y: track.minY,
                          width: track.width * CGFloat(item.fraction), height: track.height)
        guard done.width > 0.5 else { return }
        (item.state == .paused ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: done, xRadius: 1, yRadius: 1).fill()
    }

    private static func icon(for item: DownloadItem) -> NSImage {
        let ext = item.destination.pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}
