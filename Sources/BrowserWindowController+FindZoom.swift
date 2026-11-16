import AppKit
import WebKit

extension BrowserWindowController {
    @objc func zoomIn() { adjustZoom(1.1) }
    @objc func zoomOut() { adjustZoom(1 / 1.1) }
    @objc func zoomReset() { activeTab?.webView?.pageZoom = 1 }

    private func adjustZoom(_ factor: CGFloat) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = min(3, max(0.4, wv.pageZoom * factor))
        showStatus("Zoom \(Int(wv.pageZoom * 100))%")
    }

    @objc func showFindBar() {
        findVisible = true
        layoutChrome()
        focus(findField)
    }

    @objc func hideFindBar() {
        findVisible = false
        findCount.stringValue = ""
        layoutChrome()
        focusWebContent()
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    private func runFind(backwards: Bool) {
        guard let wv = activeTab?.webView, !findField.stringValue.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(findField.stringValue, configuration: cfg) { [weak self] result in
            self?.findCount.stringValue = result.matchFound ? "" : "Not found"
        }
    }
}
