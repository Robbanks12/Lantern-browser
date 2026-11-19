import AppKit
import WebKit

extension BrowserWindowController {
    @objc func goBack() { activeTab?.goBack() }
    @objc func goForward() { activeTab?.goForward() }

    @objc func reloadOrStop() {
        guard let tab = activeTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reload() { activeTab?.reload() }

    @objc func stopLoading() {
        guard let tab = activeTab, tab.isLoading else { return }
        tab.stop()
        refreshChrome()
    }

    @objc func toggleBlocking() {
        Config.shared.blockAdsAndTrackers.toggle()
        Config.shared.save()
        applyBlockingSetting()
    }

    /// Re-applies the ad & tracker setting: used by the toolbar shield and the
    /// Settings checkbox alike, so open tabs reload under the new rules at once.
    func applyBlockingSetting() {
        if Config.shared.blockAdsAndTrackers {
            ContentBlocker.load { [weak self] _ in
                self?.reloadAllForRuleChange()
            }
        } else {
            reloadAllForRuleChange()
        }
    }

    private func reloadAllForRuleChange() {
        // A tab carrying a download keeps its current rules until the transfer ends:
        // recreating the web view below would cancel it.
        for (i, tab) in tabs.enumerated() where i != activeIndex && !tab.isHostingActiveTransfer {
            tab.hibernate()
        }
        if let tab = activeTab, !tab.isHostingActiveTransfer {
            tab.webView?.removeFromSuperview()
            tab.hibernate()
            attachActiveTab()
        }
        refreshChrome()
        showStatus(Config.shared.blockAdsAndTrackers ? "Blocking on" : "Blocking off")
    }

    @objc func toggleBookmark() {
        guard let tab = activeTab, let u = tab.url else { return }
        let added = Store.shared.toggleBookmark(url: u, title: tab.title)
        showStatus(added ? "Bookmarked" : "Bookmark removed")
        refreshChrome()
        AppDelegate.shared?.rebuildBookmarksMenu()
    }

    @objc func urlFieldCommitted() {
        let raw = urlField.stringValue
        guard let url = Config.shared.resolve(input: raw) else { return }
        if activeTab == nil { newTab(url: url); return }
        activeTab?.load(url)
        attachActiveTab()
        refreshChrome()
        focusWebContent()
        scheduleSessionSave()
    }
}
