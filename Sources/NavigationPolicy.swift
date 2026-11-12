import WebKit

/// Keeps ordinary web links inside Lantern instead of handing them to an app.
///
/// WebKit runs Universal Links / App Links *after* a navigation action has been
/// allowed: for a user-initiated main-frame navigation it asks Launch Services
/// whether an installed app (or web app) claims the URL, gives the URL to that
/// app, and cancels its own load. The delegate then sees the load fail with
/// `WebKitErrorDomain` 102, "Frame load interrupted", while macOS launches the
/// app — the reported google.com result -> xbox.com case.
///
/// The public `WKNavigationActionPolicy` has no value meaning "allow, but do not
/// try an app link", so this uses WebKit's internal
/// `_WKNavigationActionPolicyAllowWithoutTryingAppLink`. That constant is
/// declared in `WKNavigationActionPrivate.h` as
/// `_WKNavigationActionPolicyAllowWithoutTryingAppLink = WKNavigationActionPolicyAllow + 2`,
/// and is derived the same way here so it tracks the public enum's values
/// instead of hard-coding an integer.
///
/// This is private, undocumented API. It is deliberately confined to this file,
/// it is only ever applied to `http` and `https`, and it fails closed: if the
/// value cannot be constructed the caller gets the ordinary `.allow` policy.
enum NavigationPolicy {
    /// `.allow` + 2 — proceed without consulting Launch Services first.
    private static let allowWithoutTryingAppLink =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2)

    /// The decision for a navigation Lantern should perform itself.
    ///
    /// Only web navigation gets the private policy. Every other scheme keeps the
    /// plain `.allow`, so the existing external-protocol handoff (`mailto:`,
    /// `tel:`, ...) and internal loads (`about:`, `blob:`, `data:`, `file:`)
    /// behave exactly as before.
    static func decision(for url: URL) -> WKNavigationActionPolicy {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": return allowWithoutTryingAppLink ?? .allow
        default: return .allow
        }
    }

    /// True for WebKit's "Frame load interrupted" failure (error 102), which
    /// WebKit reports whenever a policy decision changed the outcome of a load.
    /// There is no page to show for it, so callers should stay quiet rather than
    /// render an error.
    static func isFrameLoadInterrupted(_ error: NSError) -> Bool {
        guard error.code == WKError.Code.frameLoadInterruptedByPolicyChange.rawValue else { return false }
        return error.domain == "WebKitErrorDomain" || error.domain == WKErrorDomain
    }
}
