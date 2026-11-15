import AppKit

/// The ⌘, window, laid out like Safari's preferences: a band of icon tabs under a
/// centred pane name, and one column of right-aligned labels with their controls.
/// Only panes with real settings behind them are shown; every key in config.json
/// appears somewhere here.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private enum Pane: Int, CaseIterable {
        case general, tabs, search, privacy, developer

        var title: String {
            switch self {
            case .general: return "General"
            case .tabs: return "Tabs"
            case .search: return "Search"
            case .privacy: return "Privacy"
            case .developer: return "Developer"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .tabs: return "square.on.square"
            case .search: return "magnifyingglass"
            case .privacy: return "hand.raised"
            case .developer: return "wrench.and.screwdriver"
            }
        }
    }

    private static let windowWidth: CGFloat = 600
    /// Title row (drawn under the transparent titlebar) plus the icon tab row.
    private static let chromeHeight: CGFloat = 80
    private static let bottomPadding: CGFloat = 56

    private let band = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let paneHost = FlippedView()
    private let helpButton = NSButton()
    private var paneButtons: [NSButton] = []
    private var chipWidths: [CGFloat] = []
    private var currentPane: Pane = .general

    /// Rebuilt on every pane switch, so it is only a weak reference to the live field.
    private weak var homepageField: NSTextField?
    /// Same for the download-folder popup, re-synced after the Choose panel closes.
    private weak var downloadPopup: NSPopUpButton?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.windowWidth,
                                             height: 340),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = Pane.general.title
        // The pane name is drawn by us, centred, so it reads the same on every macOS
        // version instead of following the titlebar's own alignment rules.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        // No line across the band where the titlebar would normally end.
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = .windowBackgroundColor
        // The controller keeps this window alive and shows it again on the next ⌘,.
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.delegate = self
        buildContent()
        selectPane(.general)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Chrome

    private func buildContent() {
        guard let w = window else { return }
        let content = FlippedView(frame: NSRect(x: 0, y: 0,
                                                width: Self.windowWidth, height: 340))

        // No separate band or divider: the title and tab row sit directly on the
        // window background, continuous with the pane below.
        content.addSubview(band)

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        band.addSubview(titleLabel)

        for pane in Pane.allCases {
            let b = NSButton(frame: .zero)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            // Icon above its label, sized like Safari's tab items.
            b.imagePosition = .imageAbove
            b.alignment = .center
            b.imageScaling = .scaleProportionallyDown
            b.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            b.tag = pane.rawValue
            b.target = self
            b.action = #selector(choosePane(_:))
            b.toolTip = pane.title
            band.addSubview(b)
            paneButtons.append(b)
            chipWidths.append(Self.chipWidth(for: pane.title))
        }

        content.addSubview(paneHost)

        // The round help button in the bottom-right corner, as in Safari's panes.
        helpButton.bezelStyle = .circular
        helpButton.title = "?"
        helpButton.font = .systemFont(ofSize: 12, weight: .semibold)
        helpButton.target = self
        helpButton.action = #selector(showHelp(_:))
        helpButton.toolTip = "Where these settings are stored"
        content.addSubview(helpButton)

        w.contentView = content
        w.center()
        layoutChrome()
    }

    /// Everything in the window is positioned here, so a pane change can resize the
    /// window and the band, tabs and help button follow without autoresizing guesses.
    private func layoutChrome() {
        guard let content = window?.contentView else { return }
        let size = content.bounds.size
        band.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.chromeHeight)
        titleLabel.frame = NSRect(x: 0, y: 9, width: size.width, height: 17)
        paneHost.frame = NSRect(x: 0, y: Self.chromeHeight, width: size.width,
                                height: max(0, size.height - Self.chromeHeight))
        helpButton.frame = NSRect(x: size.width - 46, y: size.height - 46, width: 28, height: 28)

        // One centred row of icon-over-label items.
        let gap: CGFloat = 6
        let total = chipWidths.reduce(0, +) + gap * CGFloat(max(0, chipWidths.count - 1))
        var x = max(12, (size.width - total) / 2)
        for (i, b) in paneButtons.enumerated() {
            let w = chipWidths.indices.contains(i) ? chipWidths[i] : 74
            b.frame = NSRect(x: x, y: 30, width: w, height: 44)
            x += w + gap
        }
    }

    private static func chipWidth(for title: String) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        return max(58, ceil(text) + 18)
    }

    func windowDidResize(_ notification: Notification) {
        layoutChrome()
    }

    @objc private func choosePane(_ sender: NSButton) {
        guard let pane = Pane(rawValue: sender.tag) else { return }
        flushHomepage()
        selectPane(pane)
    }

    private func selectPane(_ pane: Pane) {
        currentPane = pane
        window?.title = pane.title
        titleLabel.stringValue = pane.title
        for b in paneButtons {
            let selected = b.tag == pane.rawValue
            b.layer?.backgroundColor = selected
                ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
            let color: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
            b.contentTintColor = color
            b.attributedTitle = NSAttributedString(
                string: Pane(rawValue: b.tag)?.title ?? "",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
        }
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        homepageField = nil
        let builder = PaneBuilder(host: paneHost, width: window?.contentView?.bounds.width ?? Self.windowWidth)
        switch pane {
        case .general: buildGeneral(builder)
        case .tabs: buildTabs(builder)
        case .search: buildSearch(builder)
        case .privacy: buildPrivacy(builder)
        case .developer: buildDeveloper(builder)
        }
        resizeWindow(toContentHeight: Self.chromeHeight + builder.maxY + Self.bottomPadding)
    }

    /// Panes size themselves to their rows, the way Safari's preferences do, so a
    /// short pane never leaves a screenful of empty window under it.
    /// Keep a fixed top edge: growing downward is what people expect from a
    /// preferences window, so the bottom moves and the title stays put.
    private func resizeWindow(toContentHeight height: CGFloat) {
        guard let w = window else { return }
        var frame = w.frame
        if abs(frame.height - height) < 0.5 { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        w.setFrame(frame, display: true)
        layoutChrome()
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        flushHomepage()
        // Rebuild so a hand-edited config.json or the toolbar shield shows up here.
        selectPane(currentPane)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A typed-but-uncommitted homepage is flushed on close, so typing a URL and
    /// clicking the red dot still saves it.
    func windowWillClose(_ notification: Notification) {
        flushHomepage()
    }

    private func flushHomepage() {
        guard let field = homepageField, field.stringValue != Config.shared.homepage else { return }
        commitHomepage(field)
    }

    // MARK: - Panes

    private func buildGeneral(_ b: PaneBuilder) {
        let opens = NSPopUpButton(frame: .zero, pullsDown: false)
        opens.addItems(withTitles: ["A new window", "All windows from last session"])
        opens.selectItem(at: Config.shared.restoreSessionOnLaunch ? 1 : 0)
        opens.target = self
        opens.action = #selector(chooseRestoreSession(_:))
        b.row("Lantern opens with:", opens)

        let field = NSTextField(string: Config.shared.homepage)
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .default
        field.target = self
        field.action = #selector(commitHomepage(_:))
        field.toolTip = "Blank means the start page."
        b.row("Homepage:", field)
        homepageField = field

        let setCurrent = NSButton(title: "Set to Current Page", target: self,
                                  action: #selector(setHomepageToCurrentPage(_:)))
        setCurrent.bezelStyle = .rounded
        b.indented(setCurrent)

        b.note("New tabs open the homepage when one is set. Blank keeps the native start page.")
        b.spacer(10)

        // Safari puts the download folder below the home page block, in its own group.
        let downloads = NSPopUpButton(frame: .zero, pullsDown: false)
        syncDownloadPopup(downloads)
        downloads.target = self
        downloads.action = #selector(chooseDownloadFolder(_:))
        b.row("File download location:", downloads)
        downloadPopup = downloads
    }

    private func buildTabs(_ b: PaneBuilder) {
        let sleep = NSPopUpButton(frame: .zero, pullsDown: false)
        sleep.menu = hibernateMenu()
        syncHibernate(sleep)
        sleep.target = self
        sleep.action = #selector(chooseHibernate(_:))
        b.row("Sleep background tabs:", sleep)

        let pressure = NSButton(checkboxWithTitle: "Sleep them immediately when memory is tight",
                                target: self, action: #selector(toggleMemoryPressure(_:)))
        pressure.state = Config.shared.hibernateOnMemoryPressure ? .on : .off
        b.row("Low memory:", pressure)

        let pill = NSButton(checkboxWithTitle: "Show memory usage in the toolbar",
                            target: self, action: #selector(toggleMemoryPill(_:)))
        pill.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        b.row("Memory readout:", pill)

        b.note("Sleeping destroys a tab's web process and keeps its scroll position and history, "
               + "so a background tab costs a couple of KB instead of ~100 MB.")
        b.spacer(6)

        let commandClick = NSButton(checkboxWithTitle: "⌘-click opens a link in a new tab",
                                    target: self, action: #selector(toggleCommandClickNewTab(_:)))
        commandClick.state = Config.shared.commandClickOpensNewTab ? .on : .off
        b.row("Navigation:", commandClick)

        let activate = NSButton(checkboxWithTitle: "Make a new tab the active tab",
                                target: self, action: #selector(toggleActivateNewTab(_:)))
        activate.state = Config.shared.activateNewTabsOnOpen ? .on : .off
        b.indented(activate)

        let numberKeys = NSButton(checkboxWithTitle: "Use ⌘-1 through ⌘-9 to switch tabs",
                                  target: self, action: #selector(toggleCommandNumberTabs(_:)))
        numberKeys.state = Config.shared.useCommandNumberTabShortcuts ? .on : .off
        b.indented(numberKeys)

        // Lives here rather than in its own row: it is a navigation nicety.
        let doubleClick = NSButton(checkboxWithTitle: "Double-click empty space for a new tab",
                                   target: self, action: #selector(toggleDoubleClickNewTab(_:)))
        doubleClick.state = Config.shared.doubleClickTabStripForNewTab ? .on : .off
        b.indented(doubleClick)

        b.note("With ⌘-click off it behaves like an ordinary click. Middle-click always "
               + "opens a background tab.")
        b.spacer(2)
        b.legend("⌘-click:", "Opens a link in a new background tab.")
        b.legend("⌘-Shift-click:", "Opens a link in a new tab, and makes it active.")
    }

    private func buildSearch(_ b: PaneBuilder) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        buildEngineMenu(into: popup)
        popup.target = self
        popup.action = #selector(selectEngine(_:))
        b.row("Search engine:", popup)

        b.note("Engines marked Requires sign-in open their sign-in page first. "
               + "The choice applies to the very next search.")
    }

    private func buildPrivacy(_ b: PaneBuilder) {
        let block = NSButton(checkboxWithTitle: "Block ads and trackers",
                             target: self, action: #selector(toggleBlocking(_:)))
        block.state = Config.shared.blockAdsAndTrackers ? .on : .off
        b.row("Website tracking:", block)

        b.note("Open tabs reload so the network rules take effect.")

        let data = NSButton(title: "Manage Website Data…", target: self,
                            action: #selector(manageWebsiteData(_:)))
        data.bezelStyle = .rounded
        b.row("Website data:", data, height: 26)

        b.note("Clearing removes cookies and cached files, and signs you out of sites.")
    }

    private func buildDeveloper(_ b: PaneBuilder) {
        let tools = NSButton(checkboxWithTitle: "Enable Inspect Element on pages",
                             target: self, action: #selector(toggleDeveloperTools(_:)))
        tools.state = Config.shared.enableDeveloperTools ? .on : .off
        b.row("Web Inspector:", tools)

        b.note("Applies to tabs opened afterwards. Right-clicking a page then offers Inspect Element.")
    }

    // MARK: - General

    @objc private func chooseRestoreSession(_ sender: NSPopUpButton) {
        // Read on the next launch, so there is nothing live to notify.
        Config.shared.restoreSessionOnLaunch = sender.indexOfSelectedItem == 1
        Config.shared.save()
    }

    @objc private func setHomepageToCurrentPage(_ sender: NSButton) {
        guard let field = homepageField,
              let url = AppDelegate.shared?.front?.activeTab?.url?.absoluteString else {
            NSSound.beep()
            return
        }
        field.stringValue = url
        commitHomepage(field)
    }

    @objc private func commitHomepage(_ sender: NSTextField) {
        let raw = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            Config.shared.homepage = "about:blank"
        } else if Self.isHomepageValue(raw) {
            Config.shared.homepage = raw
        } else {
            NSSound.beep()
            sender.stringValue = Config.shared.homepage
            return
        }
        Config.shared.save()
        sender.stringValue = Config.shared.homepage
    }

    /// The folder item shows its icon and name, like Safari; "Choose…" opens the
    /// directory picker. Rebuilt from Config each time, so cancel or a hand-edited
    /// config.json can never leave a stale row behind.
    private func syncDownloadPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        let url = Config.shared.downloadDirectoryURL
        popup.addItem(withTitle: url.lastPathComponent)
        if let item = popup.lastItem {
            // The stock folder icon, not the folder's own: asking LaunchServices about
            // ~/Downloads reads the folder, which is what makes macOS ask for permission
            // before a single file has been downloaded. Menu items draw images at their
            // natural size and the stock icon is large, so it has to be pinned to the
            // 16 point slot menus use or it overflows the row.
            if let icon = NSImage(named: NSImage.folderName)?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
        }
        popup.addItem(withTitle: "Choose…")
        popup.selectItem(at: 0)
        popup.toolTip = url.path
    }

    @objc private func chooseDownloadFolder(_ sender: NSPopUpButton) {
        // The folder item itself is display-only; only "Choose…" acts. Re-select it
        // rather than rebuilding the menu inside its own action.
        guard sender.indexOfSelectedItem == sender.numberOfItems - 1, let w = window else {
            sender.selectItem(at: 0)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.shared.downloadDirectoryURL
        panel.prompt = "Choose"
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = panel.urls.first else {
                if let p = self?.downloadPopup { self?.syncDownloadPopup(p) }
                return
            }
            Config.shared.downloadDirectory = url.path
            Config.shared.save()
            if let p = self?.downloadPopup { self?.syncDownloadPopup(p) }
        }
    }

    private static func isHomepageValue(_ s: String) -> Bool {
        if s.lowercased() == "about:blank" { return true }
        guard let u = URL(string: s),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return u.host != nil
    }

    // MARK: - Tabs

    private func hibernateMenu() -> NSMenu {
        let menu = NSMenu()
        // Manual validation stays off so every interval stays choosable.
        menu.autoenablesItems = false
        for (title, minutes) in [("Never", 0), ("After 1 minute", 1), ("After 5 minutes", 5),
                                 ("After 15 minutes", 15), ("After 30 minutes", 30)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = minutes
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseHibernate(_ sender: NSPopUpButton) {
        Config.shared.hibernateAfterMinutes = Double(sender.selectedTag())
        Config.shared.save()
        // applySettings restarts the timer with the new interval.
        AppDelegate.shared?.settingsDidChange()
    }

    private func syncHibernate(_ popup: NSPopUpButton) {
        let minutes = Int(Config.shared.hibernateAfterMinutes)
        if popup.menu?.items.contains(where: { $0.tag == minutes }) == true {
            popup.selectItem(withTag: minutes)
        } else {
            // A hand-written interval with no matching row: nothing selected.
            popup.select(nil)
        }
    }

    @objc private func toggleMemoryPressure(_ sender: NSButton) {
        Config.shared.hibernateOnMemoryPressure = (sender.state == .on)
        Config.shared.save()
        // applySettings starts or stops the watchdog to match.
        AppDelegate.shared?.settingsDidChange()
    }

    @objc private func toggleMemoryPill(_ sender: NSButton) {
        Settings.shared.setShowMemoryPill(sender.state == .on)
        AppDelegate.shared?.settingsDidChange()
    }

    @objc private func toggleDoubleClickNewTab(_ sender: NSButton) {
        // Read on each click in the tab strip, so there is nothing live to notify.
        Config.shared.doubleClickTabStripForNewTab = (sender.state == .on)
        Config.shared.save()
    }

    @objc private func toggleCommandClickNewTab(_ sender: NSButton) {
        // Read while WebKit decides each link click, so it applies immediately.
        Config.shared.commandClickOpensNewTab = (sender.state == .on)
        Config.shared.save()
    }

    @objc private func toggleActivateNewTab(_ sender: NSButton) {
        Config.shared.activateNewTabsOnOpen = (sender.state == .on)
        Config.shared.save()
    }

    @objc private func toggleCommandNumberTabs(_ sender: NSButton) {
        // The Window menu validates against this, so the shortcut follows at once.
        Config.shared.useCommandNumberTabShortcuts = (sender.state == .on)
        Config.shared.save()
    }

    // MARK: - Privacy

    @objc private func toggleBlocking(_ sender: NSButton) {
        Config.shared.blockAdsAndTrackers = (sender.state == .on)
        Config.shared.save()
        AppDelegate.shared?.blockingSettingChanged()
    }

    @objc private func manageWebsiteData(_ sender: NSButton) {
        AppDelegate.shared?.clearWebsiteData()
    }

    // MARK: - Developer

    @objc private func toggleDeveloperTools(_ sender: NSButton) {
        // Read when each web view is created, so already-open tabs are untouched.
        Config.shared.enableDeveloperTools = (sender.state == .on)
        Config.shared.save()
    }

    // MARK: - Search engine picker

    /// One dropdown for every engine. Group names are disabled separator items, so
    /// the whole catalog fits in one control. Items carry the engine id in
    /// `representedObject`: the group headers share tag 0, so tags cannot identify an
    /// engine (Google is index 0) without the header winning the lookup.
    private func buildEngineMenu(into popup: NSPopUpButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in SearchEngine.Group.allCases {
            let engines = SearchEngines.all.filter { $0.group == group }
            guard !engines.isEmpty else { continue }
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for engine in engines {
                let item = NSMenuItem(title: engine.name, action: nil, keyEquivalent: "")
                item.tag = 1
                item.representedObject = engine.id
                item.image = Self.tileIcon(letter: String(engine.name.prefix(1)))
                if engine.requiresLogin {
                    let titled = NSMutableAttributedString(
                        string: engine.name + "  ",
                        attributes: [.font: NSFont.systemFont(ofSize: 13)])
                    titled.append(NSAttributedString(
                        string: "Requires sign-in",
                        attributes: [.font: NSFont.systemFont(ofSize: 11),
                                     .foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = titled
                }
                menu.addItem(item)
            }
        }
        popup.menu = menu
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == Config.shared.searchEngine
        }) {
            popup.select(item)
        } else {
            // A hand-written template with no matching engine: nothing selected.
            popup.select(nil)
        }
    }

    @objc private func selectEngine(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              SearchEngines.engine(id: id) != nil else { return }
        // Persists and takes effect on the very next search: resolve() reads the
        // live setting, so no window needs to reload or relayout.
        Config.shared.setSearchEngine(id)
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

    // MARK: - Help

    @objc private func showHelp(_ sender: NSButton) {
        let a = NSAlert()
        a.messageText = "Where these settings live"
        a.informativeText = """
            Everything here is also a key in config.json, in \
            ~/Library/Application Support/Lantern. Edits made here are saved at once; \
            hand edits are picked up the next time this window opens.
            """
        a.addButton(withTitle: "OK")
        if let w = window {
            a.beginSheetModal(for: w, completionHandler: nil)
        } else {
            a.runModal()
        }
    }
}

/// Places right-aligned labels and their controls in one column, top to bottom,
/// in a flipped view so the cursor grows downward.
private final class PaneBuilder {
    private let host: NSView
    private let width: CGFloat
    private var y: CGFloat = 26

    /// Where the last row ended, so the window can be sized to fit the pane.
    var maxY: CGFloat { y }

    /// The label+control block is centred in the window, so the pane reads as one
    /// column instead of hugging the left edge.
    private var blockLeft: CGFloat { max(20, (width - 450) / 2) }
    private var labelRight: CGFloat { blockLeft + 160 }
    private var controlX: CGFloat { labelRight + 10 }
    private var controlWidth: CGFloat { width - controlX - blockLeft }

    init(host: NSView, width: CGFloat) {
        self.host = host
        self.width = width
    }

    func row(_ text: String, _ control: NSView, height: CGFloat = 24) {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: blockLeft, y: y + (height - 17) / 2, width: labelRight - blockLeft, height: 17)
        host.addSubview(label)
        control.frame = NSRect(x: controlX, y: y, width: controlWidth, height: height)
        host.addSubview(control)
        y += height + 8
    }

    /// A control that sits under the one above it rather than beside a label.
    func indented(_ control: NSButton) {
        control.sizeToFit()
        control.frame.origin = NSPoint(x: controlX, y: y)
        host.addSubview(control)
        y += control.frame.height + 8
    }

    func note(_ text: String) {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = controlWidth
        let h = note.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: controlWidth, height: .greatestFiniteMagnitude)).height ?? 16
        note.frame = NSRect(x: controlX, y: y, width: controlWidth, height: h)
        host.addSubview(note)
        y += h + 10
    }

    /// A read-only row: the gesture on the label side, what it does beside it.
    func legend(_ key: String, _ text: String) {
        let label = NSTextField(labelWithString: key)
        label.alignment = .right
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let desc = NSTextField(wrappingLabelWithString: text)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = controlWidth
        let h = max(16, desc.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: controlWidth, height: .greatestFiniteMagnitude)).height ?? 16)
        label.frame = NSRect(x: blockLeft, y: y + 1, width: labelRight - blockLeft, height: 16)
        desc.frame = NSRect(x: controlX, y: y, width: controlWidth, height: h)
        host.addSubview(label)
        host.addSubview(desc)
        y += h + 2
    }

    func spacer(_ h: CGFloat) { y += h }
}
