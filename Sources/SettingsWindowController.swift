import AppKit

/// The ⌘, window. Built on first use and reused afterwards, so there is only ever one
/// instance; it is an ordinary window (not a panel), so it never floats above anything.
///
/// Sections stack vertically and each owns its own controls, so future config
/// options slot in as new blocks without redesigning what is here.
final class SettingsWindowController: NSWindowController {

    private let showMemoryPillBox = NSButton(
        checkboxWithTitle: "Show memory usage in the toolbar", target: nil, action: nil)

    /// One dropdown for every engine. Groups appear as disabled separator headers,
    /// so the full catalog fits in a single control instead of a scrolling list.
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 190))

        showMemoryPillBox.target = self
        showMemoryPillBox.action = #selector(toggleShowMemoryPill(_:))
        showMemoryPillBox.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        showMemoryPillBox.frame = NSRect(x: 20, y: 150, width: 440, height: 20)
        content.addSubview(showMemoryPillBox)

        let note = NSTextField(labelWithString:
            "Hides the total-memory pill on the right of the toolbar. Takes effect immediately.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 22, y: 130, width: 436, height: 16)
        content.addSubview(note)

        let divider = NSBox(frame: NSRect(x: 20, y: 112, width: 440, height: 5))
        divider.boxType = .separator
        content.addSubview(divider)

        let engineLabel = NSTextField(labelWithString: "Search Engine")
        engineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        engineLabel.frame = NSRect(x: 20, y: 88, width: 440, height: 20)
        content.addSubview(engineLabel)

        let engineNote = NSTextField(labelWithString:
            "Takes effect immediately. Engines marked as such need sign-in.")
        engineNote.font = .systemFont(ofSize: 11)
        engineNote.textColor = .secondaryLabelColor
        engineNote.frame = NSRect(x: 22, y: 70, width: 436, height: 14)
        content.addSubview(engineNote)

        enginePopup.target = self
        enginePopup.action = #selector(selectEngine(_:))
        enginePopup.frame = NSRect(x: 20, y: 24, width: 440, height: 28)
        content.addSubview(enginePopup)
        rebuildEngineMenu()

        w.contentView = content
        w.center()
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        syncEnginePopup()
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
