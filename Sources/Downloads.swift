import AppKit
import WebKit

extension Notification.Name {
    /// Posted when a download starts, progresses, pauses, finishes or fails. Driven
    /// entirely by WebKit's callbacks and progress KVO, so there is nothing to poll.
    static let downloadsDidChange = Notification.Name("LanternDownloadsDidChange")
}

/// One transfer, from the moment WebKit names its destination until the user clears it.
///
/// Progress comes from `WKDownload.progress` and is cached here, so the list can be
/// drawn without touching the file system: nothing reads the Downloads folder, which
/// is also what keeps a browse-only session out of TCC's Downloads permission.
final class DownloadItem {
    enum State: Equatable { case downloading, paused, finished, failed }

    let id = UUID()
    let name: String
    /// WebKit's own suggestion, kept so a resumed transfer can be recognised without
    /// trusting the file name it ended up with.
    let suggestedName: String
    let destination: URL
    fileprivate(set) var state: State = .downloading
    fileprivate(set) var completedBytes: Int64 = 0
    fileprivate(set) var totalBytes: Int64 = 0
    /// nil once the transfer is paused or over; the download belongs to WebKit.
    fileprivate(set) var download: WKDownload?
    fileprivate var observation: NSKeyValueObservation?
    fileprivate var resumeData: Data?
    fileprivate weak var webView: WKWebView?

    fileprivate init(name: String, suggestedName: String, destination: URL, download: WKDownload?) {
        self.name = name
        self.suggestedName = suggestedName
        self.destination = destination
        self.download = download
        self.webView = download?.webView
        syncProgress()
    }

    /// 0…1 for the row's progress bar.
    var fraction: Double {
        if state == .finished { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// The row's second line: a size once known, a running count while it arrives.
    var detail: String {
        switch state {
        case .failed:
            return "Failed"
        case .finished:
            return totalBytes > 0 ? DownloadItem.sizeText(totalBytes) : "Finished"
        case .paused:
            guard totalBytes > 0 else { return "Paused" }
            return "\(DownloadItem.sizeText(completedBytes)) of \(DownloadItem.sizeText(totalBytes)) \u{00B7} Paused"
        case .downloading:
            guard totalBytes > 0 else { return "Starting\u{2026}" }
            return "\(DownloadItem.sizeText(completedBytes)) of \(DownloadItem.sizeText(totalBytes))"
        }
    }

    /// Copies WebKit's counters into the item, so a row never asks the progress object
    /// (which is gone while paused) for anything.
    fileprivate func syncProgress() {
        guard let progress = download?.progress else { return }
        if progress.totalUnitCount > 0 { totalBytes = progress.totalUnitCount }
        if progress.completedUnitCount > 0 { completedBytes = progress.completedUnitCount }
        if totalBytes > 0 { completedBytes = min(completedBytes, totalBytes) }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The download list behind the toolbar's popover.
///
/// Downloads land in the Settings-chosen folder (else ~/Downloads) with a de-duplicated
/// name, and WebKit streams straight to disk. This singleton is the strong owner of
/// every `WKDownload` and its progress observation, so a transfer outlives the tab that
/// started it. No download manager window, no background service, no timers.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    /// Set by the active window so downloads can be announced in the toolbar.
    var statusHandler: ((String) -> Void)?

    /// Newest first. Finished entries stay until the user clears them.
    private(set) var items: [DownloadItem] = []

    /// WebKit resumes through a web view, so the last live one is kept for transfers
    /// whose own tab has since been closed or put to sleep.
    private weak var lastWebView: WKWebView?
    /// The paused item a resume belongs to, until its destination is decided again.
    private var resuming: DownloadItem?

    var hasItems: Bool { !items.isEmpty }
    var isDownloading: Bool { items.contains { $0.state == .downloading } }
    var activeCount: Int { items.lazy.filter { $0.state == .downloading }.count }
    var hasFinished: Bool { items.contains { $0.state == .finished || $0.state == .failed } }

    /// Mean progress of the running transfers; 0 when idle.
    var overallProgress: Double {
        let running = items.filter { $0.state == .downloading }
        guard !running.isEmpty else { return 0 }
        return min(1, max(0, running.reduce(0) { $0 + $1.fraction } / Double(running.count)))
    }

    /// Resolved on every use, so a Settings change applies to the very next download
    /// with nothing to notify and nothing cached to go stale.
    private var folder: URL { Config.shared.downloadDirectoryURL }

    /// Server-supplied names are not trusted: keep only the last path component, drop
    /// anything that could escape the folder, and never land on a dotfile.
    private func sanitizedName(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "download" : name
    }

    private func uniqueDestination(for name: String) -> URL {
        let safe = sanitizedName(name)
        var candidate = folder.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            i += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && i < 500
        return candidate
    }

    // MARK: - Tracking

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    /// True while this web view still owns a transfer that has not ended.
    ///
    /// Tabs use it to refuse hibernation and automatic retirement: destroying the
    /// web view cancels the download, and a WKDownload cannot be re-hosted on
    /// another one.
    func hasActiveTransfer(for webView: WKWebView?) -> Bool {
        guard let webView else { return false }
        return items.contains {
            ($0.state == .downloading || $0.state == .paused) && $0.webView === webView
        }
    }

    /// True once a transfer this web view carried has finished or failed. Used to
    /// decide when a tab that only existed to host a download can be retired.
    func hasEndedTransfer(for webView: WKWebView?) -> Bool {
        guard let webView else { return false }
        return items.contains {
            ($0.state == .finished || $0.state == .failed) && $0.webView === webView
        }
    }

    /// Attaches an item to the download that will carry its bytes and starts observing
    /// progress. Called once per transfer, and again when a paused one is resumed.
    private func adopt(_ download: WKDownload, into item: DownloadItem) {
        item.observation?.invalidate()
        item.download = download
        item.state = .downloading
        if let wv = download.webView {
            item.webView = wv
            lastWebView = wv
        }
        item.syncProgress()
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self, weak item] _, _ in
            item?.syncProgress()
            self?.notifyChange()
        }
        notifyChange()
    }

    /// Drops the observation and the download together; the item keeps its numbers.
    private func detach(_ item: DownloadItem) {
        item.observation?.invalidate()
        item.observation = nil
        item.download = nil
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .downloadsDidChange, object: self)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // A resumed transfer keeps the file it already started; only a fresh one gets a
        // new, de-duplicated name in the chosen folder.
        if let item = item(for: download) {
            adopt(download, into: item)
            completionHandler(item.destination)
            return
        }
        // A resume re-asks for a destination under the same suggested name, which is
        // how it finds its way back to the paused row.
        if let pending = resuming, pending.suggestedName == suggestedFilename {
            resuming = nil
            adopt(download, into: pending)
            completionHandler(pending.destination)
            return
        }
        let dest = uniqueDestination(for: suggestedFilename)
        let item = DownloadItem(name: dest.lastPathComponent, suggestedName: suggestedFilename,
                                destination: dest, download: download)
        items.insert(item, at: 0)
        adopt(download, into: item)
        statusHandler?("Downloading \(item.name)\u{2026}")
        // WebKit writes the bytes; we only pick where they land.
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.syncProgress()
        item.state = .finished
        item.completedBytes = item.totalBytes
        detach(item)
        statusHandler?("Saved \(item.name) to \(item.destination.deletingLastPathComponent().lastPathComponent)")
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        // A cancel we asked for ourselves is a pause, not a failure.
        if item.state == .paused {
            item.resumeData = item.resumeData ?? resumeData
            notifyChange()
            return
        }
        item.syncProgress()
        item.state = .failed
        item.resumeData = resumeData
        detach(item)
        statusHandler?(Self.message(for: error))
    }

    private static func message(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
            return "Download failed: no permission to write to "
                + Config.shared.downloadDirectoryURL.lastPathComponent
                + ". Choose another folder in Settings."
        }
        return "Download failed: \(error.localizedDescription)"
    }

    // MARK: - Pause, resume, clear

    /// WebKit has no pause, so a pause is a cancel that keeps its resume data, and a
    /// resume replays that data through a live web view.
    func togglePause(_ item: DownloadItem) {
        switch item.state {
        case .downloading:
            guard let download = item.download else { return }
            // Set before the cancel lands: its failure callback means "paused" now.
            item.state = .paused
            item.observation?.invalidate()
            item.observation = nil
            download.cancel { [weak self, weak item] data in
                guard let self, let item else { return }
                guard let data else {
                    // No resume data means WebKit cannot continue this transfer, so say
                    // so instead of leaving a row that will never move again.
                    item.state = .failed
                    self.statusHandler?("This download can't be paused")
                    self.notifyChange()
                    return
                }
                item.resumeData = data
                self.notifyChange()
            }
            item.download = nil
            notifyChange()
        case .paused:
            resume(item)
        case .finished, .failed:
            break
        }
    }

    private func resume(_ item: DownloadItem) {
        guard let data = item.resumeData, let webView = webViewForResume() else {
            statusHandler?("Open a tab to resume this download")
            return
        }
        item.state = .downloading
        item.completedBytes = 0
        resuming = item
        notifyChange()
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            // Progress and the outcome arrive only if the delegate is set right here.
            download.delegate = self
            // The destination callback may already have adopted this one; if it has
            // not run yet, adopt here so the row moves either way.
            if self.resuming === item {
                self.resuming = nil
                self.adopt(download, into: item)
            }
        }
    }

    /// The transfer's own tab may be gone, so fall back to the front tab; waking it
    /// costs one web process, which is the price of carrying on the download.
    private func webViewForResume() -> WKWebView? {
        if let wv = lastWebView, wv.window != nil { return wv }
        guard let tab = AppDelegate.shared?.front?.activeTab else { return nil }
        let wv = tab.ensureLoaded()
        lastWebView = wv
        return wv
    }

    /// Removes everything that is no longer running. The running ones stay: clearing
    /// the list must never cancel a transfer.
    func clearFinished() {
        items.removeAll { $0.state == .finished || $0.state == .failed }
        notifyChange()
    }

    func reveal(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    /// Opens the folder downloads land in, selecting a file that is still arriving.
    func revealFolder() {
        if let running = items.first(where: { $0.state == .downloading }) {
            reveal(running)
            return
        }
        NSWorkspace.shared.open(folder)
    }
}
