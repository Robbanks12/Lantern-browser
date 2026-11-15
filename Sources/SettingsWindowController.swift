import AppKit

/// The ⌘, window, laid out like Safari's preferences: a strip of icon tabs across the
/// top, the pane's name as the window title, and one column of right-aligned labels
/// with their controls. Only panes with real settings behind them are shown; every
/// key in config.json appears somewhere here.
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

    private static let windowWidth: CGFloat = 620
    private static let windowHeight: CGFloat = 560
    private static let toolbarHeight: CGFloat = 80

    private var paneButtons: [NSButton] = []
    private let paneHost = FlippedView()
    private var currentPane: Pane = .general

    /// Rebuilt on every pane switch, so it is only a weak reference to the live field.
    private weak var homepageField: NSTextField?
    private var enginePopup: NSPopUpButton?
    private var hibernatePopup: NSPopUpButton?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.windowWidth,
                                             height: SettingsWindowController.windowHeight),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = Pane.general.title
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
                                                width: Self.windowWidth, height: Self.windowHeight))
        content.autoresizingMask = [.width, .height]

        // The icon strip sits on a slightly lighter band, like Safari's.
        let toolbar = FlippedView(frame: NSRect(x: 0, y: 0,
                                                width: Self.windowWidth, height: Self.toolbarHeight))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        toolbar.autoresizingMask = [.width]

        let count = CGFloat(Pane.allCases.count)
        let buttonWidth: CGFloat = 88
        let spacing: CGFloat = 10
        let total = count * buttonWidth + (count - 1) * spacing
        var x = (Self.windowWidth - total) / 2
        for pane in Pane.allCases {
            let b = NSButton(frame: NSRect(x: x, y: 7, width: buttonWidth, height: 66))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.imagePosition = .imageAbove
            b.alignment = .center
            b.imageScaling = .scaleProportionallyDown
            b.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 21, weight: .regular))
            b.tag = pane.rawValue
            b.target = self
            b.action = #selector(choosePane(_:))
            b.toolTip = pane.title
            toolbar.addSubview(b)
            paneButtons.append(b)
            x += buttonWidth + spacing
        }

        let hairline = NSBox(frame: NSRect(x: 0, y: Self.toolbarHeight - 1,
                                           width: Self.windowWidth, height: 1))
        hairline.boxType = .separator
        hairline.autoresizingMask = [.width]
        toolbar.addSubview(hairline)
        content.addSubview(toolbar)

        paneHost.frame = NSRect(x: 0, y: Self.toolbarHeight, width: Self.windowWidth,
                                height: Self.windowHeight - Self.toolbarHeight)
        paneHost.autoresizingMask = [.width, .height]
        content.addSubview(paneHost)

        // The round help button in the bottom-right corner, as in Safari's panes.
        let help = NSButton(frame: NSRect(x: Self.windowWidth - 46,
                                          y: Self.windowHeight - 48, width: 28, height: 28))
        help.bezelStyle = .circular
        help.title = "?"
        help.font = .systemFont(ofSize: 12, weight: .semibold)
        help.target = self
        help.action = #selector(showHelp(_:))
        help.toolTip = "Where these settings are stored"
        help.autoresizingMask = [.minXMargin]
        content.addSubview(help)

        w.contentView = content
        w.center()
    }

    @objc private func choosePane(_ sender: NSButton) {
        guard let pane = Pane(rawValue: sender.tag) else { return }
        flushHomepage()
        selectPane(pane)
    }

    private func selectPane(_ pane: Pane) {
        currentPane = pane
        window?.title = pane.title
        for b in paneButtons {
            let selected = b.tag == pane.rawValue
            b.layer?.backgroundColor = selected
                ? NSColor.labelColor.withAlphaComponent(0.1).cgColor
                : NSColor.clear.cgColor
            b.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            let color: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
            b.attributedTitle = NSAttributedString(
                string: Pane(rawValue: b.tag)?.title ?? "",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
        }
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        homepageField = nil
        enginePopup = nil
        hibernatePopup = nil
        switch pane {
        case .general: buildGeneral(in: paneHost)
        case .tabs: buildTabs(in: paneHost)
        case .search: buildSearch(in: paneHost)
        case .privacy: buildPrivacy(in: paneHost)
        case .developer: buildDeveloper(in: paneHost)
        }
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        flushHomepage()
        // Rebuild so a hand-edited config.json or the toolbar shield shows up here.
        selectPane(currentPane)
        showWindow(nil)
        window?.center()
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

    private func buildGeneral(in host: NSView) {
        let b = PaneBuilder(host: host, width: Self.windowWidth)

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

        b.spacer(10)
        b.note("New tabs open the homepage when one is set. Blank keeps the native start page.")
    }

    private func buildTabs(in host: NSView) {
        let b = PaneBuilder(host: host, width: Self.windowWidth)

        let sleep = NSPopUpButton(frame: .zero, pullsDown: false)
        sleep.menu = hibernateMenu()
        syncHibernate(sleep)
        sleep.target = self
        sleep.action = #selector(chooseHibernate(_:))
        b.row("Sleep background tabs:", sleep)
        hibernatePopup = sleep

        let pressure = NSButton(checkboxWithTitle: "Sleep them immediately when memory is tight",
                                target: self, action: #selector(toggleMemoryPressure(_:)))
        pressure.state = Config.shared.hibernateOnMemoryPressure ? .on : .off
        b.row("Low memory:", pressure)

        let pill = NSButton(checkboxWithTitle: "Show memory usage in the toolbar",
                            target: self, action: #selector(toggleMemoryPill(_:)))
        pill.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        b.row("Memory readout:", pill)

        b.spacer(4)
        b.note("Sleeping destroys a tab's web process and keeps its scroll position and history, "
               + "so a background tab costs a couple of KB instead of ~100 MB.")
    }

    private func buildSearch(in host: NSView) {
        let b = PaneBuilder(host: host, width: Self.windowWidth)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        buildEngineMenu(into: popup)
        popup.target = self
        popup.action = #selector(selectEngine(_:))
        b.row("Search engine:", popup)
        enginePopup = popup

        b.spacer(4)
        b.note("Engines marked Requires sign-in open their sign-in page first. "
               + "The choice applies to the very next search.")
    }

    private func buildPrivacy(in host: NSView) {
        let b = PaneBuilder(host: host, width: Self.windowWidth)

        let block = NSButton(checkboxWithTitle: "Block ads and trackers",
                             target: self, action: #selector(toggleBlocking(_:)))
        block.state = Config.shared.blockAdsAndTrackers ? .on : .off
        b.row("Website tracking:", block)

        b.spacer(2)
        b.note("Open tabs reload so the network rules take effect.")

        let data = NSButton(title: "Manage Website Data…", target: self,
                            action: #selector(manageWebsiteData(_:)))
        data.bezelStyle = .rounded
        b.row("Website data:", data, height: 26)

        b.spacer(2)
        b.note("Clearing removes cookies and cached files, and signs you out of sites.")
    }

    private func buildDeveloper(in host: NSView) {
        let b = PaneBuilder(host: host, width: Self.windowWidth)

        let tools = NSButton(checkboxWithTitle: "Enable Inspect Element on pages",
                             target: self, action: #selector(toggleDeveloperTools(_:)))
        tools.state = Config.shared.enableDeveloperTools ? .on : .off
        b.row("Web Inspector:", tools)

        b.spacer(4)
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

    /// One dropdown for every engine. Groups appear as disabled separator headers,
    /// so the full catalog fits in a single control instead of a scrolling list.
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
                guard let idx = SearchEngines.all.firstIndex(where: { $0.id == engine.id }) else { continue }
                let item = NSMenuItem(title: engine.name, action: nil, keyEquivalent: "")
                item.tag = idx
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
        if let idx = SearchEngines.all.firstIndex(where: { $0.id == Config.shared.searchEngine }),
           let item = popup.itemArray.first(where: { $0.tag == idx }) {
            popup.select(item)
        } else {
            // A hand-written template with no matching engine: nothing selected.
            popup.select(nil)
        }
    }

    @objc private func selectEngine(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              SearchEngines.all.indices.contains(item.tag) else { return }
        // Persists and takes effect on the very next search: resolve() reads the
        // live setting, so no window needs to reload or relayout.
        Config.shared.setSearchEngine(SearchEngines.all[item.tag].id)
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

    private var labelRight: CGFloat { 296 }
    private var controlX: CGFloat { 308 }
    private var controlWidth: CGFloat { width - controlX - 24 }

    init(host: NSView, width: CGFloat) {
        self.host = host
        self.width = width
    }

    func row(_ text: String, _ control: NSView, height: CGFloat = 24) {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 24, y: y + (height - 17) / 2, width: labelRight - 24, height: 17)
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
        y += h + 8
    }

    func spacer(_ h: CGFloat) { y += h }
}
