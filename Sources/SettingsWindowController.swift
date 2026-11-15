import AppKit

/// The ⌘, window. Built on first use and reused afterwards, so there is only ever one
/// instance; it is an ordinary window (not a panel), so it never floats above anything.
///
/// Sections stack vertically and each owns its own controls, so future config
/// options slot in as new blocks without redesigning what is here.
final class SettingsWindowController: NSWindowController {

    private let showMemoryPillBox = NSButton(
        checkboxWithTitle: "Show memory usage in the toolbar", target: nil, action: nil)

    /// Group ids expanded in the picker. General and China start open; both AI
    /// groups start collapsed.
    private var expandedGroups: Set<String> = Set(SearchEngine.Group.allCases
        .filter { !$0.collapsedByDefault }.map { $0.rawValue })
    private var engineRows: [(engine: SearchEngine, button: NSButton)] = []
    private let engineScrollView = NSScrollView()
    private var engineDocumentView: NSView?

    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 28

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        // The controller keeps this window alive and shows it again on the next ⌘,.
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildContent()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let w = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))

        showMemoryPillBox.target = self
        showMemoryPillBox.action = #selector(toggleShowMemoryPill(_:))
        showMemoryPillBox.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        showMemoryPillBox.frame = NSRect(x: 20, y: 556, width: 440, height: 20)
        content.addSubview(showMemoryPillBox)

        let note = NSTextField(labelWithString:
            "Hides the total-memory pill on the right of the toolbar. Takes effect immediately.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 22, y: 530, width: 436, height: 16)
        content.addSubview(note)

        let divider = NSBox(frame: NSRect(x: 20, y: 508, width: 440, height: 5))
        divider.boxType = .separator
        content.addSubview(divider)

        let engineLabel = NSTextField(labelWithString: "Search Engine")
        engineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        engineLabel.frame = NSRect(x: 20, y: 484, width: 440, height: 20)
        content.addSubview(engineLabel)

        let engineNote = NSTextField(labelWithString:
            "Takes effect immediately. Engines marked as such need sign-in.")
        engineNote.font = .systemFont(ofSize: 11)
        engineNote.textColor = .secondaryLabelColor
        engineNote.frame = NSRect(x: 22, y: 466, width: 436, height: 14)
        content.addSubview(engineNote)

        engineScrollView.frame = NSRect(x: 20, y: 20, width: 440, height: 430)
        engineScrollView.hasVerticalScroller = true
        engineScrollView.hasHorizontalScroller = false
        engineScrollView.autohidesScrollers = true
        engineScrollView.drawsBackground = false
        engineScrollView.borderType = .noBorder
        content.addSubview(engineScrollView)
        rebuildEngineList()

        w.contentView = content
        w.center()
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        refreshEngineStates()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleShowMemoryPill(_ sender: NSButton) {
        Settings.shared.setShowMemoryPill(sender.state == .on)
        AppDelegate.shared?.settingsDidChange()
    }

    // MARK: - Search engine picker

    private func rebuildEngineList() {
        let width: CGFloat = 440
        var height: CGFloat = 0
        for group in SearchEngine.Group.allCases {
            height += Self.headerHeight
            if expandedGroups.contains(group.rawValue) {
                height += CGFloat(SearchEngines.all.filter { $0.group == group }.count) * Self.rowHeight
            }
        }
        let savedOffset = engineScrollView.contentView.bounds.origin
        engineDocumentView?.removeFromSuperview()
        engineRows = []

        let doc = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height
        let groups = SearchEngine.Group.allCases
        for (gi, group) in groups.enumerated() {
            let engines = SearchEngines.all.filter { $0.group == group }
            y -= Self.headerHeight
            let header = NSButton(title: "\(group.title) (\(engines.count))",
                                  target: self, action: #selector(toggleGroup(_:)))
            header.bezelStyle = .disclosure
            header.state = expandedGroups.contains(group.rawValue) ? .on : .off
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            header.tag = gi
            header.frame = NSRect(x: 0, y: y, width: width, height: Self.headerHeight)
            doc.addSubview(header)

            if expandedGroups.contains(group.rawValue) {
                for engine in engines {
                    y -= Self.rowHeight
                    guard let idx = SearchEngines.all.firstIndex(where: { $0.id == engine.id }) else { continue }
                    let row = NSButton(radioButtonWithTitle: engine.name,
                                       target: self, action: #selector(selectEngine(_:)))
                    row.tag = idx
                    row.image = Self.tileIcon(letter: String(engine.name.prefix(1)))
                    row.imagePosition = .imageLeft
                    row.frame = NSRect(x: 16, y: y, width: width - 16, height: Self.rowHeight)
                    doc.addSubview(row)
                    engineRows.append((engine, row))
                    if engine.requiresLogin {
                        let badge = NSTextField(labelWithString: "Requires sign-in")
                        badge.font = .systemFont(ofSize: 11)
                        badge.textColor = .secondaryLabelColor
                        badge.alignment = .right
                        badge.frame = NSRect(x: width - 130, y: y + 5, width: 120, height: 14)
                        doc.addSubview(badge)
                    }
                }
            }
        }
        engineDocumentView = doc
        engineScrollView.documentView = doc
        refreshEngineStates()

        var origin = savedOffset
        origin.y = min(max(origin.y, 0), max(0, height - engineScrollView.contentSize.height))
        engineScrollView.contentView.scroll(to: origin)
        engineScrollView.reflectScrolledClipView(engineScrollView.contentView)
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        let groups = SearchEngine.Group.allCases
        guard groups.indices.contains(sender.tag) else { return }
        let raw = groups[sender.tag].rawValue
        if expandedGroups.contains(raw) {
            expandedGroups.remove(raw)
        } else {
            expandedGroups.insert(raw)
        }
        rebuildEngineList()
    }

    @objc private func selectEngine(_ sender: NSButton) {
        guard SearchEngines.all.indices.contains(sender.tag) else { return }
        // Persists and takes effect on the very next search: resolve() reads the
        // live setting, so no window needs to reload or relayout.
        Config.shared.setSearchEngine(SearchEngines.all[sender.tag].id)
        refreshEngineStates()
    }

    private func refreshEngineStates() {
        let current = Config.shared.searchEngine
        for (engine, button) in engineRows {
            button.state = engine.id == current ? .on : .off
        }
    }

    /// Letter tile in the tab-fallback style: no network, no cache, no async.
    private static func tileIcon(letter: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        bg.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let s = NSAttributedString(string: letter, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2))
        img.unlockFocus()
        return img
    }
}
