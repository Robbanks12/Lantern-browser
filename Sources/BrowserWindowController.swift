import AppKit
import WebKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One view holds the toolbar, tab strip and find row. Windowed, it overlays the
/// transparent titlebar inside `root`. In native full screen it fills AppKit's
/// titlebar window, covering the native strip so it sits flush under the menu bar.
final class BrowserChromeView: NSView {
    override var isFlipped: Bool { true }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {

    var tabs: [Tab] = []
    var activeIndex = 0
    let isPrivateWindow: Bool

    let root = FlippedView()
    let tabStrip = TabStripView()
    let tabScrollView = TabStripScrollView()
    let toolbarRow = FlippedView()
    let progressBar = ProgressBar()
    let webContainer = FlippedView()
    let startView = StartView()

    let chromeBackground = NSVisualEffectView()
    let hairline = HairlineView()
    /// The custom chrome overlays the transparent native titlebar in a single row.
    let chromeHost = BrowserChromeView()

    // MARK: Full-screen state
    /// Non-nil exactly while the window is in native full screen. Then an empty
    /// accessory sizes AppKit's titlebar window and `chromeHost` fills that window,
    /// not `root`, so it moves with the menu bar.
    var fullScreenAccessory: NSTitlebarAccessoryViewController?
    /// Empty spacer that sizes AppKit's full-screen titlebar window to the chrome.
    var fullScreenSpacer: NSView?
    /// Native titlebar height AppKit adds above the accessory in full screen.
    var fullScreenTitlebarStrip: CGFloat = 0

    /// Our own window buttons, drawn in full screen while the native ones hide.
    let fullScreenTrafficLights = FullScreenTrafficLights()
    var nativeTrafficLightStates: [(type: NSWindow.ButtonType, wasHidden: Bool, label: String?, help: String?)] = []

    var backButton: ToolbarButton!
    var forwardButton: ToolbarButton!
    var reloadButton: ToolbarButton!
    var shieldButton: ToolbarButton!
    var bookmarkButton: ToolbarButton!
    let urlBar = URLBar()
    var urlField: URLField { urlBar.field }
    let statusPill = StatusPill()
    let downloadIndicator = DownloadIndicator()
    var plusButton: ToolbarButton!
    /// Built on the first click and released when it closes, so a window that never
    /// opens the list pays nothing for it.
    var downloadsPopover: NSPopover?
    var downloadsPopoverClosedAt: Date?

    let findRow = BarBackgroundView()
    let findField = NSTextField()
    let findCount = NSTextField(labelWithString: "")
    var findPrevButton: ToolbarButton!
    var findNextButton: ToolbarButton!
    let findDoneButton = NSButton()
    var findVisible = false

    var hibernationTimer: Timer?
    var memoryTimer: Timer?
    var memoryPressureSource: DispatchSourceMemoryPressure?
    var sessionSaveScheduled = false
    var suppressCompletion = false
    var statusResetWork: DispatchWorkItem?
    var closedTabs: [SavedTab] = []

    let toolbarRowHeight: CGFloat = 40
    let tabRowHeight: CGFloat = 36

    /// Every input that places chrome. Progress and download ticks call
    /// layoutChrome constantly, so when none of these moved the frames are
    /// already right and the whole pass is skipped. Traffic-light geometry is
    /// deliberately absent: it only moves with the window, which moves the key.
    private struct ChromeLayoutKey: Equatable {
        var width: CGFloat
        var height: CGFloat
        var inTitlebar: Bool
        var findVisible: Bool
        var downloadHidden: Bool
        var pillHidden: Bool
        var pillWidth: CGFloat
    }
    private var lastChromeLayoutKey: ChromeLayoutKey?
    var chromeHeight: CGFloat { toolbarRowHeight + tabRowHeight }
    var findRowHeight: CGFloat { findVisible ? 34 : 0 }
    var isChromeReady = false

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    // MARK: - Init

    init(isPrivate: Bool = false) {
        self.isPrivateWindow = isPrivate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        w.title = isPrivate ? "Lantern Private" : "Lantern 🏮"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 520, height: 380)
        w.tabbingMode = .disallowed
        w.setFrameAutosaveName(isPrivate ? "LanternPrivateWindow" : "LanternWindow")
        w.backgroundColor = .windowBackgroundColor
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }

        buildChrome()
        w.contentView = root

        isChromeReady = true
        w.delegate = self
        layoutChrome()

        startHibernationTimer()
        startMemoryReadout()
        installMemoryPressureHandling()

        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }

        NotificationCenter.default.addObserver(self, selector: #selector(downloadsDidChange),
                                               name: .downloadsDidChange, object: Downloads.shared)
        updateDownloadIndicator()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Chrome

    private func buildChrome() {
        chromeBackground.material = .titlebar
        chromeBackground.blendingMode = .withinWindow
        chromeBackground.state = .followsWindowActiveState

        tabScrollView.documentView = tabStrip
        root.addSubview(webContainer)
        root.addSubview(chromeHost)
        chromeHost.addSubview(chromeBackground)
        chromeHost.addSubview(toolbarRow)
        chromeHost.addSubview(tabScrollView)
        chromeHost.addSubview(progressBar)
        chromeHost.addSubview(findRow)
        chromeHost.addSubview(hairline)

        tabStrip.delegate = self
        progressBar.active = false
        findRow.isHidden = true
        downloadIndicator.isHidden = true
        // Its own layer, so switching from the progress ring to the settled glyph
        // cannot leave the accent arc behind.
        downloadIndicator.wantsLayer = true
        downloadIndicator.onClick = { [weak self] in self?.toggleDownloadsPopover() }

        backButton = ToolbarButton(symbol: "chevron.backward", tip: "Back (\u{2318}[)",
                                   target: self, action: #selector(goBack))
        forwardButton = ToolbarButton(symbol: "chevron.forward", tip: "Forward (\u{2318}])",
                                      target: self, action: #selector(goForward))
        reloadButton = ToolbarButton(symbol: "arrow.clockwise", tip: "Reload (\u{2318}R)",
                                     target: self, action: #selector(reloadOrStop))
        bookmarkButton = ToolbarButton(symbol: "star", tip: "Bookmark (\u{2318}D)",
                                       target: self, action: #selector(toggleBookmark))
        bookmarkButton.onTint = .systemYellow
        shieldButton = ToolbarButton(symbol: "shield.lefthalf.filled",
                                     tip: "Ad & tracker blocking",
                                     target: self, action: #selector(toggleBlocking))

        plusButton = ToolbarButton(symbol: "plus", tip: "New Tab (\u{2318}T)",
                                   target: self, action: #selector(newTabFromToolbar))

        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldCommitted)
        urlField.onCancel = { [weak self] in
            guard let self else { return }
            self.urlField.stringValue = self.activeTab?.url
                .map { Store.displayForm($0.absoluteString) } ?? ""
            self.focusWebContent()
        }

        [backButton, forwardButton, urlBar, reloadButton, bookmarkButton,
         shieldButton, statusPill, downloadIndicator, plusButton].forEach { toolbarRow.addSubview($0!) }

        fullScreenTrafficLights.isHidden = true
        fullScreenTrafficLights.onClose = { [weak self] in self?.window?.performClose(nil) }
        fullScreenTrafficLights.onZoom = { [weak self] in self?.window?.toggleFullScreen(nil) }
        toolbarRow.addSubview(fullScreenTrafficLights)

        findField.placeholderString = "Find on page"
        findField.font = .systemFont(ofSize: 12)
        findField.bezelStyle = .roundedBezel
        findField.target = self
        findField.action = #selector(findNext)
        findCount.font = .systemFont(ofSize: 11)
        findCount.textColor = .secondaryLabelColor
        findPrevButton = ToolbarButton(symbol: "chevron.up", tip: "Previous (\u{2318}\u{21E7}G)",
                                       target: self, action: #selector(findPrevious), pointSize: 11)
        findNextButton = ToolbarButton(symbol: "chevron.down", tip: "Next (\u{2318}G)",
                                       target: self, action: #selector(findNext), pointSize: 11)
        findDoneButton.title = "Done"
        findDoneButton.bezelStyle = .rounded
        findDoneButton.controlSize = .small
        findDoneButton.target = self
        findDoneButton.action = #selector(hideFindBar)
        [findField, findPrevButton, findNextButton, findCount, findDoneButton]
            .forEach { findRow.addSubview($0!) }

        startView.onOpen = { [weak self] urlString in
            guard let self, let u = URL(string: urlString) else { return }
            self.activeTab?.load(u)
            self.refreshChrome()
            self.attachActiveTab()
        }
    }

    func layoutChrome() {
        guard isChromeReady,
              let win = window, win.frame.width > 0, win.frame.height > 0,
              root.bounds.width > 0,
              backButton != nil, forwardButton != nil, reloadButton != nil,
              bookmarkButton != nil, shieldButton != nil else { return }

        let b = root.bounds
        let inTitlebar = fullScreenAccessory != nil
        let toolbarWidth: CGFloat = inTitlebar
            ? (chromeHost.bounds.width > 0 ? chromeHost.bounds.width : b.width)
            : b.width
        let pillVisible = Config.shared.showMemoryReadout
        let pillWidth: CGFloat = pillVisible ? max(64, min(190, statusPill.fittingWidth)) : 0
        let downloadVisible = !downloadIndicator.isHidden

        let key = ChromeLayoutKey(width: b.width, height: b.height, inTitlebar: inTitlebar,
                                  findVisible: findVisible, downloadHidden: !downloadVisible,
                                  pillHidden: !pillVisible, pillWidth: pillWidth)
        guard key != lastChromeLayoutKey else { return }
        lastChromeLayoutKey = key

        // All of the geometry lives in ChromeLayout; this method only applies it.
        var input = ChromeLayout.Input()
        input.bounds = b
        input.toolbarWidth = toolbarWidth
        input.inTitlebar = inTitlebar
        input.toolbarRowHeight = toolbarRowHeight
        input.tabRowHeight = tabRowHeight
        input.findVisible = findVisible
        input.downloadVisible = downloadVisible
        input.pillVisible = pillVisible
        input.pillWidth = pillWidth
        input.contentLeft = chromeContentLeft(in: win, inTitlebar: inTitlebar)
        let frames = ChromeLayout.frames(input)

        if inTitlebar {
            resizeFullScreenAccessory(to: frames.visibleChromeHeight)
        } else {
            chromeHost.isHidden = false
            chromeHost.frame = frames.chromeHost
        }

        toolbarRow.frame = frames.toolbarRow
        tabScrollView.frame = frames.tabScrollView
        progressBar.frame = frames.progressBar
        findRow.frame = frames.findRow
        findRow.isHidden = !findVisible
        chromeBackground.frame = frames.chromeBackground
        hairline.frame = frames.hairline

        webContainer.frame = frames.webContainer
        startView.frame = webContainer.bounds
        activeTab?.webView?.frame = webContainer.bounds

        backButton.frame = frames.back
        forwardButton.frame = frames.forward
        reloadButton.frame = frames.reload
        urlBar.frame = frames.urlBar
        plusButton.frame = frames.plus
        downloadIndicator.frame = frames.download
        shieldButton.frame = frames.shield
        bookmarkButton.frame = frames.bookmark
        statusPill.isHidden = !pillVisible
        statusPill.frame = frames.pill

        findField.frame = frames.findField
        findPrevButton.frame = frames.findPrevious
        findNextButton.frame = frames.findNext
        findCount.frame = frames.findCount
        findDoneButton.frame = frames.findDone

        fullScreenTrafficLights.frame = NSRect(x: 9, y: 0,
                                              width: FullScreenTrafficLights.preferredWidth,
                                              height: toolbarRowHeight)
    }

    /// Left edge of the navigation buttons. Windowed, the native buttons are measured
    /// from their real frames; in full screen our own lights define the space.
    private func chromeContentLeft(in win: NSWindow, inTitlebar: Bool) -> CGFloat {
        if inTitlebar { return 9 + FullScreenTrafficLights.preferredWidth + 10 }
        let lightsRight = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { win.standardWindowButton($0) }
            .map { root.convert($0.bounds, from: $0).maxX }
            .max() ?? 70
        return lightsRight + 10
    }

    func windowDidResize(_ notification: Notification) {
        guard isChromeReady, let win = window, notification.object as? NSWindow === win else { return }
        layoutChrome()
    }

    // MARK: - Remaining Original Code
    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.lastActive = Date()
        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
    }

    func windowWillClose(_ notification: Notification) {
        tabStrip.cancelDrag()
        downloadsPopover?.close()
        saveSessionNow()
        // Release every web view now, not whenever the last reference happens to
        // go: a closed window must not leave content processes running.
        tabs.forEach { $0.hibernate() }
        NotificationCenter.default.removeObserver(self)
        hibernationTimer?.invalidate()
        memoryTimer?.invalidate()
        memoryPressureSource?.cancel()
        AppDelegate.shared?.windowClosed(self)
    }
}
