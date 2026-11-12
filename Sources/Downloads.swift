import AppKit
import WebKit

extension Notification.Name {
    /// Posted when a download starts, progresses, finishes or fails. Driven entirely by
    /// WebKit's callbacks and progress KVO, so there is nothing to poll.
    static let downloadsDidChange = Notification.Name("LanternDownloadsDidChange")
}

/// Downloads land in ~/Downloads with a de-duplicated name. No download manager
/// window, no background service -- WebKit streams straight to disk.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    /// Set by the active window so finished downloads can be announced in the toolbar.
    var statusHandler: ((String) -> Void)?
    private(set) var recent: [URL] = []

    /// `WKDownload.delegate` is weak, so this singleton is the strong owner of both the
    /// downloads and their progress observations: a download outlives the tab that
    /// started it, and its progress stays observable until it terminates.
    private var active: [(download: WKDownload, observation: NSKeyValueObservation)] = []

    var isDownloading: Bool { !active.isEmpty }
    var activeCount: Int { active.count }

    /// Mean progress of the running downloads; 0 when idle.
    var overallProgress: Double {
        guard !active.isEmpty else { return 0 }
        let sum = active.reduce(0.0) { $0 + $1.download.progress.fractionCompleted }
        return min(1, max(0, sum / Double(active.count)))
    }

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

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

    private func track(_ download: WKDownload) {
        guard !active.contains(where: { $0.download === download }) else { return }
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] _, _ in self?.notifyChange()
        }
        active.append((download, observation))
        notifyChange()
    }

    /// Drops the observation and the reference together, so a finished download leaves
    /// nothing behind in the toolbar's state.
    private func untrack(_ download: WKDownload) {
        guard let i = active.firstIndex(where: { $0.download === download }) else { return }
        active[i].observation.invalidate()
        active.remove(at: i)
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .downloadsDidChange, object: self)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = uniqueDestination(for: suggestedFilename)
        track(download)
        statusHandler?("Downloading \(dest.lastPathComponent)\u{2026}")
        // WebKit writes the bytes; we only pick where they land.
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let name = download.progress.fileURL?.lastPathComponent ?? "file"
        if let u = download.progress.fileURL {
            recent.insert(u, at: 0)
            recent = Array(recent.prefix(20))
        }
        untrack(download)
        statusHandler?("Saved \(name) to Downloads")
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        untrack(download)
        statusHandler?("Download failed: \(error.localizedDescription)")
    }

    func revealFolder() {
        NSWorkspace.shared.open(folder)
    }
}
