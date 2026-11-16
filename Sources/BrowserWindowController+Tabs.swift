import AppKit
import WebKit

extension BrowserWindowController {
    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil) -> Tab {
        // A blank new tab opens the homepage when one is set, else the native start page.
        let effectiveURL = url ?? Config.shared.homepageURL
        let tab = Tab(url: effectiveURL, isPrivate: isPrivateWindow, delegate: self, configuration: configuration)
        tabs.append(tab)
        if configuration != nil { tab.ensureLoaded() }
        if activate {
            activeIndex = tabs.count - 1
            attachActiveTab()
            if effectiveURL == nil { focusURLField() }
        }
        refreshChrome()
        scheduleSessionSave()
        return tab
    }

    func restore(saved: [SavedTab], activeIndex idx: Int) {
        for s in saved {
            let t = Tab(saved: s, delegate: self)
            tabs.append(t)
        }
        activeIndex = min(max(0, idx), max(0, tabs.count - 1))
        attachActiveTab()
        refreshChrome()
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func selectRelativeTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        selectTab(index: ((activeIndex + delta) % n + n) % n)
    }

    func closeTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if tab.url != nil, !isPrivateWindow {
            closedTabs.append(tab.snapshot())
            if closedTabs.count > 10 { closedTabs.removeFirst() }
        }
        tab.webView?.removeFromSuperview()
        tab.hibernate()
        tabs.remove(at: index)
        if tabs.isEmpty {
            saveSessionNow()
            window?.close()
            return
        }
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if index < activeIndex { activeIndex -= 1 }
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func closeActiveTab() { closeTab(index: activeIndex) }

    @objc func reopenClosedTab() {
        guard let saved = closedTabs.popLast() else {
            showStatus("No recently closed tabs")
            return
        }
        let tab = Tab(saved: saved, delegate: self)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func attachActiveTab() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = activeTab else { return }
        tab.lastActive = Date()

        if tab.url == nil && !tab.hasEverLoaded {
            startView.rebuild()
            startView.frame = webContainer.bounds
            webContainer.addSubview(startView)
            return
        }
        let wv = tab.ensureLoaded()
        wv.frame = webContainer.bounds
        webContainer.addSubview(wv)
        window?.makeFirstResponder(wv)
    }

    func focusWebContent() {
        guard let wv = activeTab?.webView else { return }
        window?.makeFirstResponder(wv)
        if fullScreenAccessory != nil { window?.makeKey() }
    }

    func focusURLField() {
        setURLEditing(true)
        if !focus(urlField) { setURLEditing(false) }
    }

    func setURLEditing(_ editing: Bool) {
        isEditingURL = editing
        updateChromePin()
    }

    @discardableResult
    func focus(_ field: NSTextField) -> Bool {
        guard let host = field.window else { return false }
        if !host.isKeyWindow { host.makeKey() }
        return host.makeFirstResponder(field)
    }

    @objc func newTabFromToolbar() { newTab() }

    func applySettings() {
        startMemoryReadout()
        startHibernationTimer()
        applyMemoryPressureSetting()
        layoutChrome()
    }

    /// Starts or stops the memory-pressure watchdog to match the current setting.
    func applyMemoryPressureSetting() {
        if Config.shared.hibernateOnMemoryPressure {
            if memoryPressureSource == nil { installMemoryPressureHandling() }
        } else {
            memoryPressureSource?.cancel()
            memoryPressureSource = nil
        }
    }

    func startHibernationTimer() {
        hibernationTimer?.invalidate()
        guard Config.shared.hibernateAfterMinutes > 0 else { return }
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.hibernateIdleTabs()
        }
    }

    private func hibernateIdleTabs() {
        let threshold = Config.shared.hibernateAfterMinutes * 60
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if tab.canHibernate(idleFor: threshold) { tab.hibernate(); slept += 1 }
        }
        if slept > 0 {
            refreshChrome()
            saveSessionNow()
        }
    }

    @objc func hibernateBackgroundTabsNow() {
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if !tab.isHibernated { tab.hibernate(); slept += 1 }
        }
        refreshChrome()
        showStatus(slept == 0 ? "Nothing to sleep" : "Slept \(slept) tab\(slept == 1 ? "" : "s")")
    }

    func installMemoryPressureHandling() {
        guard Config.shared.hibernateOnMemoryPressure else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("Lantern: memory pressure, sleeping background tabs")
            self.hibernateBackgroundTabsNow()
            URLCache.shared.removeAllCachedResponses()
        }
        src.resume()
        memoryPressureSource = src
    }
}
