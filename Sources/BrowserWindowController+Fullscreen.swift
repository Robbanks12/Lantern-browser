import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Full screen

    func windowDidEnterFullScreen(_ notification: Notification) {
        installFullScreenAccessory()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        removeFullScreenAccessory()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        removeFullScreenAccessory()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        installFullScreenAccessory()
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }

    private func installFullScreenAccessory() {
        guard fullScreenAccessory == nil, let win = window else { return }

        // 1. Hide native traffic lights and draw custom ones
        installFullscreenTrafficLights(in: win)

        // 2. Setup accessory
        chromeHost.removeFromSuperview()
        chromeHost.frame = NSRect(x: 0, y: 0, width: root.bounds.width,
                                  height: chromeHeight + findRowHeight)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 0
        accessory.view = chromeHost
        fullScreenAccessory = accessory

        // 3. Keep titlebar transparent to match windowed mode (Fixes dark theme/outlines)
        win.titlebarAppearsTransparent = true
        chromeBackground.isHidden = false // Ensure background is visible
        
        win.addTitlebarAccessoryViewController(accessory)

        chromeHost.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(chromeHostFrameDidChange),
                                               name: NSView.frameDidChangeNotification,
                                               object: chromeHost)
        layoutChrome()
    }

    private func removeFullScreenAccessory() {
        guard let accessory = fullScreenAccessory, let win = window else { return }

        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                  object: chromeHost)
        chromeHost.postsFrameChangedNotifications = false
        fullScreenAccessory = nil

        if let index = win.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            win.removeTitlebarAccessoryViewController(at: index)
        }
        chromeHost.removeFromSuperview()
        root.addSubview(chromeHost)
        
        // Restore native traffic lights
        restoreNativeTrafficLights(in: win)
        
        win.titlebarAppearsTransparent = true
        layoutChrome()
    }

    @objc private func chromeHostFrameDidChange(_ notification: Notification) {
        guard fullScreenAccessory != nil,
              abs(chromeHost.bounds.width - toolbarRow.frame.width) > 0.5 else { return }
        layoutChrome()
    }

    func resizeFullScreenAccessory(to height: CGFloat) {
        guard fullScreenAccessory != nil else { return }
        if abs(chromeHost.frame.height - height) > 0.5 {
            chromeHost.setFrameSize(NSSize(width: chromeHost.frame.width, height: height))
        }
        updateChromePin()
    }

    func updateChromePin() {
        guard let accessory = fullScreenAccessory else { return }
        let minHeight: CGFloat = (isEditingURL || findVisible) ? chromeHost.frame.height : 0
        if accessory.fullScreenMinHeight != minHeight { accessory.fullScreenMinHeight = minHeight }
    }

    // MARK: - Traffic Light Helpers
    private func installFullscreenTrafficLights(in window: NSWindow) {
        removeFullscreenTrafficLights()
        
        let buttonTypes: [(NSWindow.ButtonType, Selector)] = [
            (.closeButton, #selector(NSWindow.performClose(_:))),
            (.miniaturizeButton, #selector(NSWindow.performMiniaturize(_:))),
            (.zoomButton, #selector(NSWindow.toggleFullScreen(_:)))
        ]

        nativeTrafficLightStates = buttonTypes.compactMap { type, _ in
            guard let button = window.standardWindowButton(type) else { return nil }
            return (type, button.isHidden)
        }

        let rowHeight = toolbarRow.bounds.height > 0 ? toolbarRow.bounds.height : 40
        var x: CGFloat = 9
        
        for (type, action) in buttonTypes {
            guard let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
            button.target = window
            button.action = action
            button.isHidden = true // Hide native

            let size = button.frame.size
            button.frame = NSRect(x: x, y: (rowHeight - size.height) / 2, width: size.width, height: size.height)
            toolbarRow.addSubview(button)
            fullscreenTrafficLights.append(button)
            x += size.width + 9
        }
    }

    private func removeFullscreenTrafficLights() {
        fullscreenTrafficLights.forEach { $0.removeFromSuperview() }
        fullscreenTrafficLights.removeAll(keepingCapacity: true)
    }

    private func restoreNativeTrafficLights(in window: NSWindow) {
        nativeTrafficLightStates.forEach {
            window.standardWindowButton($0.type)?.isHidden = $0.wasHidden
        }
        nativeTrafficLightStates.removeAll(keepingCapacity: true)
        removeFullscreenTrafficLights()
    }
}
