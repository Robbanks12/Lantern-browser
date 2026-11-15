import AppKit

/// The ⌘, window. Built on first use and reused afterwards, so there is only ever one
/// instance; it is an ordinary window (not a panel), so it never floats above anything.
///
/// Every key in config.json has a control here. Each control writes straight through
/// to Config and saves, then notifies the app where the change can apply live; the
/// notes say when something waits for the next launch or the next tab instead.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let homepageField = NSTextField(frame: .zero)
    private let restoreSessionBox = NSButton(
        checkboxWithTitle: "Restore session on launch", target: nil, action: nil)
    private let blockAdsBox = NSButton(
        checkboxWithTitle: "Block ads and trackers", target: nil, action: nil)
    private let developerToolsBox = NSButton(
        checkboxWithTitle: "Enable developer tools", target: nil, action: nil)
    private let memoryPressureBox = NSButton(
        checkboxWithTitle: "Sleep tabs on memory pressure", target: nil, action: nil)
    private let memoryPillBox = NSButton(
        checkboxWithTitle: "Show memory usage in the toolbar", target: nil, action: nil)

    /// One dropdown for every engine. Groups appear as disabled separator headers,
    /// so the full catalog fits in a single control instead of a scrolling list.
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hibernatePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        // The controller keeps this window alive and shows it again on the next ⌘,.
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.delegate = self
        buildContent()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let w = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 610))

        // MARK: General

        let generalHeader = Self.header("General")
        generalHeader.frame = NSRect(x: 20, y: 564, width: 440, height: 20)
        content.addSubview(generalHeader)

        let homepageLabel = NSTextField(labelWithString: "Homepage")
        homepageLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        homepageLabel.frame = NSRect(x: 20, y: 540, width: 440, height: 18)
        content.addSubview(homepageLabel)

        homepageField.target = self
        homepageField.action = #selector(commitHomepage(_:))
        homepageField.placeholderString = "about:blank"
        homepageField.frame = NSRect(x: 20, y: 512, width: 440, height: 24)
        content.addSubview(homepageField)

        let homepageNote = Self.note("New tabs open this page. Blank means the start page.")
        homepageNote.frame = NSRect(x: 22, y: 494, width: 436, height: 14)
        content.addSubview(homepageNote)

        restoreSessionBox.target = self
        restoreSessionBox.action = #selector(toggleRestoreSession(_:))
        restoreSessionBox.toolTip = "Takes effect on the next launch."
        restoreSessionBox.frame = NSRect(x: 20, y: 464, width: 440, height: 20)
        content.addSubview(restoreSessionBox)

        Self.divider(atY: 444, in: content)

        // MARK: Search engine

        let engineHeader = Self.header("Search Engine")
        engineHeader.frame = NSRect(x: 20, y: 414, width: 440, height: 20)
        content.addSubview(engineHeader)

        let engineNote = Self.note("Takes effect immediately. Engines marked as such need sign-in.")
        engineNote.frame = NSRect(x: 22, y: 396, width: 436, height: 14)
        content.addSubview(engineNote)

        enginePopup.target = self
        enginePopup.action = #selector(selectEngine(_:))
        enginePopup.frame = NSRect(x: 20, y: 364, width: 440, height: 26)
        content.addSubview(enginePopup)
        rebuildEngineMenu()

        Self.divider(atY: 344, in: content)

        // MARK: Privacy

        let privacyHeader = Self.header("Privacy")
        privacyHeader.frame = NSRect(x: 20, y: 314, width: 440, height: 20)
        content.addSubview(privacyHeader)

        blockAdsBox.target = self
        blockAdsBox.action = #selector(toggleBlocking(_:))
        blockAdsBox.frame = NSRect(x: 20, y: 288, width: 440, height: 20)
        content.addSubview(blockAdsBox)

        let blockNote = Self.note("Open tabs reload to apply the change.")
        blockNote.frame = NSRect(x: 22, y: 270, width: 436, height: 14)
        content.addSubview(blockNote)

        developerToolsBox.target = self
        developerToolsBox.action = #selector(toggleDeveloperTools(_:))
        developerToolsBox.frame = NSRect(x: 20, y: 242, width: 440, height: 20)
        content.addSubview(developerToolsBox)

        let devtoolsNote = Self.note("Applies to tabs opened afterwards. Adds Inspect Element.")
        devtoolsNote.frame = NSRect(x: 22, y: 224, width: 436, height: 14)
        content.addSubview(devtoolsNote)

        Self.divider(atY: 204, in: content)

        // MARK: Performance

        let performanceHeader = Self.header("Performance")
        performanceHeader.frame = NSRect(x: 20, y: 174, width: 440, height: 20)
        content.addSubview(performanceHeader)

        let hibernateLabel = NSTextField(labelWithString: "Sleep background tabs")
        hibernateLabel.font = .systemFont(ofSize: 13)
        hibernateLabel.frame = NSRect(x: 20, y: 144, width: 220, height: 22)
        content.addSubview(hibernateLabel)

        hibernatePopup.target = self
        hibernatePopup.action = #selector(chooseHibernate(_:))
        hibernatePopup.frame = NSRect(x: 250, y: 142, width: 210, height: 26)
        content.addSubview(hibernatePopup)
        rebuildHibernateMenu()

        memoryPressureBox.target = self
        memoryPressureBox.action = #selector(toggleMemoryPressure(_:))
        memoryPressureBox.frame = NSRect(x: 20, y: 114, width: 440, height: 20)
        content.addSubview(memoryPressureBox)

        Self.divider(atY: 94, in: content)

        // MARK: Appearance

        let appearanceHeader = Self.header("Appearance")
        appearanceHeader.frame = NSRect(x: 20, y: 64, width: 440, height: 20)
        content.addSubview(appearanceHeader)

        memoryPillBox.target = self
        memoryPillBox.action = #selector(toggleMemoryPill(_:))
        memoryPillBox.frame = NSRect(x: 20, y: 38, width: 440, height: 20)
        content.addSubview(memoryPillBox)

        let memoryNote = Self.note(
            "Hides the total-memory pill on the right of the toolbar. Takes effect immediately.")
        memoryNote.frame = NSRect(x: 22, y: 20, width: 436, height: 14)
        content.addSubview(memoryNote)

        w.contentView = content
        w.center()
    }

    private static func header(_ text: String) -> NSTextField {
        let h = NSTextField(labelWithString: text)
        h.font = .systemFont(ofSize: 13, weight: .semibold)
        return h
    }

    private static func note(_ text: String) -> NSTextField {
        let n = NSTextField(labelWithString: text)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        return n
    }

    private static func divider(atY y: CGFloat, in content: NSView) {
        let d = NSBox(frame: NSRect(x: 20, y: y, width: 440, height: 8))
        d.boxType = .separator
        content.addSubview(d)
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        syncAllControls()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A typed-but-uncommitted homepage is flushed on close, so typing a URL and
    /// clicking the red dot still saves it.
    func windowWillClose(_ notification: Notification) {
        if homepageField.window?.firstResponder === homepageField.currentEditor() {
            commitHomepage(homepageField)
        }
    }

    private func syncAllControls() {
        homepageField.stringValue = Config.shared.homepage
        restoreSessionBox.state = Config.shared.restoreSessionOnLaunch ? .on : .off
        blockAdsBox.state = Config.shared.blockAdsAndTrackers ? .on : .off
        developerToolsBox.state = Config.shared.enableDeveloperTools ? .on : .off
        memoryPressureBox.state = Config.shared.hibernateOnMemoryPressure ? .on : .off
        memoryPillBox.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        syncEnginePopup()
        syncHibernatePopup()
    }

    // MARK: - General

    @objc private func commitHomepage(_ sender: NSTextField) {
        let raw = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            Config.shared.homepage = "about:blank"
        } else if Self.isHomepageValue(raw) {
            Config.shared.homepage = raw
        } else {
            NSBeep()
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

    @objc private func toggleRestoreSession(_ sender: NSButton) {
        // Read on the next launch, so there is nothing live to notify.
        Config.shared.restoreSessionOnLaunch = (sender.state == .on)
        Config.shared.save()
    }

    // MARK: - Privacy

    @objc private func toggleBlocking(_ sender: NSButton) {
        Config.shared.blockAdsAndTrackers = (sender.state == .on)
        Config.shared.save()
        AppDelegate.shared?.blockingSettingChanged()
    }

    @objc private func toggleDeveloperTools(_ sender: NSButton) {
        // Read when each web view is created, so already-open tabs are untouched.
        Config.shared.enableDeveloperTools = (sender.state == .on)
        Config.shared.save()
    }

    // MARK: - Performance

    private func rebuildHibernateMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, minutes) in [("Never", 0), ("After 1 minute", 1), ("After 5 minutes", 5),
                                 ("After 15 minutes", 15), ("After 30 minutes", 30)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = minutes
            menu.addItem(item)
        }
        hibernatePopup.menu = menu
        syncHibernatePopup()
    }

    @objc private func chooseHibernate(_ sender: NSPopUpButton) {
        Config.shared.hibernateAfterMinutes = Double(sender.selectedTag())
        Config.shared.save()
        // applySettings restarts the timer with the new interval.
        AppDelegate.shared?.settingsDidChange()
    }

    private func syncHibernatePopup() {
        let minutes = Int(Config.shared.hibernateAfterMinutes)
        if hibernatePopup.menu?.items.contains(where: { $0.tag == minutes }) == true {
            hibernatePopup.selectItem(withTag: minutes)
        } else {
            // A hand-written interval with no matching row: nothing selected.
            hibernatePopup.select(nil)
        }
    }

    @objc private func toggleMemoryPressure(_ sender: NSButton) {
        Config.shared.hibernateOnMemoryPressure = (sender.state == .on)
        Config.shared.save()
        // applySettings starts or stops the watchdog to match.
        AppDelegate.shared?.settingsDidChange()
    }

    // MARK: - Appearance

    @objc private func toggleMemoryPill(_ sender: NSButton) {
        Settings.shared.setShowMemoryPill(sender.state == .on)
        AppDelegate.shared?.settingsDidChange()
    }

    // MARK: - Search engine picker

    private func rebuildEngineMenu() {
        let menu = NSMenu()
        // Manual validation stays off: every engine item is always choosable, and
        // only the group headers are disabled separators.
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
        enginePopup.menu = menu
        syncEnginePopup()
    }

    @objc private func selectEngine(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              SearchEngines.all.indices.contains(item.tag) else { return }
        // Persists and takes effect on the very next search: resolve() reads the
        // live setting, so no window needs to reload or relayout.
        Config.shared.setSearchEngine(SearchEngines.all[item.tag].id)
    }

    private func syncEnginePopup() {
        if let idx = SearchEngines.all.firstIndex(where: { $0.id == Config.shared.searchEngine }),
           let item = enginePopup.itemArray.first(where: { $0.tag == idx }) {
            enginePopup.select(item)
        } else {
            // A hand-written template with no matching engine: nothing selected.
            enginePopup.select(nil)
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
