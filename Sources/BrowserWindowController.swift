import AppKit
import WebKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One view holds the toolbar, tab strip and find row. Windowed, it overlays the
/// transparent titlebar inside `root`. In native full screen the same view becomes
/// the view of a titlebar accessory, so AppKit moves it with the menu bar.
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
    /// Non-nil exactly while the window is in native full screen. Then `chromeHost` is
    /// the accessory's view and lives in AppKit's titlebar window, not in `root`.
    var fullScreenAccessory: NSTitlebarAccessoryViewController?
    var isEditingURL = false

    // Fullscreen custom traffic lights
    var fullscreenTrafficLights: [NSButton] = []
    var nativeTrafficLightStates: [(type: NSWindow.ButtonType, wasHidden: Bool)] = []

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
        let pillVisible = Settings.shared.showMemoryPill(jsonValue: Config.shared.showMemoryReadout)
        let pillWidth: CGFloat = pillVisible ? max(64, min(190, statusPill.fittingWidth)) : 0

        let key = ChromeLayoutKey(width: b.width, height: b.height, inTitlebar: inTitlebar,
                                  findVisible: findVisible, downloadHidden: downloadIndicator.isHidden,
                                  pillHidden: !pillVisible, pillWidth: pillWidth)
        guard key != lastChromeLayoutKey else { return }
        lastChromeLayoutKey = key

        let toolRow = toolbarRowHeight
        let tabRow = tabRowHeight
        let visibleChromeHeight = chromeHeight + findRowHeight
        let tabsWidth: CGFloat = toolbarWidth

        if inTitlebar {
            resizeFullScreenAccessory(to: visibleChromeHeight)
        } else {
            chromeHost.isHidden = false
            chromeHost.frame = NSRect(x: b.minX, y: b.minY,
                                      width: b.width, height: visibleChromeHeight)
        }

        toolbarRow.frame = NSRect(x: 0, y: 0, width: toolbarWidth, height: toolRow)
        tabScrollView.frame = NSRect(x: 0, y: toolRow, width: tabsWidth, height: tabRow)
        progressBar.frame = NSRect(x: 0, y: chromeHeight - 3, width: tabsWidth, height: 3)
        findRow.frame = NSRect(x: 0, y: chromeHeight, width: tabsWidth, height: findRowHeight)
        findRow.isHidden = !findVisible

        chromeBackground.frame = NSRect(x: 0, y: 0, width: tabsWidth, height: visibleChromeHeight)
        hairline.frame = NSRect(x: 0, y: visibleChromeHeight - 1, width: tabsWidth, height: 1)

        if inTitlebar {
            webContainer.frame = b
        } else {
            webContainer.frame = NSRect(x: b.minX, y: b.minY + visibleChromeHeight,
                                        width: b.width,
                                        height: max(0, b.height - visibleChromeHeight))
        }
        startView.frame = webContainer.bounds
        activeTab?.webView?.frame = webContainer.bounds

        let bw: CGFloat = 30, bh: CGFloat = 28
        let y = (toolRow - bh) / 2
        
        // In fullscreen, the native traffic lights are hidden and replaced by our custom ones in toolbarRow
        let leftStart: CGFloat
        if inTitlebar {
            leftStart = fullscreenTrafficLights.map(\.frame.maxX).max().map { $0 + 10 } ?? 78
        } else {
            let lightsRight = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { win.standardWindowButton($0) }
                .map { root.convert($0.bounds, from: $0).maxX }
                .max() ?? 70
            leftStart = lightsRight + 10
        }
        
        backButton.frame = NSRect(x: leftStart, y: y, width: bw, height: bh)
        forwardButton.frame = NSRect(x: leftStart + bw + 2, y: y, width: bw, height: bh)

        let clusterLeft = layoutRightCluster(y: y, toolbarWidth: toolbarWidth,
                                              pillVisible: pillVisible, pillWidth: pillWidth)
        layoutAddressBar(clusterLeft: clusterLeft, navRight: forwardButton.frame.maxX,
                         y: y, toolbarWidth: toolbarWidth)

        if findVisible {
            findField.frame = NSRect(x: 14, y: 5, width: 250, height: 24)
            findPrevButton.frame = NSRect(x: 272, y: 5, width: 26, height: 24)
            findNextButton.frame = NSRect(x: 300, y: 5, width: 26, height: 24)
            findCount.frame = NSRect(x: 334, y: 9, width: 200, height: 16)
            findDoneButton.frame = NSRect(x: tabsWidth - 78, y: 5, width: 64, height: 24)
        }
    }

    /// Slots plus, ring, shield, star and readout right to left; returns the
    /// cluster's left edge, which the address bar measures its gap from.
    private func layoutRightCluster(y: CGFloat, toolbarWidth: CGFloat,
                                      pillVisible: Bool, pillWidth: CGFloat) -> CGFloat {
        let bw: CGFloat = 30, bh: CGFloat = 28
        var right = toolbarWidth - 12
        plusButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2

        // The download ring takes the same slot as every other toolbar button, so its
        // padding matches the controls either side of it. The cluster closes up while
        // it is hidden, so an idle window shows no empty slot.
        if !downloadIndicator.isHidden {
            downloadIndicator.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
            right -= bw + 2
        }

        shieldButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        bookmarkButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2

        // The readout sits at the head of the right-hand cluster, left of the star.
        if pillVisible {
            statusPill.isHidden = false
            statusPill.frame = NSRect(x: right - pillWidth, y: 0,
                                      width: pillWidth, height: toolbarRowHeight)
            right -= pillWidth + 4
        } else {
            statusPill.isHidden = true
        }

        // Leftmost item of the cluster: the readout when it is shown, else the star.
        return statusPill.isHidden ? bookmarkButton.frame.minX : statusPill.frame.minX
    }

    /// Reload glued to the bar, with an even gap to the nav buttons on one side
    /// and the page controls on the other, the way Safari spaces the pair.
    private func layoutAddressBar(clusterLeft: CGFloat, navRight: CGFloat,
                                    y: CGFloat, toolbarWidth: CGFloat) {
        let bw: CGFloat = 30, bh: CGFloat = 28
        let width = toolbarWidth
        let reloadGap: CGFloat = 8
        let minBarWidth: CGFloat = 220
        let available = clusterLeft - navRight
        let slack = available - bw - reloadGap - minBarWidth
        let sideGap = max(14, min(width * 0.14, slack / 2))

        let reloadX = clusterLeft - sideGap - bw
        reloadButton.frame = NSRect(x: reloadX, y: y, width: bw, height: bh)

        let urlX = navRight + sideGap
        let fieldH: CGFloat = 28
        urlBar.frame = NSRect(x: urlX, y: (toolbarRowHeight - fieldH) / 2,
                              width: max(90, reloadX - reloadGap - urlX), height: fieldH)
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
