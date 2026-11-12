import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripDidSelect(index: Int)
    func tabStripDidRequestClose(index: Int)
    func tabStripDidRequestNewTab()
    /// Title/handler pairs for a tab's right-click menu; "-" means a separator.
    func tabStripContextActions(index: Int) -> [(String, () -> Void)]
    func tabStripDidRequestMove(from: Int, to: Int)
}

/// One view per tab, everything drawn by hand. A stock NSTableView or NSSegmented
/// control would add layers, cells and layout passes we do not need.
final class TabItemView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var favicon: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isHibernated = false { didSet { needsDisplay = true } }
    var isLoading = false { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if isLoading { needsDisplay = true } } }
    var isPrivate = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var closeHovering = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var contextActions: [(String, () -> Void)] = []
    /// Drag-to-reorder. The strip owns the reordering logic; the item only reports
    /// where the press started and where the pointer is now.
    var onDragBegan: ((CGFloat) -> Void)?      // press x within this item
    var onDragChanged: ((NSPoint) -> Void)?    // pointer, window coordinates
    var onDragEnded: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// A press on a tab belongs to the tab, never to the window. The window is
    /// `isMovableByWindowBackground`, and AppKit would otherwise start dragging the
    /// window instead of delivering mouseDragged, so the tab could not reorder.
    override var mouseDownCanMoveWindow: Bool { false }

    private var showsTitle: Bool { bounds.width >= 76 }
    /// Safari keeps the close button's slot even while the button is hidden, so the
    /// icon and title do not shift sideways when the tab is hovered.
    private var hasCloseSlot: Bool { bounds.width >= 58 }
    private var showsClose: Bool { hasCloseSlot && (hovering || isSelected) }
    /// Leading edge, like Safari — the tab title no longer runs into it.
    private var closeRect: NSRect {
        NSRect(x: bounds.minX + 5, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
    /// The band left for the icon and title, after the close button's slot.
    private var contentLeft: CGFloat { hasCloseSlot ? closeRect.maxX + 4 : bounds.minX + 7 }
    private var contentRight: CGFloat { bounds.maxX - 7 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; closeHovering = false }
    override func mouseMoved(with event: NSEvent) {
        closeHovering = closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    private var pressPoint: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The close button is its own control: swallow the press here, before
        // pressPoint is recorded, so a click (or a press-and-drag) that starts on it
        // can never become a tab press or begin the drag-to-reorder gesture.
        if showsClose, closeRect.contains(p) {
            pressPoint = nil
            dragging = false
            onClose?()
            return
        }
        if event.type == .otherMouseDown { onClose?(); return }
        pressPoint = p
        onSelect?()   // select on press, like Safari, so dragging the current tab feels direct
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressPoint else { return }
        let here = convert(event.locationInWindow, from: nil)
        if !dragging, abs(here.x - press.x) > 5 {
            dragging = true
            onDragBegan?(press.x)
        }
        if dragging { onDragChanged?(event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDragEnded?() }
        pressPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }  // middle-click closes

    override func rightMouseDown(with event: NSEvent) {
        guard !contextActions.isEmpty else { return super.rightMouseDown(with: event) }
        let menu = NSMenu()
        for (i, entry) in contextActions.enumerated() {
            if entry.0 == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.0, action: #selector(runContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func runContextAction(_ sender: NSMenuItem) {
        guard contextActions.indices.contains(sender.tag) else { return }
        contextActions[sender.tag].1()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }

        // Safari parity: the close button owns the leading edge, so the title is
        // measured first and the icon + title are then centred as one group in the
        // band that is left. Nothing here is laid out by hand twice.
        let iconSize: CGFloat = 16
        let iconGap: CGFloat = 6
        let available = max(0, contentRight - contentLeft)

        let titleColor: NSColor = isSelected ? .labelColor
            : (isHibernated ? .tertiaryLabelColor : .secondaryLabelColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph,
        ]
        let titleString = showsTitle ? NSAttributedString(string: title, attributes: titleAttrs) : nil
        let maxTitleWidth = max(0, available - iconSize - iconGap)
        let titleWidth = titleString.map { min($0.size().width.rounded(.up), maxTitleWidth) } ?? 0
        let groupWidth = iconSize + (titleWidth > 0 ? iconGap + titleWidth : 0)

        var x = contentLeft + max(0, (available - groupWidth) / 2)
        let iconY = (bounds.height - iconSize) / 2

        if isLoading {
            // A quiet arc instead of a spinning NSProgressIndicator: no timer, no layer.
            let c = NSPoint(x: x + iconSize / 2, y: bounds.midY)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: 6, startAngle: 0, endAngle: 360)
            NSColor.tertiaryLabelColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 6, startAngle: 90,
                          endAngle: 90 - CGFloat(360 * max(0.08, progress)), clockwise: true)
            NSColor.controlAccentColor.setStroke()
            arc.lineWidth = 2
            arc.stroke()
        } else if let icon = favicon {
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            // This view is flipped, and without respectFlipped the image maps with
            // its origin at the wrong corner and renders upside down.
            if isHibernated {
                NSGraphicsContext.current?.saveGraphicsState()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45,
                          respectFlipped: true, hints: nil)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                          respectFlipped: true, hints: nil)
            }
        } else {
            // Letter tile fallback so tabs never look empty.
            let letter = String(title.first.map(String.init)?.uppercased() ?? "\u{2022}")
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            let bg = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.tertiaryLabelColor.withAlphaComponent(isHibernated ? 0.2 : 0.35).setFill()
            bg.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        }
        x += iconSize

        if let titleString, titleWidth > 0 {
            x += iconGap
            let h = titleString.size().height
            titleString.draw(with: NSRect(x: x, y: bounds.midY - h / 2, width: maxTitleWidth, height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if isPrivate {
            // Moved to the trailing edge: the leading corner is the close button now.
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 9, y: r.minY + 2.5, width: 5, height: 5))
            NSColor.systemPurple.setFill()
            dot.fill()
        }

        if showsClose {
            let cr = closeRect
            if closeHovering {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
            }
            let inset = cr.insetBy(dx: 4.5, dy: 4.5)
            let x1 = NSBezierPath()
            x1.move(to: NSPoint(x: inset.minX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            x1.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            (closeHovering ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
            x1.lineWidth = 1.3
            x1.lineCapStyle = .round
            x1.stroke()
        }
    }
}

final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private var items: [TabItemView] = []
    private var dragIndex: Int?
    private var dragGrabX: CGFloat = 0     // where in the tab the press landed
    private var dragPointerX: CGFloat = 0  // pointer, strip coordinates

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild only when the tab count changes; otherwise update in place so
    /// typing in a page title does not churn the view hierarchy.
    func update(tabs: [Tab], selected: Int) {
        if items.count != tabs.count {
            // The views below are replaced, so a drag in flight has no view left to
            // track and must not keep an index into the old array.
            if dragIndex != nil { endDrag() }
            items.forEach { $0.removeFromSuperview() }
            items = tabs.indices.map { i in
                let v = TabItemView()
                v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
                v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
                addSubview(v)
                return v
            }
        }
        for (i, tab) in tabs.enumerated() {
            let v = items[i]
            v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
            v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
            v.title = tab.displayTitle
            v.favicon = tab.favicon
            v.isSelected = (i == selected)
            v.isHibernated = tab.isHibernated
            v.isLoading = tab.isLoading
            v.progress = tab.progress
            v.isPrivate = tab.isPrivate
            v.contextActions = delegate?.tabStripContextActions(index: i) ?? []
            v.onDragBegan = { [weak self] grabX in self?.beginDrag(i, grabX: grabX) }
            v.onDragChanged = { [weak self] p in self?.updateDrag(p) }
            v.onDragEnded = { [weak self] in self?.endDrag() }
            v.toolTip = tab.isHibernated
                ? "\(tab.displayTitle) \u{2014} sleeping (0 MB)"
                : tab.url?.absoluteString ?? tab.displayTitle
        }
        layoutTabs()
    }

    /// Safari's bargain, active-first: the selected tab is always allocated its
    /// full maximum while every inactive tab shares the remainder. Inactive tabs
    /// shrink to their floor before the active tab gives up a single point, and
    /// below that everything scales in proportion so the row still fills the strip.
    private let maxTabWidth: CGFloat = 210
    private let minActiveTabWidth: CGFloat = 140
    private let minInactiveTabWidth: CGFloat = 48

    /// One width per item, in `items` order. The selected tab is found by its flag
    /// rather than by an index, because a drag swaps this array around.
    private func tabWidths() -> [CGFloat] {
        let n = items.count
        guard n > 0 else { return [] }
        let available = max(0, bounds.width - 6)
        if n == 1 { return [min(maxTabWidth, available)] }
        let selected = items.firstIndex(where: { $0.isSelected }) ?? 0
        // 1. Plenty of room: the active tab takes its maximum, the rest split
        //    the remainder evenly (which here is still >= the maximum each).
        if available >= maxTabWidth * CGFloat(n) { return Array(repeating: maxTabWidth, count: n) }
        // 2. Normal crowding: active pinned at the maximum, inactive share the rest.
        if available >= maxTabWidth + CGFloat(n - 1) * minInactiveTabWidth {
            let inactive = (available - maxTabWidth) / CGFloat(n - 1)
            return items.indices.map { $0 == selected ? maxTabWidth : inactive }
        }
        // 3. Inactive tabs are at their floor; the active tab now absorbs the
        //    overflow instead, and can shrink as far as its own minimum.
        if available >= minActiveTabWidth + CGFloat(n - 1) * minInactiveTabWidth {
            let active = available - CGFloat(n - 1) * minInactiveTabWidth
            return items.indices.map { $0 == selected ? active : minInactiveTabWidth }
        }
        // 4. Not even the minimums fit: shrink in proportion so the row still
        //    exactly fills the strip instead of overflowing it.
        let scale = available / (minActiveTabWidth + CGFloat(n - 1) * minInactiveTabWidth)
        return items.indices.map {
            $0 == selected ? minActiveTabWidth * scale : minInactiveTabWidth * scale
        }
    }

    private func layoutTabs() {
        guard !items.isEmpty else { return }
        let widths = tabWidths()
        var x: CGFloat = 0
        for (i, v) in items.enumerated() {
            if i == dragIndex { x += widths[i]; continue }   // positioned below, on top of the rest
            v.frame = NSRect(x: x, y: 0, width: widths[i], height: bounds.height)
            x += widths[i]
        }
        if let d = dragIndex, items.indices.contains(d) {
            let rowWidth = widths.reduce(0, +)
            let clamped = max(0, min(rowWidth - widths[d], dragPointerX - dragGrabX))
            items[d].frame = NSRect(x: clamped, y: 0, width: widths[d], height: bounds.height)
        }
    }

    // MARK: - Drag to reorder

    private func beginDrag(_ index: Int, grabX: CGFloat) {
        guard items.indices.contains(index) else { return }
        dragIndex = index
        dragGrabX = grabX
        dragPointerX = items[index].frame.minX + grabX
        addSubview(items[index])          // raise above its neighbours while moving
    }

    private func updateDrag(_ pointerInWindow: NSPoint) {
        guard let from = dragIndex else { return }
        guard items.indices.contains(from) else { endDrag(); return }
        dragPointerX = convert(pointerInWindow, from: nil).x
        let widths = tabWidths()
        guard !widths.isEmpty else { return }

        // The dragged tab's centre decides its slot. Slots are the row's current
        // cumulative widths, so the index stays right when tabs differ in size.
        let leadingEdge = dragPointerX - dragGrabX
        let to = dropIndex(center: leadingEdge + widths[from] / 2, widths: widths)
        if to != from {
            // Move the view exactly as the model moves, so items[i] keeps describing
            // tab i and the view under the pointer stays the one being dragged. The
            // delegate's update() then rebinds content by index and agrees with us.
            let moved = items.remove(at: from)
            items.insert(moved, at: to)
            dragIndex = to
            // grabX is preserved so the tab stays under the pointer.
            delegate?.tabStripDidRequestMove(from: from, to: to)
        }
        layoutTabs()
    }

    /// The slot whose span contains `center`, found by walking the row's cumulative
    /// widths. Identical to centre-rounding when every tab is the same width.
    private func dropIndex(center: CGFloat, widths: [CGFloat]) -> Int {
        var edge: CGFloat = 0
        for i in widths.indices {
            edge += widths[i]
            if center < edge { return i }
        }
        return max(0, widths.count - 1)
    }

    private func endDrag() {
        dragIndex = nil
        layoutTabs()
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// Double-clicking empty strip space opens a tab, as in every other browser. Single
    /// clicks fall through so the window can still be dragged by its top bar.
    override func mouseDown(with event: NSEvent) {
        // Empty strip space only: a press that lands on a tab is handled by the item itself,
        // and the strip is no longer the window's titlebar, so double-clicking the top bar
        // keeps its standard macOS behaviour.
        let p = convert(event.locationInWindow, from: nil)
        let onTab = items.contains { $0.frame.contains(p) }
        if event.clickCount == 2, !onTab {
            delegate?.tabStripDidRequestNewTab()
            return
        }
        super.mouseDown(with: event)
    }
}

/// 2px determinate bar under the toolbar. Hidden at rest so there is nothing to animate.
final class ProgressBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { isHidden = !active; needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.02, progress)), height: bounds.height).fill()
    }
}
