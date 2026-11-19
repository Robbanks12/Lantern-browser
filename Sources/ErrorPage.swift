import Foundation

/// The page shown when a navigation fails.
///
/// It lives here rather than inside `Tab` so the tab model is not half HTML string,
/// and so the escaping that keeps a hostile host name from writing markup has one
/// home.
enum ErrorPage {

    static func html(failingURL: String, domain: String, code: Int, reason: String) -> String {
        let host = escaped(URL(string: failingURL)?.host ?? failingURL)
        let detail = escaped(reason)
        let origin = escaped(domain)
        return """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
        <style>
        :root{color-scheme:light dark}
        body{font:15px/1.55 -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;
        color:#111;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#1c1c1e}}
        .c{max-width:30rem;padding:2rem;text-align:center}
        h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}
        p{opacity:.65;margin:0 0 1.5rem}
        button{font:inherit;padding:.5rem 1.1rem;border-radius:7px;border:0;background:#0a84ff;color:#fff;cursor:pointer}
        code{opacity:.5;font-size:.8rem}
        </style>
        <div class=c><h1>Can\u{2019}t open \(host)</h1>
        <p>\(detail)</p>
        <button onclick="location.reload()">Try again</button>
        <p><code>\(origin) \(code)</code></p></div>
        """
    }

    /// Everything that came from outside the app — the host, the system error text
    /// and the error domain — is escaped before it is interpolated.
    private static func escaped(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }
}
