import AppKit

/// The new-tab page, drawn natively. A blank tab in Lantern allocates no web
/// process at all -- there is literally nothing to load.
final class StartView: NSView {
    var onOpen: ((String) -> Void)?

    /// Clicking the title flips it between the product name and the characters.
    private var showsCharacters = false
    /// Held explicitly so layout() positions the title and the shortcut hint by
    /// identity, instead of guessing them out of the subview list.
    private var titleButton: NSButton?
    private var shortcutLabel: NSTextField?
    private var siteButtons: [NSButton] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        siteButtons.removeAll()

        // A borderless button, not a label: it reads as plain text but is clickable,
        // and the two brandings are just a title and a font swap.
        let title = NSButton(title: "", target: self, action: #selector(toggleBrand))
        title.isBordered = false
        title.focusRingType = .none
        title.alignment = .center
        title.contentTintColor = .labelColor
        addSubview(title)
        titleButton = title
        applyBrand()

        let sub = NSTextField(labelWithString: "\u{2318}L to go somewhere")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .tertiaryLabelColor
        sub.alignment = .center
        addSubview(sub)
        shortcutLabel = sub

        // Top sites by visit count, one entry per host.
        var seenHosts = Set<String>()
        var top: [(host: String, url: String)] = []
        for e in Store.shared.history.sorted(by: { $0.visits > $1.visits }) {
            guard let h = URL(string: e.url)?.host else { continue }
            let clean = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            if seenHosts.contains(clean) { continue }
            seenHosts.insert(clean)
            top.append((clean, "https://" + h + "/"))
            if top.count == 10 { break }
        }

        for site in top {
            let b = NSButton(title: site.host, target: self, action: #selector(openSite(_:)))
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = .secondaryLabelColor
            b.identifier = NSUserInterfaceItemIdentifier(site.url)
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
            b.layer?.cornerRadius = 8
            addSubview(b)
            siteButtons.append(b)
        }
        needsLayout = true
    }

    // MARK: - Branding

    @objc private func toggleBrand() {
        showsCharacters.toggle()
        applyBrand()
    }

    private func applyBrand() {
        guard let titleButton else { return }
        titleButton.title = showsCharacters ? "灯笼 🏮" : "Lantern 🏮"
        titleButton.font = showsCharacters
            ? StartView.hanFont(size: 30)
            : .systemFont(ofSize: 30, weight: .bold)
        needsLayout = true
    }

    /// PingFang SC Semibold, falling back to the family name and then to the system
    /// font, so the line still renders if the face is unavailable.
    private static func hanFont(size: CGFloat) -> NSFont {
        NSFont(name: "PingFangSC-Semibold", size: size)
            ?? NSFont(name: "PingFang SC", size: size)
            ?? .systemFont(ofSize: size, weight: .bold)
    }

    /// The title's natural size, so the button is only as wide as the word itself
    /// and clicking empty space beside it does nothing.
    private func brandSize() -> NSSize {
        guard let titleButton else { return .zero }
        let font = titleButton.font ?? .systemFont(ofSize: 30, weight: .bold)
        return (titleButton.title as NSString).size(withAttributes: [.font: font])
    }

    @objc private func openSite(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpen?(id) }
    }

    override func layout() {
        super.layout()
        let centerY = bounds.height * 0.34

        if let titleButton {
            // 40 rather than 38: a 30pt emoji glyph has a taller line box than SF Pro
            // and would otherwise clip at the edges of the button.
            let width = min(bounds.width, ceil(brandSize().width) + 4)
            titleButton.frame = NSRect(x: (bounds.width - width) / 2, y: centerY,
                                       width: width, height: 40)
        }
        shortcutLabel?.frame = NSRect(x: 0, y: centerY + 42, width: bounds.width, height: 18)

        guard !siteButtons.isEmpty else { return }
        // Center a wrapping row of pills under the title.
        let perRow = max(1, min(5, Int(bounds.width / 150)))
        let bw: CGFloat = 132, bh: CGFloat = 30, gap: CGFloat = 10
        var i = 0
        while i < siteButtons.count {
            let rowCount = min(perRow, siteButtons.count - i)
            let rowWidth = CGFloat(rowCount) * bw + CGFloat(rowCount - 1) * gap
            var x = (bounds.width - rowWidth) / 2
            let y = centerY + 84 + CGFloat(i / perRow) * (bh + gap)
            for j in 0..<rowCount {
                siteButtons[i + j].frame = NSRect(x: x, y: y, width: bw, height: bh)
                x += bw + gap
            }
            i += rowCount
        }
    }
}

/// URL field that gives the page its focus back on Escape and selects all on focus.
final class URLField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return ok
    }
}
