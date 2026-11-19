import AppKit

/// Pure geometry for the window chrome.
///
/// Every frame in the toolbar, tab strip, find bar and web container is computed
/// here from a value input, so the layout can be reasoned about — and tested —
/// without a window. `BrowserWindowController` only applies the result.
///
/// The fields are defaulted and filled in by the caller rather than passed through
/// one long initialiser: the argument order of a twenty-parameter call is the kind
/// of thing that only a compiler catches.
enum ChromeLayout {

    struct Input {
        var bounds: NSRect = .zero
        var toolbarWidth: CGFloat = 0
        var inTitlebar = false
        var toolbarRowHeight: CGFloat = 40
        var tabRowHeight: CGFloat = 36
        var findVisible = false
        var downloadVisible = false
        var pillVisible = false
        var pillWidth: CGFloat = 0
        /// Left edge of the navigation buttons, after the traffic lights.
        var contentLeft: CGFloat = 78
    }

    struct Frames {
        var visibleChromeHeight: CGFloat = 0
        var chromeHost: NSRect = .zero
        var toolbarRow: NSRect = .zero
        var tabScrollView: NSRect = .zero
        var progressBar: NSRect = .zero
        var findRow: NSRect = .zero
        var chromeBackground: NSRect = .zero
        var hairline: NSRect = .zero
        var webContainer: NSRect = .zero
        var back: NSRect = .zero
        var forward: NSRect = .zero
        var reload: NSRect = .zero
        var urlBar: NSRect = .zero
        var plus: NSRect = .zero
        var download: NSRect = .zero
        var shield: NSRect = .zero
        var bookmark: NSRect = .zero
        var pill: NSRect = .zero
        var findField: NSRect = .zero
        var findPrevious: NSRect = .zero
        var findNext: NSRect = .zero
        var findCount: NSRect = .zero
        var findDone: NSRect = .zero
    }

    static func frames(_ input: Input) -> Frames {
        var f = Frames()

        let b = input.bounds
        let toolRow = input.toolbarRowHeight
        let tabRow = input.tabRowHeight
        let findRowHeight: CGFloat = input.findVisible ? 34 : 0
        let chromeHeight = toolRow + tabRow
        let visibleChromeHeight = chromeHeight + findRowHeight
        let width = input.toolbarWidth

        let bw: CGFloat = 30
        let bh: CGFloat = 28
        let y = (toolRow - bh) / 2

        // Right cluster, laid out right to left: plus, ring, shield, star, readout.
        var right = width - 12
        f.plus = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        f.download = NSRect(x: right - bw, y: y, width: bw, height: bh)
        if input.downloadVisible { right -= bw + 2 }
        f.shield = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        f.bookmark = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        if input.pillVisible {
            f.pill = NSRect(x: right - input.pillWidth, y: 0,
                            width: input.pillWidth, height: toolRow)
            right -= input.pillWidth + 4
        }
        // Leftmost item of the cluster: the readout when shown, else the star.
        let clusterLeft = input.pillVisible ? f.pill.minX : f.bookmark.minX

        // Address bar: reload glued to its trailing edge, an even gap either side.
        let navRight = input.contentLeft + bw + 2 + bw
        let reloadGap: CGFloat = 8
        let minBarWidth: CGFloat = 220
        let slack = (clusterLeft - navRight) - bw - reloadGap - minBarWidth
        let sideGap = max(14, min(width * 0.14, slack / 2))
        let reloadX = clusterLeft - sideGap - bw
        let urlX = navRight + sideGap

        f.back = NSRect(x: input.contentLeft, y: y, width: bw, height: bh)
        f.forward = NSRect(x: input.contentLeft + bw + 2, y: y, width: bw, height: bh)
        f.reload = NSRect(x: reloadX, y: y, width: bw, height: bh)
        f.urlBar = NSRect(x: urlX, y: (toolRow - bh) / 2,
                          width: max(90, reloadX - reloadGap - urlX), height: bh)

        f.visibleChromeHeight = visibleChromeHeight
        f.chromeHost = NSRect(x: b.minX, y: b.minY, width: b.width, height: visibleChromeHeight)
        f.toolbarRow = NSRect(x: 0, y: 0, width: width, height: toolRow)
        f.tabScrollView = NSRect(x: 0, y: toolRow, width: width, height: tabRow)
        f.progressBar = NSRect(x: 0, y: chromeHeight - 3, width: width, height: 3)
        f.findRow = NSRect(x: 0, y: chromeHeight, width: width, height: findRowHeight)
        f.chromeBackground = NSRect(x: 0, y: 0, width: width, height: visibleChromeHeight)
        f.hairline = NSRect(x: 0, y: visibleChromeHeight - 1, width: width, height: 1)

        if input.inTitlebar {
            // The surface underneath the accessory already sits inside the titlebar
            // window, so the web container fills the whole content view.
            f.webContainer = b
        } else {
            f.webContainer = NSRect(x: b.minX, y: b.minY + visibleChromeHeight,
                                    width: b.width,
                                    height: max(0, b.height - visibleChromeHeight))
        }

        f.findField = NSRect(x: 14, y: 5, width: 250, height: 24)
        f.findPrevious = NSRect(x: 272, y: 5, width: 26, height: 24)
        f.findNext = NSRect(x: 300, y: 5, width: 26, height: 24)
        f.findCount = NSRect(x: 334, y: 9, width: 200, height: 16)
        f.findDone = NSRect(x: width - 78, y: 5, width: 64, height: 24)

        return f
    }
}
