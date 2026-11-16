import AppKit
import WebKit

extension BrowserWindowController {
    @objc func downloadsDidChange() { updateDownloadIndicator() }

    func updateDownloadIndicator() {
        let d = Downloads.shared
        // Visible while the list holds anything, so finished files stay reachable, and
        // held in place while its popover is open even if the list empties under it.
        downloadIndicator.isHidden = !d.hasItems && downloadsPopover == nil
        downloadIndicator.isActive = d.isDownloading
        downloadIndicator.progress = d.overallProgress
        downloadIndicator.toolTip = d.isDownloading
            ? "\(d.activeCount) download\(d.activeCount == 1 ? "" : "s") \u{2014} \(Int(d.overallProgress * 100))%"
            : (d.hasItems ? "Downloads" : nil)
        layoutChrome()
    }

    /// One popover, anchored under the indicator, created on demand and released when
    /// it closes.
    func toggleDownloadsPopover() {
        if let pop = downloadsPopover, pop.isShown {
            pop.performClose(nil)
            return
        }
        // A transient popover closes itself on the very click that lands on its anchor,
        // so a click arriving just after that means "close", not "open again".
        if let closedAt = downloadsPopoverClosedAt,
           Date().timeIntervalSince(closedAt) < 0.25 {
            downloadsPopoverClosedAt = nil
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = DownloadsPopoverController(nibName: nil, bundle: nil)
        // The toolbar row is flipped, so its maxY edge is the visual bottom: anchoring
        // there makes the popover drop down out of the toolbar, as Safari's does.
        pop.show(relativeTo: downloadIndicator.bounds, of: downloadIndicator, preferredEdge: .maxY)
        downloadsPopover = pop
    }

    func popoverDidClose(_ notification: Notification) {
        // Ignore a close from a popover that has already been replaced.
        guard let pop = notification.object as? NSPopover, pop === downloadsPopover else { return }
        downloadsPopoverClosedAt = Date()
        downloadsPopover = nil
        // Clearing the list while the popover was open left the anchor in place; now
        // that it is closed it can go.
        updateDownloadIndicator()
    }

    func refreshChrome() {
        layoutChrome()
        tabStrip.update(tabs: tabs, selected: activeIndex)

        guard let tab = activeTab else { return }
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward

        reloadButton.setSymbol(tab.isLoading ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = tab.isLoading ? "Stop loading" : "Reload (\u{2318}R)"
        progressBar.active = tab.isLoading && tab.progress < 1
        progressBar.progress = tab.progress

        if urlField.window?.firstResponder !== urlField.currentEditor() {
            let text = tab.url.map { u -> String in
                let s = u.absoluteString
                return s == "about:blank" ? "" : Store.displayForm(s)
            } ?? ""
            if urlField.stringValue != text { urlField.stringValue = text }
        }

        urlBar.showSecurity(for: tab.url)
        let bookmarked = tab.url.map { Store.shared.isBookmarked($0) } ?? false
        bookmarkButton.setSymbol(bookmarked ? "star.fill" : "star")
        bookmarkButton.isHighlighted2 = bookmarked
        bookmarkButton.isEnabled = tab.url != nil

        let blocking = Config.shared.blockAdsAndTrackers && ContentBlocker.ruleList != nil
        shieldButton.isHighlighted2 = blocking
        shieldButton.setSymbol(blocking ? "shield.lefthalf.filled" : "shield.slash")
        shieldButton.toolTip = blocking
            ? "Blocking \(ContentBlocker.ruleCount) ad & tracker rules \u{2014} click to disable"
            : "Ad & tracker blocking off \u{2014} click to enable"

        window?.title = tab.displayTitle
    }

    func startMemoryReadout() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        guard Settings.shared.showMemoryPill(jsonValue: Config.shared.showMemoryReadout) else {
            statusPill.text = ""
            return
        }
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, let w = self.window,
                  w.isVisible, w.occlusionState.contains(.visible) else { return }
            self.updateMemoryReadout()
        }
    }

    private func updateMemoryReadout() {
        guard statusResetWork == nil else { return }
        let s = MemoryMonitor.sharedSample()
        let sleeping = tabs.filter { $0.isHibernated }.count
        var text = s.display
        if sleeping > 0 { text += " \u{00B7} \(sleeping) asleep" }
        statusPill.text = text
        statusPill.toolTip = s.detail()
        layoutChrome()
    }

    func showStatus(_ message: String) {
        statusResetWork?.cancel()
        statusPill.text = message
        layoutChrome()
        let work = DispatchWorkItem { [weak self] in
            self?.statusResetWork = nil
            self?.updateMemoryReadout()
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func scheduleSessionSave() {
        guard !isPrivateWindow, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sessionSaveScheduled = false
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        guard !isPrivateWindow else { return }
        let snapshots = tabs.filter { $0.url != nil }.map { $0.snapshot() }
        Store.shared.saveSession(snapshots, activeIndex: activeIndex)
        Store.shared.flush()
    }
}
