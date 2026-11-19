import AppKit
import WebKit

// MARK: - Delegates

extension BrowserWindowController: TabDelegate {
    func tabDidChangeState(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        if idx == activeIndex {
            refreshChrome()
        } else {
            tabStrip.update(tabs: tabs, selected: activeIndex)
        }
        if !tab.isLoading { scheduleSessionSave() }
    }

    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab? {
        let previous = activeIndex
        let newOne = newTab(url: url, activate: true, configuration: configuration)
        if !activate, tabs.indices.contains(previous) {
            activeIndex = previous
            attachActiveTab()
            refreshChrome()
        }
        return newOne
    }

    func tabRequestsClose(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(index: idx)
    }

    /// A blank tab WebKit created for a link that became a download. It should go,
    /// but only once the transfer it is carrying has ended.
    func tabRequestsRetirement(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        // Mark, never close, at this point. The download decision is still travelling
        // through WebKit, so the transfer may not exist for a few more runloop turns;
        // closing now would destroy the web view that is about to carry the bytes.
        // `retireFinishedTransferTabs` closes it when DownloadItem reports an end.
        tab.awaitsTransferBeforeRetirement = true
        // A transfer that failed before we got here will not post again.
        retireFinishedTransferTabs()
    }

    func tabStatus(_ tab: Tab, message: String?) {
        if let message { showStatus(message) }
    }
}

extension BrowserWindowController: TabStripDelegate {
    func tabStripDidSelect(index: Int) { selectTab(index: index) }
    func tabStripDidRequestClose(index: Int) { closeTab(index: index) }
    func tabStripDidRequestNewTab() { newTab() }

    func tabStripDidRequestMove(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        if activeIndex == from {
            activeIndex = to
        } else if from < activeIndex, to >= activeIndex {
            activeIndex -= 1
        } else if from > activeIndex, to <= activeIndex {
            activeIndex += 1
        }
        refreshChrome()
        scheduleSessionSave()
    }

    func tabStripContextActions(index: Int) -> [(String, () -> Void)] {
        guard tabs.indices.contains(index) else { return [] }
        let tab = tabs[index]
        var items: [(String, () -> Void)] = []

        items.append(("Reload", { [weak self] in
            tab.reload(); self?.refreshChrome()
        }))
        items.append(("Duplicate Tab", { [weak self] in
            guard let self, let u = tab.url else { return }
            self.newTab(url: u)
        }))
        if let u = tab.url {
            items.append(("Copy Address", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }))
        }
        items.append(("-", {}))
        if !tab.isHibernated {
            items.append(("Put Tab to Sleep", { [weak self] in
                guard let self else { return }
                if tab === self.activeTab { self.showStatus("Can\u{2019}t sleep the active tab"); return }
                tab.hibernate()
                self.refreshChrome()
            }))
        }
        items.append(("-", {}))
        items.append(("Close Tab", { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(index: i)
        }))
        if tabs.count > 1 {
            items.append(("Close Other Tabs", { [weak self] in
                guard let self else { return }
                for other in self.tabs where other !== tab {
                    if other.url != nil { self.closedTabs.append(other.snapshot()) }
                    other.webView?.removeFromSuperview()
                    other.hibernate()
                }
                self.tabs = [tab]
                self.activeIndex = 0
                self.attachActiveTab()
                self.refreshChrome()
                self.scheduleSessionSave()
            }))
        }
        return items
    }
}

extension BrowserWindowController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        urlBar.setFocused(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        urlBar.setFocused(false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField, !suppressCompletion,
              let editor = urlField.currentEditor() as? NSTextView else { return }
        suppressCompletion = true
        editor.complete(nil)
        suppressCompletion = false
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        return Store.shared.suggestions(for: textView.string)
    }
}
