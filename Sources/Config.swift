import Foundation

/// User-editable settings, read from ~/Library/Application Support/Lantern/config.json
/// Missing file => defaults. Nothing here requires a rebuild to change.
/// The on-disk shape of config.json. Every key carries its default, and decoding
/// is per-key lenient: a missing key or a mistyped value falls back to the
/// default for that key only, so one bad line never nukes the rest of the file.
private struct StoredConfig: Codable {
    var searchTemplate = "https://www.google.com/search?q=%s"
    /// nil when the file predates the engine picker: Config adopts an engine
    /// from the template instead of assuming one.
    var searchEngine: String?
    var homepage = "about:blank"
    var hibernateAfterMinutes = 5.0
    var hibernateOnMemoryPressure = true
    var blockAdsAndTrackers = true
    var restoreSessionOnLaunch = true
    var showMemoryReadout = true
    var enableDeveloperTools = true
    var doubleClickTabStripForNewTab = true
    var commandClickOpensNewTab = true
    var activateNewTabsOnOpen = false
    var useCommandNumberTabShortcuts = true
    var downloadDirectory = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchTemplate = (try? c.decodeIfPresent(String.self, forKey: .searchTemplate)) ?? searchTemplate
        searchEngine = try? c.decodeIfPresent(String.self, forKey: .searchEngine)
        homepage = (try? c.decodeIfPresent(String.self, forKey: .homepage)) ?? homepage
        hibernateAfterMinutes = (try? c.decodeIfPresent(Double.self, forKey: .hibernateAfterMinutes)) ?? hibernateAfterMinutes
        hibernateOnMemoryPressure = (try? c.decodeIfPresent(Bool.self, forKey: .hibernateOnMemoryPressure)) ?? hibernateOnMemoryPressure
        blockAdsAndTrackers = (try? c.decodeIfPresent(Bool.self, forKey: .blockAdsAndTrackers)) ?? blockAdsAndTrackers
        restoreSessionOnLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .restoreSessionOnLaunch)) ?? restoreSessionOnLaunch
        showMemoryReadout = (try? c.decodeIfPresent(Bool.self, forKey: .showMemoryReadout)) ?? showMemoryReadout
        enableDeveloperTools = (try? c.decodeIfPresent(Bool.self, forKey: .enableDeveloperTools)) ?? enableDeveloperTools
        doubleClickTabStripForNewTab = (try? c.decodeIfPresent(Bool.self, forKey: .doubleClickTabStripForNewTab)) ?? doubleClickTabStripForNewTab
        commandClickOpensNewTab = (try? c.decodeIfPresent(Bool.self, forKey: .commandClickOpensNewTab)) ?? commandClickOpensNewTab
        activateNewTabsOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .activateNewTabsOnOpen)) ?? activateNewTabsOnOpen
        useCommandNumberTabShortcuts = (try? c.decodeIfPresent(Bool.self, forKey: .useCommandNumberTabShortcuts)) ?? useCommandNumberTabShortcuts
        downloadDirectory = (try? c.decodeIfPresent(String.self, forKey: .downloadDirectory)) ?? downloadDirectory
    }
}

final class Config {
    static let shared = Config()

    var searchTemplate: String
    /// Stable engine id from the picker (default google). Empty means a
    /// hand-written searchTemplate with no matching engine: it is used as-is.
    var searchEngine: String
    var homepage: String
    /// Minutes a background tab may sit before its web process is destroyed. 0 = never.
    var hibernateAfterMinutes: Double
    /// Hibernate every background tab immediately when the OS reports memory pressure.
    var hibernateOnMemoryPressure: Bool
    var blockAdsAndTrackers: Bool
    var restoreSessionOnLaunch: Bool
    var showMemoryReadout: Bool
    var enableDeveloperTools: Bool
    /// Double-clicking empty tab-strip space opens a new tab.
    var doubleClickTabStripForNewTab: Bool
    /// ⌘-clicking a link opens it in a new tab rather than loading it in place.
    var commandClickOpensNewTab: Bool
    /// A link opened in a new tab becomes the active tab.
    var activateNewTabsOnOpen: Bool
    /// The Window menu's ⌘-1 … ⌘-9 tab shortcuts are live.
    var useCommandNumberTabShortcuts: Bool
    /// Where downloads land. Empty means the system Downloads folder; the
    /// Settings window writes the folder the user picks here.
    var downloadDirectory: String

    static var supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lantern", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var fileURL: URL { Config.supportDir.appendingPathComponent("config.json") }

    /// Writes one snapshot without touching self, so the first launch can
    /// materialize the file before any property exists to read back.
    private static func persist(_ stored: StoredConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stored) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Moves an unparseable config.json aside instead of overwriting the only copy
    /// of the user's settings.
    private static func preserveUnreadableFile() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let backup = fileURL.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }

    private init() {
        let stored: StoredConfig
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(StoredConfig.self, from: data) {
            stored = decoded
        } else {
            // A file that exists but will not parse is still the user's settings, and
            // not ours to discard: keep it as config.json.bak before writing defaults.
            Self.preserveUnreadableFile()
            stored = StoredConfig()
            Self.persist(stored)  // materialize the file so it is discoverable and editable
        }
        searchTemplate = stored.searchTemplate
        homepage = stored.homepage
        hibernateAfterMinutes = stored.hibernateAfterMinutes
        hibernateOnMemoryPressure = stored.hibernateOnMemoryPressure
        blockAdsAndTrackers = stored.blockAdsAndTrackers
        restoreSessionOnLaunch = stored.restoreSessionOnLaunch
        showMemoryReadout = stored.showMemoryReadout
        enableDeveloperTools = stored.enableDeveloperTools
        doubleClickTabStripForNewTab = stored.doubleClickTabStripForNewTab
        commandClickOpensNewTab = stored.commandClickOpensNewTab
        activateNewTabsOnOpen = stored.activateNewTabsOnOpen
        useCommandNumberTabShortcuts = stored.useCommandNumberTabShortcuts
        downloadDirectory = stored.downloadDirectory
        if let id = stored.searchEngine {
            searchEngine = id
        } else if let known = SearchEngines.id(forTemplate: searchTemplate) {
            // A hand-set template that names a known engine: adopt it so the
            // picker reflects reality instead of silently overriding it.
            searchEngine = known
        } else if searchTemplate != (SearchEngines.template(for: SearchEngines.defaultEngineID) ?? "") {
            // A hand-set template with no matching engine: keep using it.
            searchEngine = ""
        } else {
            searchEngine = SearchEngines.defaultEngineID
        }
    }

    /// Called by the Settings picker. Keeps the legacy template in sync so older
    /// builds (which only read searchTemplate) keep working, then persists.
    func setSearchEngine(_ id: String) {
        searchEngine = id
        if let t = SearchEngines.template(for: id) { searchTemplate = t }
        save()
    }

    /// The effective download folder: the user's choice when it still exists,
    /// else the system Downloads folder. A stale or hand-edited path never
    /// breaks downloading; it just falls back to the default.
    var downloadDirectoryURL: URL {
        let def = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let raw = downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return def }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return def }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Homepage as a loadable URL, or nil for the native start page. Empty,
    /// about:blank and unparseable values all mean the start page, so a fresh
    /// install never spends a web process on a new tab.
    var homepageURL: URL? {
        let s = homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.lowercased() != "about:blank",
              let u = URL(string: s),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    func save() {
        var stored = StoredConfig()
        stored.searchTemplate = searchTemplate
        stored.searchEngine = searchEngine
        stored.homepage = homepage
        stored.hibernateAfterMinutes = hibernateAfterMinutes
        stored.hibernateOnMemoryPressure = hibernateOnMemoryPressure
        stored.blockAdsAndTrackers = blockAdsAndTrackers
        stored.restoreSessionOnLaunch = restoreSessionOnLaunch
        stored.showMemoryReadout = showMemoryReadout
        stored.enableDeveloperTools = enableDeveloperTools
        stored.doubleClickTabStripForNewTab = doubleClickTabStripForNewTab
        stored.commandClickOpensNewTab = commandClickOpensNewTab
        stored.activateNewTabsOnOpen = activateNewTabsOnOpen
        stored.useCommandNumberTabShortcuts = useCommandNumberTabShortcuts
        stored.downloadDirectory = downloadDirectory
        Self.persist(stored)
    }

    /// Turn whatever the user typed into something loadable: URL, bare host, or search.
    func resolve(input raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        if s.lowercased().hasPrefix("about:") || s.lowercased().hasPrefix("file:") { return URL(string: s) }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           scheme == "http" || scheme == "https", u.host != nil { return u }

        // A bare host: no spaces and a dot that looks like a TLD, or localhost[:port].
        let looksLikeHost = !s.contains(" ")
            && (s.range(of: #"^[\w.-]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || s.range(of: #"^localhost(:\d+)?(/.*)?$"#, options: .regularExpression) != nil)
        if looksLikeHost { return URL(string: "https://" + s) }

        return SearchEngines.buildSearchUrl(query: s)
    }
}
