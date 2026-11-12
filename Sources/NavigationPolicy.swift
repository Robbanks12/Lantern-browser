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
/// `_WKNavigationActionPolicyAllowWithoutTryingAppLink`.
///
/// ## Where the value comes from
///
/// `Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h` declares it
/// as a file-scope constant rather than an enum case:
///
///     static const WKNavigationActionPolicy _WKNavigationActionPolicyAllowWithoutTryingAppLink
///         = (WKNavigationActionPolicy)(WKNavigationActionPolicyAllow + 2);
///
/// `Source/WebKit/UIProcess/Cocoa/NavigationState.mm` then handles it by calling
/// `localListener->use()` directly, skipping the `tryInterceptNavigation()` call
/// — the one that runs `LSAppLink openWithURL` — that a plain `.allow` goes
/// through. The URL is still offered to SO authorization, so enterprise SSO
/// sign-in keeps working.
///
/// Current numbering: cancel 0, allow 1, download 2, allowWithoutTryingAppLink 3,
/// allowInNewProcess 4. This derives it as `.allow + 2` rather than hard-coding
/// an integer, so it follows the public cases if those ever shift.
///
/// ## Risk
///
/// Raw value 3 is a private implementation detail of the WebKit build shipping
/// on the Mac, with no compatibility contract: Apple may change, remove or
/// repurpose it in any future macOS release. If it stops meaning what it means
/// today, these navigations get whatever WebKit makes of the number — 2, for
/// instance, is download, which would turn page loads into downloads. The value
/// is therefore only ever used for `http`/`https`, and `decision(for:)` keeps an
/// ordinary `.allow` path. After a macOS update, re-check by hand that a link to
/// a site with a native app (xbox.com) loads in place instead of opening the app.
enum NavigationPolicy {
    /// `.allow` + 2 — "load it, do not consult Launch Services first".
    ///
    /// `init?(rawValue:)` is declared failable, but an `NS_ENUM` never rejects a
    /// value: Swift treats it like the C cast it is, precisely so a framework can
    /// use private cases its headers do not list. The fallback below should
    /// therefore never run — if it somehow does, the page still loads normally
    /// and WebKit's app-link interception simply resumes.
    private static let allowWithoutTryingAppLink =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    /// The decision for a navigation Lantern should perform itself.
    ///
    /// Only web navigation gets the private policy. Every other scheme keeps the
    /// plain `.allow`, so the existing external-protocol handoff (`mailto:`,
    /// `tel:`, ...) and internal loads (`about:`, `blob:`, `data:`, `file:`)
    /// behave exactly as before.
    static func decision(for url: URL) -> WKNavigationActionPolicy {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": return allowWithoutTryingAppLink
        default: return .allow
        }
    }

    /// True for WebKit's "Frame load interrupted" failure (error 102), which
    /// WebKit reports whenever a policy decision changed the outcome of a load:
    /// our own `.cancel` for an external scheme or a new-tab click, or the system
    /// taking an http(s) URL over for an app.
    static func isFrameLoadInterrupted(_ error: NSError) -> Bool {
        // Use the legacy global constant for WebKit error 102, 
        // as WKError.Code does not expose this case.
        return error.domain == "WebKitErrorDomain" && 
               error.code == WebKitErrorFrameLoadInterruptedByPolicyChange
    }

    /// `scheme://host` for a URL string, or `unknown host`.
    ///
    /// Used only for diagnostics, and deliberately drops the path, query,
    /// fragment and any user info: Console output must not record where the user
    /// was browsing, what they searched for, or a token a URL carried.
    static func originDescription(of urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString),
              let host = url.host, !host.isEmpty else { return "unknown host" }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme.isEmpty ? host : "\(scheme)://\(host)"
    }
}
