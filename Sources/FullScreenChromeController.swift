import AppKit

/// The window controller side of the full-screen chrome. Kept as a protocol so
/// this file owns visibility and pointer tracking only: tab management, WebKit
/// lifecycle and chrome geometry stay where they already live.
protocol FullScreenChromeHost: AnyObject {
    /// Height the chrome collapses to, including the find row when it is up
    /// (76pt normally, 110pt with the find bar).
    var chromeBarHeight: CGFloat { get }
    /// Slide the chrome to its current visibility state. Called on the main thread.
    func applyChromeVisibility(animated: Bool, completion: (() -> Void)?)
    /// True while the chrome must stay on screen: field editing, a tab drag, a
    /// press in progress, a sheet.
    var isChromeInteractionPinned: Bool { get }
    /// Hand focus back to the page before a chrome that holds it disappears.
    func releaseChromeFocus()
}

/// Owns browser-chrome visibility in full screen.
///
/// Everything is event-driven: one permanent tracking area along the top edge of
/// the content root (the reveal zone), a second over the chrome while it is on
/// screen, and the window delegate's full-screen callbacks. No timers, no
/// polling, no event monitors, no extra windows — AppKit supplies every event
/// and the reveal lines up with the menu bar it also reveals.
/// `NSResponder` so the tracking-area callbacks are the documented overrides
/// rather than guessed selectors on a bare object.
final class FullScreenChromeController: NSResponder {

    private weak var host: FullScreenChromeHost?
    private weak var hostWindow: NSWindow?
    private weak var root: NSView?
    private weak var chrome: NSView?

    /// True between windowDidEnterFullScreen and windowDidExitFullScreen.
    private(set) var isFullScreen = false
    /// Whether the chrome currently occupies the top of the screen.
    private(set) var isChromeVisible = true

    private var revealArea: NSTrackingArea?
    private var chromeArea: NSTrackingArea?
    private var revealRect: NSRect = .zero

    /// Height of the permanent top-edge band that summons the chrome. As tall as
    /// the menu bar it reveals with, so the pointer reaches us before the system's
    /// own top-edge overlay can take the event stream. Tracking areas only observe,
    /// so the band never steals a click from the page.
    private static let revealZoneHeight: CGFloat = 24
    /// Matches the system's own full-screen chrome reveal.
    static let slideDuration: TimeInterval = 0.18

    init(window: NSWindow, root: NSView, chrome: NSView, host: FullScreenChromeHost) {
        self.hostWindow = window
        self.root = root
        self.chrome = chrome
        self.host = host
        super.init()
    }

    /// NSResponder declares this designated initializer as required. The controller
    /// is only ever built from a window, so there is no archive to decode.
    required init?(coder: NSCoder) { fatalError() }

    /// Where the chrome sits vertically: 0 while shown, -height while hidden so
    /// the web content can fill the window with nothing left behind.
    var chromeOffset: CGFloat {
        isChromeVisible ? 0 : -(host?.chromeBarHeight ?? 0)
    }

    // MARK: - Full-screen transitions

    /// Called from windowDidEnterFullScreen. The chrome starts out hidden, so the
    /// page is the only thing on screen until the pointer reaches the top edge.
    func windowDidEnterFullScreen() {
        isFullScreen = true
        isChromeVisible = false
        installRevealTracking()
        host?.applyChromeVisibility(animated: false, completion: nil)
        // The pointer may already be resting on the top edge (green button, then
        // moving up). AppKit will not synthesise a mouseEntered for an area that
        // appeared underneath it, so check once here.
        if pointerIsInRevealZone() { reveal(animated: false) }
    }

    func windowDidExitFullScreen() {
        isFullScreen = false
        isChromeVisible = true
        removeTrackingAreas()
        host?.applyChromeVisibility(animated: false, completion: nil)
    }

    /// Window teardown: drop the tracking areas so nothing outlives the window.
    func detach() {
        isFullScreen = false
        removeTrackingAreas()
    }

    /// Geometry changed (window resize, find bar shown/hidden). The reveal band
    /// spans the content root's width, so it is rebuilt when that width moves.
    func layoutDidChange() {
        guard isFullScreen, let root = root else { return }
        let rect = NSRect(x: 0, y: 0, width: max(1, root.bounds.width),
                          height: Self.revealZoneHeight)
        if rect != revealRect { installRevealTracking() }
    }

    // MARK: - Keyboard

    /// Cmd+L / Cmd+T / Cmd+F: the shortcut is about to focus a control that lives
    /// in the chrome, so the chrome has to be on screen before the focus lands.
    func revealForKeyboard() {
        guard isFullScreen else { return }
        reveal(animated: true)
    }

    // MARK: - Tracking areas

    /// Attached to the content root, not to the chrome, so it stays active no
    /// matter what the chrome is doing.
    private func installRevealTracking() {
        guard let root = root else { return }
        if let revealArea = revealArea { root.removeTrackingArea(revealArea) }
        let rect = NSRect(x: 0, y: 0, width: max(1, root.bounds.width),
                          height: Self.revealZoneHeight)
        // The root is flipped, so y 0 is the top edge of the app's content.
        let area = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        root.addTrackingArea(area)
        revealArea = area
        revealRect = rect
    }

    /// Only installed while the chrome is on screen: it exists to notice the
    /// pointer leaving the whole toolbar + tab strip band.
    private func installChromeTracking() {
        guard let chrome = chrome, chromeArea == nil else { return }
        let area = NSTrackingArea(rect: chrome.bounds,
                                  options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        chrome.addTrackingArea(area)
        chromeArea = area
    }

    private func removeChromeTracking() {
        if let chromeArea = chromeArea {
            chrome?.removeTrackingArea(chromeArea)
            self.chromeArea = nil
        }
    }

    private func removeTrackingAreas() {
        if let revealArea = revealArea {
            root?.removeTrackingArea(revealArea)
            self.revealArea = nil
        }
        revealRect = .zero
        removeChromeTracking()
    }

    // MARK: - Pointer

    override func mouseEntered(with event: NSEvent) {
        guard isFullScreen else { return }
        // Entering the chrome needs no work: being inside it is what keeps it up.
        if let revealArea = revealArea, event.trackingArea === revealArea {
            reveal(animated: true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isFullScreen, !isChromeVisible else { return }
        // Movement inside the band is a second chance to reveal, covering a band
        // that was installed under a pointer that never "entered" it.
        reveal(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isFullScreen else { return }
        // Leaving the top band must not hide anything: the pointer is on its way
        // down into the chrome it just revealed. Only the chrome's own exit —
        // leaving the entire toolbar + tab strip — can hide it.
        if let chromeArea = chromeArea, event.trackingArea === chromeArea {
            hideIfPossible()
        }
    }

    private func reveal(animated: Bool) {
        guard isFullScreen else { return }
        setChromeVisible(true, animated: animated)
    }

    /// Hide only when nothing else is going on and the pointer really is away.
    private func hideIfPossible() {
        guard isFullScreen, isChromeVisible else { return }
        guard let keyWindow = hostWindow, keyWindow.isKeyWindow else { return }
        // A context menu, a drag or a press in flight keeps the chrome where it is.
        if let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp { return }
        if host?.isChromeInteractionPinned == true { return }
        if pointerIsInsideChrome() || pointerIsInRevealZone() { return }
        setChromeVisible(false, animated: true)
    }

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        guard isFullScreen else { isChromeVisible = true; return }
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible
        if visible {
            installChromeTracking()
        } else {
            removeChromeTracking()
            host?.releaseChromeFocus()
        }
        host?.applyChromeVisibility(animated: animated) { [weak self] in
            self?.settlePointerState()
        }
    }

    /// Reconcile with where the pointer actually ended up once a transition has
    /// finished. Covers a tracking area installed while the pointer was already
    /// inside it, and a pointer that left while the chrome was still sliding.
    private func settlePointerState() {
        guard isFullScreen else { return }
        if isChromeVisible {
            if !pointerIsInsideChrome() && !pointerIsInRevealZone() {
                hideIfPossible()
            }
        } else if pointerIsInRevealZone() {
            reveal(animated: true)
        }
    }

    private func pointerLocationInRoot() -> NSPoint? {
        guard let root = root, let hostWindow = hostWindow else { return nil }
        return root.convert(hostWindow.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func pointerIsInsideChrome() -> Bool {
        guard let chrome = chrome, let p = pointerLocationInRoot() else { return true }
        return chrome.frame.contains(p)
    }

    private func pointerIsInRevealZone() -> Bool {
        guard let root = root, let p = pointerLocationInRoot() else { return false }
        return NSRect(x: 0, y: 0, width: root.bounds.width,
                      height: Self.revealZoneHeight).contains(p)
    }
}
