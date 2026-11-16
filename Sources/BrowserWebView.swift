import AppKit
import WebKit

/// A web view whose context menu can actually download.
///
/// WebKit's menu ships "Download Image", "Download Linked File" and "Download Media"
/// items, but in a plain `WKWebView` all three are inert: the items carry no URL of
/// their own and WebKit never routes them through `WKNavigationDelegate`, so choosing
/// one does nothing at all. They are taken over here, and the target is resolved from
/// the element under the cursor with one `elementFromPoint` call after the item is
/// chosen -- no injected scripts, no per-page work, nothing read on a plain right-click.
final class BrowserWebView: WKWebView {

    /// Called with a download-ready URL when one of those items is chosen.
    var onContextDownload: ((URL) -> Void)?

    /// Where the menu was opened, in top-left view points, and the page zoom at that
    /// moment. Kept until the next menu opens: AppKit can close the menu before it
    /// runs the item's action.
    private var menuPoint: NSPoint?
    private var menuZoom: CGFloat = 1

    /// WebKit's identifiers are stable across macOS releases; the titles are localised,
    /// so the identifier is the only safe thing to match on.
    private enum MenuItem: String {
        case image = "WKMenuItemIdentifierDownloadImage"
        case link = "WKMenuItemIdentifierDownloadLinkedFile"
        case media = "WKMenuItemIdentifierDownloadMedia"

        /// The DOM element that item means.
        var selector: String {
            switch self {
            case .image: return "img"
            case .link: return "a"
            case .media: return "video,audio,source"
            }
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let p = convert(event.locationInWindow, from: nil)
        menuPoint = NSPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        menuZoom = max(0.1, pageZoom)

        adoptDownloadItems(in: menu)
    }

    /// Takes over every download item in the menu, submenus included: which level
    /// WebKit puts them on is its business, and a miss would leave a dead item.
    private func adoptDownloadItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                adoptDownloadItems(in: submenu)
                continue
            }
            guard let id = item.identifier?.rawValue, MenuItem(rawValue: id) != nil else { continue }
            // WebKit's localised title, key equivalent and position are kept; only the
            // action changes, so the menu still reads like the one macOS ships.
            item.target = self
            item.action = #selector(downloadFromMenu(_:))
            item.representedObject = id
        }
    }

    @objc private func downloadFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let kind = MenuItem(rawValue: id),
              let point = menuPoint else {
            NSSound.beep()
            return
        }
        resolve(kind, at: point) { [weak self] url in
            guard let self else { return }
            guard let url else { NSSound.beep(); return }
            self.onContextDownload?(url)
        }
    }

    /// One query per chosen item, on the page's own element at the click point. The
    /// page is untrusted, so the result is checked again here and only schemes WebKit
    /// can download are passed on -- never `file:` or `javascript:`.
    private func resolve(_ kind: MenuItem, at point: NSPoint,
                         completion: @escaping (URL?) -> Void) {
        let x = Int((point.x / menuZoom).rounded())
        let y = Int((point.y / menuZoom).rounded())
        let js = """
        (function(){
          var el = document.elementFromPoint(\(x), \(y));
          if (!el || !el.closest) return null;
          var node = el.closest('\(kind.selector)');
          if (!node) return null;
          var raw = node.currentSrc || node.src || node.href || '';
          if (!raw) return null;
          try {
            var u = new URL(raw, location.href);
            if (u.protocol === 'http:' || u.protocol === 'https:'
                || u.protocol === 'data:' || u.protocol === 'blob:') return u.href;
          } catch (e) {}
          return null;
        })()
        """
        evaluateJavaScript(js) { result, _ in
            // A page can monkey-patch its own JS, so the scheme is enforced here too,
            // where the page has no say.
            guard let raw = result as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "data", "blob"].contains(scheme) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }
}
