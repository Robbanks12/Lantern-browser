import AppKit
import WebKit

/// The three window buttons, hand-drawn for full screen.
///
/// The native buttons live in AppKit's theme frame. Reparenting them into the
/// toolbar is unsupported, and removing them from that frame leaves the window with
/// no traffic lights at all after full screen ends. These are our own views, wired
/// to the window's standard actions; the native ones are only hidden and restored.
final class FullScreenTrafficLights: NSView {
    static let preferredWidth: CGFloat = 62

    var onClose: (() -> Void)?
    var onZoom: (() -> Void)?

    private let diameter: CGFloat = 12
    private let gap: CGFloat = 8
    private var hovered: Int?
    private var trackingAreaRef: NSTrackingArea?
    private var menuWorkItem: DispatchWorkItem?
    private var menuShownForHover = false

    private var isMenuOpen = false
    private var activeMenu: NSMenu?
    private var menuWatchdog: Timer?
    private var menuAllowedScreenRect: NSRect = .zero

    private lazy var zoomMenu: NSMenu = makeZoomMenu()

    deinit {
        menuWorkItem?.cancel()
        menuWatchdog?.invalidate()
    }

    override var isFlipped: Bool { true }

    private func circle(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (diameter + gap),
               y: (bounds.height - diameter) / 2,
               width: diameter,
               height: diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        (0..<3).first { circle($0).insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func activate(_ index: Int) {
        switch index {
        case 0: onClose?()
        case 2: onZoom?()
        default: break
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        // While the menu tracks the pointer this view stops receiving mouse events;
        // the menu watchdog owns the transition until it closes.
        guard !isMenuOpen else { return }
        hovered = nil
        cancelMenuTimer()
        menuShownForHover = false
        needsDisplay = true
    }

    private func updateHover(_ event: NSEvent) {
        guard !isMenuOpen else { return }
        let raw = index(at: convert(event.locationInWindow, from: nil))
        // The yellow button is disabled in full screen: it gets no hover glyph and
        // no highlight, just like the native control.
        let next = raw == 1 ? nil : raw
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true

        cancelMenuTimer()
        if next != 2 { menuShownForHover = false }
        guard next == 2, !menuShownForHover else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == 2, !self.menuShownForHover,
                  self.window?.isKeyWindow == true else { return }
            self.menuWorkItem = nil
            self.menuShownForHover = true
            self.showZoomMenu()
        }
        menuWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func cancelMenuTimer() {
        menuWorkItem?.cancel()
        menuWorkItem = nil
    }

    /// In full screen macOS shows the reduced green-button menu: exit, plus the two
    /// tiling choices disabled because the window is already filling the screen.
    /// The larger Move & Resize / Fill & Arrange panel belongs to windowed mode,
    /// where this view is not used.
    private func makeZoomMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let exit = NSMenuItem(title: "Exit Full Screen",
                              action: #selector(exitFullScreen),
                              keyEquivalent: "")
        exit.target = self
        exit.isEnabled = true
        exit.image = menuImage("arrow.down.right.and.arrow.up.left")
        menu.addItem(exit)

        menu.addItem(.separator())

        let left = NSMenuItem(title: "Tile Window to Left of Screen",
                              action: nil, keyEquivalent: "")
        left.isEnabled = false
        left.image = menuImage("rectangle.lefthalf.inset.filled")
        menu.addItem(left)

        let right = NSMenuItem(title: "Tile Window to Right of Screen",
                               action: nil, keyEquivalent: "")
        right.isEnabled = false
        right.image = menuImage("rectangle.righthalf.inset.filled")
        menu.addItem(right)

        return menu
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 14, height: 14)
        return image
    }

    /// Show the cached menu as one owned session. `popUp` blocks while the menu
    /// tracks, so everything after it is cleanup for every close path: selection,
    /// Escape, click-away, or the watchdog cancelling it when the pointer leaves.
    private func showZoomMenu() {
        guard !isMenuOpen, let win = window else { return }
        isMenuOpen = true
        hovered = 2
        needsDisplay = true

        let menu = zoomMenu
        let anchor = NSPoint(x: circle(2).minX, y: circle(2).maxY + 3)
        let screenAnchor = win.convertToScreen(NSRect(origin: convert(anchor, to: nil),
                                                      size: .zero)).origin
        let buttonRect = win.convertToScreen(convert(circle(2), to: nil))
        var menuSize = menu.size
        if menuSize.width < 1 || menuSize.height < 1 {
            menuSize = NSSize(width: 260, height: 170)
        }
        let menuRect = NSRect(x: screenAnchor.x,
                              y: screenAnchor.y - menuSize.height,
                              width: menuSize.width,
                              height: menuSize.height)
        menuAllowedScreenRect = buttonRect.union(menuRect).insetBy(dx: -12, dy: -10)

        activeMenu = menu
        startMenuWatchdog()
        menu.popUp(positioning: nil, at: anchor, in: self)
        stopMenuWatchdog()
        activeMenu = nil
        isMenuOpen = false
        recomputeHoverAfterMenu()
    }

    private func startMenuWatchdog() {
        stopMenuWatchdog()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.menuWatchdogTick()
        }
        // Menu tracking runs in the event-tracking mode, which common modes include.
        RunLoop.main.add(timer, forMode: .common)
        menuWatchdog = timer
    }

    private func stopMenuWatchdog() {
        menuWatchdog?.invalidate()
        menuWatchdog = nil
    }

    private func menuWatchdogTick() {
        guard isMenuOpen, let menu = activeMenu else {
            stopMenuWatchdog()
            return
        }
        if !menuAllowedScreenRect.contains(NSEvent.mouseLocation) {
            // Stop before cancelling so a close that takes a moment cannot tick again.
            stopMenuWatchdog()
            menu.cancelTracking()
        }
    }

    private func recomputeHoverAfterMenu() {
        menuShownForHover = false
        guard let win = window else {
            hovered = nil
            needsDisplay = true
            return
        }
        let mouse = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        let raw = index(at: mouse)
        let next = raw == 1 ? nil : raw
        hovered = next
        menuShownForHover = next == 2
        needsDisplay = true
    }

    /// Close the menu if full screen ends while it is open.
    func dismissMenu() {
        cancelMenuTimer()
        activeMenu?.cancelTracking()
    }

    /// The pointer was somewhere else before this view appeared, so start clean.
    func resetHover() {
        cancelMenuTimer()
        hovered = nil
        menuShownForHover = false
        needsDisplay = true
    }

    @objc private func exitFullScreen() {
        onZoom?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isMenuOpen,
              let hit = index(at: convert(event.locationInWindow, from: nil)) else { return }
        activate(hit)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Yellow is dimmed in native full screen because minimizing is unavailable.
        let colours: [NSColor] = [.systemRed,
                                  NSColor.systemGray.withAlphaComponent(0.45),
                                  .systemGreen]
        for i in 0..<3 {
            let rect = circle(i)
            let fill = hovered == i
                ? (colours[i].blended(withFraction: 0.12, of: .white) ?? colours[i])
                : colours[i]
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()

            guard hovered == i else { continue }
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let glyph = NSBezierPath()
            glyph.lineWidth = 1.2
            glyph.lineCapStyle = .round
            switch i {
            case 0:
                let inset = rect.insetBy(dx: 3.8, dy: 3.8)
                glyph.move(to: NSPoint(x: inset.minX, y: inset.minY))
                glyph.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
                glyph.move(to: NSPoint(x: inset.maxX, y: inset.minY))
                glyph.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            case 2:
                // The exit-full-screen glyph: two diagonal arrows pointing inward.
                let inset = rect.insetBy(dx: 3.2, dy: 3.2)
                let mid = NSPoint(x: rect.midX, y: rect.midY)
                let reach: CGFloat = 1.2
                let head: CGFloat = 2.5

                glyph.move(to: NSPoint(x: inset.minX, y: inset.minY))
                glyph.line(to: NSPoint(x: mid.x - reach, y: mid.y - reach))
                glyph.move(to: NSPoint(x: mid.x - head, y: mid.y - reach))
                glyph.line(to: NSPoint(x: mid.x - reach, y: mid.y - reach))
                glyph.line(to: NSPoint(x: mid.x - reach, y: mid.y - head))

                glyph.move(to: NSPoint(x: inset.maxX, y: inset.maxY))
                glyph.line(to: NSPoint(x: mid.x + reach, y: mid.y + reach))
                glyph.move(to: NSPoint(x: mid.x + head, y: mid.y + reach))
                glyph.line(to: NSPoint(x: mid.x + reach, y: mid.y + reach))
                glyph.line(to: NSPoint(x: mid.x + reach, y: mid.y + head))
            default:
                break
            }
            glyph.stroke()
        }
    }
}

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

        // 1. Hide the native buttons and show ours. Only isHidden is touched: the
        //    buttons themselves stay where AppKit put them.
        hideNativeTrafficLights(in: win)
        fullScreenTrafficLights.isHidden = false
        fullScreenTrafficLights.resetHover()

        // 2. An empty spacer sets the height of AppKit's full-screen titlebar
        //    window. Together with the native strip AppKit adds, it is sized to the
        //    chrome, so the chrome can fill the titlebar instead of sitting below it.
        //    The accessory cannot pin the chrome itself: the chrome is in the
        //    titlebar window, not the accessory, so there is deliberately no
        //    fullScreenMinHeight pin here.
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: 0))
        spacer.autoresizingMask = [.width]
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = spacer
        fullScreenAccessory = accessory
        fullScreenSpacer = spacer

        // 3. Keep titlebar transparent to match windowed mode (Fixes dark theme/outlines)
        win.titlebarAppearsTransparent = true
        chromeBackground.isHidden = false // Ensure background is visible

        win.addTitlebarAccessoryViewController(accessory)

        // 4. The titlebar window is the native strip plus the spacer. If AppKit
        //    has not created it yet, unwind the accessory and leave the chrome in
        //    `root`; the window then keeps its windowed chrome instead of losing it.
        guard let tw = spacer.window, let cv = tw.contentView else {
            if let index = win.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                win.removeTitlebarAccessoryViewController(at: index)
            }
            fullScreenAccessory = nil
            fullScreenSpacer = nil
            fullScreenTitlebarStrip = 0
            fullScreenTrafficLights.dismissMenu()
            fullScreenTrafficLights.isHidden = true
            restoreNativeTrafficLights(in: win)
            layoutChrome()
            return
        }

        // AppKit does not expose the native strip height; measure it from the
        // empty spacer's titlebar window before sizing the spacer to the chrome.
        fullScreenTitlebarStrip = max(0, cv.bounds.height - spacer.frame.height)
        chromeHost.removeFromSuperview()
        resizeFullScreenAccessory(to: chromeHeight + findRowHeight)
        cv.addSubview(chromeHost)
        chromeHost.frame = cv.bounds

        // AppKit's private autofill heuristic scans the key-view loop when a
        // text field gets focus. The chrome was in the main window's loop a
        // moment ago; without this rebuild it can follow stale cross-window
        // links and hang the app for minutes. Do not remove this line.
        tw.recalculateKeyViewLoop()

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
        fullScreenSpacer = nil
        fullScreenTitlebarStrip = 0

        if let index = win.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            win.removeTitlebarAccessoryViewController(at: index)
        }
        chromeHost.removeFromSuperview()
        root.addSubview(chromeHost)
        // Put the chrome back into the main window's loop. The matching rebuild
        // in install keeps AppKit's autofill heuristic from following stale
        // cross-window links.
        win.recalculateKeyViewLoop()

        fullScreenTrafficLights.dismissMenu()
        fullScreenTrafficLights.isHidden = true
        restoreNativeTrafficLights(in: win)

        win.titlebarAppearsTransparent = true
        layoutChrome()
    }

    @objc private func chromeHostFrameDidChange(_ notification: Notification) {
        guard fullScreenAccessory != nil,
              abs(chromeHost.bounds.width - toolbarRow.frame.width) > 0.5 else { return }
        layoutChrome()
    }

    /// Sizes the spacer, and the chrome host inside the titlebar window, to the
    /// full-screen chrome height.
    func resizeFullScreenAccessory(to height: CGFloat) {
        guard fullScreenAccessory != nil, let spacer = fullScreenSpacer else { return }
        let accessoryHeight = max(0, height - fullScreenTitlebarStrip)
        if abs(spacer.frame.height - accessoryHeight) > 0.5 {
            spacer.setFrameSize(NSSize(width: spacer.frame.width, height: accessoryHeight))
        }
        if let host = chromeHost.superview, !NSEqualRects(chromeHost.frame, host.bounds) {
            chromeHost.frame = host.bounds
        }
    }

    // MARK: - Native buttons

    private func hideNativeTrafficLights(in window: NSWindow) {
        // The titlebar accessory is outside the window's AX children, but these
        // standard buttons are in it. Give them the names of the drawn controls
        // so VoiceOver exposes Close, Minimize (already disabled in full screen)
        // and Exit Full Screen with the right actions.
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let labels: [NSWindow.ButtonType: (label: String, help: String)] = [
            .closeButton: ("Close", "Close this window"),
            .miniaturizeButton: ("Minimize", "Unavailable in full screen"),
            .zoomButton: ("Exit Full Screen", "Exit full screen"),
        ]
        nativeTrafficLightStates = types.compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let wasHidden = button.isHidden
            let oldLabel = button.accessibilityLabel()
            let oldHelp = button.accessibilityHelp()
            button.isHidden = true
            if let info = labels[type] {
                button.setAccessibilityLabel(info.label)
                button.setAccessibilityHelp(info.help)
            }
            return (type, wasHidden, oldLabel, oldHelp)
        }
    }

    private func restoreNativeTrafficLights(in window: NSWindow) {
        for state in nativeTrafficLightStates {
            guard let button = window.standardWindowButton(state.type) else { continue }
            button.isHidden = state.wasHidden
            button.setAccessibilityLabel(state.label)
            button.setAccessibilityHelp(state.help)
        }
        nativeTrafficLightStates.removeAll(keepingCapacity: true)
    }
}
