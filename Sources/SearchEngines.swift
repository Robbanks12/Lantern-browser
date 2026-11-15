import Foundation

/// One row of the search-engine picker and one line of the catalog.
/// Adding or removing an engine is a single line in `SearchEngines.all` below.
struct SearchEngine {
    enum Group: String, CaseIterable {
        case general, china, aiChina, ai

        var title: String {
            switch self {
            case .general: return "General"
            case .china: return "China"
            case .aiChina: return "AI (China)"
            case .ai: return "AI"
            }
        }

        /// The AI groups start collapsed so the picker opens on the essentials.
        var collapsedByDefault: Bool { self == .aiChina || self == .ai }
    }

    let id: String
    let name: String
    let group: Group
    let urlTemplate: String
    let requiresLogin: Bool

    /// Templates must be http(s) and contain exactly one %s placeholder.
    var isValid: Bool {
        guard urlTemplate.components(separatedBy: "%s").count == 2,
              let probe = URL(string: urlTemplate.replacingOccurrences(of: "%s", with: "test")),
              let scheme = probe.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              probe.host != nil else { return false }
        return true
    }
}

/// The single catalog every search entry point funnels through.
enum SearchEngines {
    static let defaultEngineID = "google"

    static let all: [SearchEngine] = {
        let engines: [SearchEngine] = [
            // General
            SearchEngine(id: "google", name: "Google", group: .general, urlTemplate: "https://www.google.com/search?q=%s", requiresLogin: false),
            SearchEngine(id: "duckduckgo", name: "DuckDuckGo", group: .general, urlTemplate: "https://duckduckgo.com/?q=%s", requiresLogin: false),
            SearchEngine(id: "ecosia", name: "Ecosia", group: .general, urlTemplate: "https://www.ecosia.org/search?q=%s", requiresLogin: false),
            SearchEngine(id: "qwant", name: "Qwant", group: .general, urlTemplate: "https://www.qwant.com/?q=%s", requiresLogin: false),
            SearchEngine(id: "mojeek", name: "Mojeek", group: .general, urlTemplate: "https://www.mojeek.com/search?q=%s", requiresLogin: false),
            SearchEngine(id: "brave", name: "Brave Search", group: .general, urlTemplate: "https://search.brave.com/search?q=%s", requiresLogin: false),
            SearchEngine(id: "wikipedia", name: "Wikipedia", group: .general, urlTemplate: "https://en.wikipedia.org/w/index.php?search=%s", requiresLogin: false),
            // China
            SearchEngine(id: "baidu", name: "Baidu", group: .china, urlTemplate: "https://www.baidu.com/s?wd=%s", requiresLogin: false),
            SearchEngine(id: "bing_cn", name: "Bing (China)", group: .china, urlTemplate: "https://cn.bing.com/search?q=%s", requiresLogin: false),
            SearchEngine(id: "so360", name: "360 Search", group: .china, urlTemplate: "https://www.so.com/s?q=%s", requiresLogin: false),
            SearchEngine(id: "sogou", name: "Sogou", group: .china, urlTemplate: "https://www.sogou.com/web?query=%s", requiresLogin: false),
            SearchEngine(id: "quark", name: "Quark", group: .china, urlTemplate: "https://quark.sm.cn/s?q=%s", requiresLogin: false),
            SearchEngine(id: "baidu_baike", name: "Baidu Baike", group: .china, urlTemplate: "https://baike.baidu.com/search?word=%s", requiresLogin: false),
            // AI (China)
            SearchEngine(id: "deepseek", name: "DeepSeek", group: .aiChina, urlTemplate: "https://chat.deepseek.com/?q=%s", requiresLogin: true),
            SearchEngine(id: "metaso", name: "Metaso", group: .aiChina, urlTemplate: "https://metaso.cn/?q=%s", requiresLogin: false),
            // AI
            SearchEngine(id: "perplexity", name: "Perplexity", group: .ai, urlTemplate: "https://www.perplexity.ai/search?q=%s", requiresLogin: false),
            SearchEngine(id: "chatgpt", name: "ChatGPT", group: .ai, urlTemplate: "https://chatgpt.com/?q=%s", requiresLogin: true),
            SearchEngine(id: "you", name: "You.com", group: .ai, urlTemplate: "https://you.com/search?q=%s", requiresLogin: true),
            SearchEngine(id: "claude", name: "Claude", group: .ai, urlTemplate: "https://claude.ai/new?q=%s", requiresLogin: true),
            SearchEngine(id: "google_ai", name: "Google AI Mode", group: .ai, urlTemplate: "https://www.google.com/search?q=%s&udm=50", requiresLogin: false),
            SearchEngine(id: "phind", name: "Phind", group: .ai, urlTemplate: "https://www.phind.com/search?q=%s", requiresLogin: false),
            SearchEngine(id: "grok", name: "Grok", group: .ai, urlTemplate: "https://grok.com/?q=%s", requiresLogin: true),
            SearchEngine(id: "kagi", name: "Kagi Assistant", group: .ai, urlTemplate: "https://kagi.com/search?q=%s", requiresLogin: false),
        ]
        assert(engines.allSatisfy { $0.isValid }, "Invalid search engine template")
        return engines.filter { $0.isValid }
    }()

    static func engine(id: String) -> SearchEngine? {
        all.first { $0.id == id }
    }

    static func template(for id: String) -> String? {
        engine(id: id)?.urlTemplate
    }

    /// Reverse lookup for hand-set templates, so the picker can reflect a
    /// template the user wrote into config.json by hand.
    static func id(forTemplate template: String) -> String? {
        all.first { $0.urlTemplate == template }?.id
    }

    /// The single funnel every search entry point uses. Reads the current
    /// setting and falls back to the default engine on unknown ids.
    static func buildSearchUrl(query: String) -> URL? {
        let template = template(for: Config.shared.searchEngine)
            ?? Config.shared.searchTemplate
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))
    }
}
