import AppKit
import WebKit

/// Host-keyed favicon cache and fetcher.
///
/// Three rules matter here.
///
/// Private tabs never touch it. The fetch is an app-process `URLSession` request,
/// so it leaves WebKit's non-persistent data store and the content blocker behind;
/// a private visit must neither start one nor leave a cached icon.
///
/// The cache is bounded. A long session touches thousands of hosts, and an
/// unbounded static dictionary is a leak no matter how small each icon is.
///
/// The response is capped. A page names its own icon URL, and buffering whatever
/// answers that URL would let a site ask for a memory spike.
enum FaviconLoader {

    private static var cache: [String: NSImage] = [:]
    /// Insertion order, so the oldest icon is the one evicted.
    private static var order: [String] = []
    /// Hosts with a fetch already running, so a reload storm cannot queue a
    /// request per navigation.
    private static var inFlight: Set<String> = []
    private static let maxEntries = 256
    private static let maxBytes = 512 * 1024

    static func cached(for host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        return cache[host]
    }

    /// Resolves the page's own icon link (or the well-known path) and fetches it.
    /// `completion` runs on the main thread, and only for a usable image.
    static func load(webView: WKWebView, host: String, completion: @escaping (NSImage?) -> Void) {
        if let hit = cache[host] {
            completion(hit)
            return
        }
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)

        let js = """
        (function(){var l=document.querySelector("link[rel~='icon']")||document.querySelector("link[rel='shortcut icon']");
        return l&&l.href?l.href:location.origin+'/favicon.ico';})()
        """
        webView.evaluateJavaScript(js) { result, _ in
            // The page chooses the href, so the scheme is checked here rather than
            // trusted: only web URLs are fetched outside WebKit.
            guard let raw = result as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                DispatchQueue.main.async {
                    inFlight.remove(host)
                    completion(nil)
                }
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data,
                      data.count <= maxBytes,
                      let http = response as? HTTPURLResponse,
                      http.expectedContentLength <= Int64(maxBytes),
                      let image = NSImage(data: data),
                      image.size.width > 0 else {
                    DispatchQueue.main.async {
                        inFlight.remove(host)
                        completion(nil)
                    }
                    return
                }
                DispatchQueue.main.async {
                    image.size = NSSize(width: 16, height: 16)
                    store(image, for: host)
                    inFlight.remove(host)
                    completion(image)
                }
            }.resume()
        }
    }

    private static func store(_ image: NSImage, for host: String) {
        if cache[host] == nil { order.append(host) }
        cache[host] = image
        while order.count > maxEntries {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}
