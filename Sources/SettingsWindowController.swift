import AppKit

/// The ⌘, window. Built on first use and reused afterwards, so there is only ever one
/// instance; it is an ordinary window (not a panel), so it never floats above anything.
final class SettingsWindowController: NSWindowController {

    private let showMemoryPillBox = NSButton(
        checkboxWithTitle: "Show memory usage in the toolbar", target: nil, action: nil)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 104),
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 104))

        showMemoryPillBox.target = self
        showMemoryPillBox.action = #selector(toggleShowMemoryPill(_:))
        showMemoryPillBox.state = Settings.shared
            .showMemoryPill(jsonValue: Config.shared.showMemoryReadout) ? .on : .off
        showMemoryPillBox.frame = NSRect(x: 20, y: 60, width: 380, height: 20)
        content.addSubview(showMemoryPillBox)

        let note = NSTextField(labelWithString:
            "Hides the total-memory pill on the right of the toolbar. Takes effect immediately.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 22, y: 34, width: 376, height: 16)
        content.addSubview(note)

        w.contentView = content
        w.center()
    }

    /// Brings the window up for ⌘, (and for the menu item, which uses the same action).
    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleShowMemoryPill(_ sender: NSButton) {
        Settings.shared.setShowMemoryPill(sender.state == .on)
        AppDelegate.shared?.settingsDidChange()
    }
}
