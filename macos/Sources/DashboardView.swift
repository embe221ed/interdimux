import AppKit

private final class DashboardDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class DashboardActionButton: NSButton {
    let descriptor: DashboardAction
    private let symbol = NSImageView()
    private var tracking: NSTrackingArea?
    var detail: String { didSet { needsDisplay = true; updateDescription() } }
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }
    var onHover: (() -> Void)?
    override var isFlipped: Bool { true }

    init(_ descriptor: DashboardAction) {
        self.descriptor = descriptor
        detail = descriptor.detail
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        title = descriptor.title
        setButtonType(.momentaryChange)
        symbol.image = NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        symbol.contentTintColor = Palette.secondary
        addSubview(symbol)
        setAccessibilityIdentifier(descriptor.id)
        updateDescription()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateDescription() {
        setAccessibilityLabel("\(descriptor.title), \(detail), key \(descriptor.key)\(descriptor.terminal ? ", opens in Rex terminal" : "")")
        toolTip = "\(detail) · \(descriptor.key.uppercased())\(descriptor.terminal ? " · Opens in Rex terminal" : "")"
    }

    override func layout() {
        super.layout()
        symbol.frame = NSRect(x: 13, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let compact = bounds.height < 40
        if chosen || hovered || isHighlighted {
            Palette.accent.withAlphaComponent(isHighlighted ? 0.14 : chosen ? 0.085 : 0.045).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        if chosen {
            Palette.accent.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: (bounds.height - 18) / 2, width: 2.5, height: 18), xRadius: 1.25, yRadius: 1.25).fill()
        }
        let keyRect = NSRect(x: max(0, bounds.width - 34), y: (bounds.height - 22) / 2, width: 24, height: 22)
        NSColor.white.withAlphaComponent(chosen ? 0.085 : 0.04).setFill()
        NSBezierPath(roundedRect: keyRect, xRadius: 5, yRadius: 5).fill()
        let keyStyle = NSMutableParagraphStyle(); keyStyle.alignment = .center
        (descriptor.key.uppercased() as NSString).draw(in: keyRect.offsetBy(dx: 0, dy: 3), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: chosen ? Palette.accent : Palette.secondary, .paragraphStyle: keyStyle
        ])
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let textWidth = max(0, keyRect.minX - 51 - (descriptor.terminal ? 57 : 0))
        (descriptor.title as NSString).draw(in: NSRect(x: 43, y: compact ? 2 : 6, width: textWidth, height: 17), withAttributes: [
            .font: NSFont.systemFont(ofSize: compact ? 12 : 13, weight: .medium), .foregroundColor: Palette.text, .paragraphStyle: style
        ])
        (detail as NSString).draw(in: NSRect(x: 43, y: compact ? 18 : 24, width: max(0, keyRect.minX - 51), height: 15), withAttributes: [
            .font: NSFont.systemFont(ofSize: compact ? 10 : 10.5), .foregroundColor: Palette.secondary, .paragraphStyle: style
        ])
        if descriptor.terminal {
            ("Terminal" as NSString).draw(in: NSRect(x: keyRect.minX - 57, y: compact ? 4 : 8, width: 49, height: 14), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: Palette.faint, .paragraphStyle: style
            ])
        }
    }
}

private final class DashboardGroup: NSView {
    let heading: NSTextField
    let buttons: [DashboardActionButton]
    private let note: NSTextField?
    var rowHeight: CGFloat = 44 { didSet { if oldValue != rowHeight { needsLayout = true } } }
    override var isFlipped: Bool { true }

    init(title: String, buttons: [DashboardActionButton]) {
        self.buttons = buttons
        heading = label(title, size: 9, weight: .semibold, color: Palette.faint)
        note = title == "TOOLS" ? label("Terminal tools open in Rex with their full controls.", size: 10.5, color: Palette.faint) : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.018).cgColor
        layer?.borderColor = Palette.line.cgColor
        layer?.borderWidth = 1
        heading.translatesAutoresizingMaskIntoConstraints = true
        addSubview(heading)
        for button in buttons { addSubview(button) }
        if let note {
            note.translatesAutoresizingMaskIntoConstraints = true
            note.maximumNumberOfLines = 2
            note.lineBreakMode = .byWordWrapping
            addSubview(note)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 15, y: 12, width: max(0, bounds.width - 30), height: 13)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 7, y: 34 + CGFloat(index) * rowHeight, width: max(0, bounds.width - 14), height: rowHeight)
        }
        note?.frame = NSRect(x: 16, y: bounds.height - 53, width: max(0, bounds.width - 32), height: 36)
    }
}

final class DashboardView: NSView {
    var onChoose: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let brand = label("INTERDIMUX", size: 10, weight: .semibold, color: Palette.secondary)
    private let brandIcon = icon("square.stack.3d.up", size: 13, color: Palette.accent)
    private let origin = label("REX  /  DASHBOARD", size: 9, weight: .medium, color: Palette.faint)
    private let title = label("Your workspace", size: 27, weight: .medium)
    private let subtitle = label("Switch, organize, and automate your Rex sessions.", size: 12, color: Palette.secondary)
    private let status = label("Choose a tool or press its key", size: 10.5, color: Palette.secondary)
    private let shortcuts = label("↑↓ navigate   ↩ open   esc close", size: 10, color: Palette.faint)
    private let scroll = NSScrollView()
    private let document = DashboardDocument()
    private let metrics = (0..<4).map { _ in label("—", size: 20, weight: .medium) }
    private let metricLabels = ["sessions", "tabs", "panes", "need attention"].map { label($0, size: 10.5, color: Palette.secondary) }
    private var buttons: [DashboardActionButton] = []
    private var groups: [DashboardGroup] = []
    private var selectedIndex = 0
    private var loading = false
    private var summary = DashboardSummary()
    var selectedActionID: String { DashboardCatalog.actions[selectedIndex].id }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = Palette.background.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        for view in [brand, brandIcon, origin, title, subtitle, status, shortcuts, scroll] + metrics + metricLabels {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for (index, descriptor) in DashboardCatalog.actions.enumerated() {
            let button = DashboardActionButton(descriptor)
            button.tag = index
            button.target = self
            button.action = #selector(chooseButton(_:))
            button.onHover = { [weak self] in self?.select(index) }
            buttons.append(button)
        }
        for name in DashboardCatalog.groups {
            let group = DashboardGroup(title: name, buttons: buttons.filter { $0.descriptor.group == name })
            document.addSubview(group)
            groups.append(group)
        }
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        setAccessibilityLabel("Interdimux dashboard")
        select(0, reveal: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let margin: CGFloat = 28
        let compact = bounds.height < 620
        let width = max(0, bounds.width - margin * 2)
        brandIcon.frame = NSRect(x: margin, y: compact ? 16 : 22, width: 14, height: 14)
        brand.frame = NSRect(x: margin + 21, y: compact ? 16 : 22, width: 130, height: 14)
        origin.frame = NSRect(x: max(margin, bounds.width - 172), y: compact ? 17 : 23, width: 144, height: 13)
        origin.alignment = .right
        title.frame = NSRect(x: margin, y: compact ? 43 : 51, width: width, height: 35)
        subtitle.frame = NSRect(x: margin, y: compact ? 79 : 91, width: width, height: 17)
        let metricWidth = width / 4
        for index in 0..<4 {
            let x = margin + CGFloat(index) * metricWidth
            metrics[index].frame = NSRect(x: x, y: compact ? 105 : 123, width: max(0, metricWidth - 10), height: 26)
            metricLabels[index].frame = NSRect(x: x, y: compact ? 132 : 151, width: max(0, metricWidth - 10), height: 15)
        }
        let contentTop: CGFloat = compact ? 154 : 185
        scroll.frame = NSRect(x: 0, y: contentTop, width: bounds.width, height: max(0, bounds.height - contentTop - 51))
        let geometry = DashboardGeometry.groups(width: scroll.contentSize.width, rowHeight: compact ? 35 : 44)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: geometry.height)
        for (group, frame) in zip(groups, geometry.frames) { group.rowHeight = compact ? 35 : 44; group.frame = frame }
        let shortcutsWidth: CGFloat = bounds.width < 620 ? 160 : 205
        shortcuts.frame = NSRect(x: max(margin, bounds.width - margin - shortcutsWidth), y: bounds.height - 30, width: shortcutsWidth, height: 15)
        shortcuts.alignment = .right
        shortcuts.stringValue = bounds.width < 620 ? "↑↓ move   ↩ open   esc" : "↑↓ navigate   ↩ open   esc close"
        status.frame = NSRect(x: margin, y: bounds.height - 30, width: max(0, shortcuts.frame.minX - margin - 15), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.line.setFill()
        NSRect(x: 0, y: bounds.height - 47, width: bounds.width, height: 1).fill()
    }

    func updateSummary(_ summary: DashboardSummary) {
        self.summary = summary
        for (index, count) in [summary.sessions, summary.tabs, summary.panes, summary.attention].enumerated() {
            metrics[index].stringValue = count.map(String.init) ?? "—"
        }
        metrics[3].textColor = (summary.attention ?? 0) > 0 ? Palette.accent : Palette.text
        if let count = summary.attention {
            buttons[1].detail = count == 1 ? "1 waiting for approval or input" : "\(count) waiting for approval or input"
        } else { buttons[1].detail = DashboardCatalog.actions[1].detail }
    }

    func setLoading(_ loading: Bool) {
        self.loading = loading
        setStatus(loading ? "Updating workspace…" : "Choose a tool or press its key")
    }

    func setStatus(_ message: String, isError: Bool = false) {
        status.stringValue = message
        status.toolTip = message
        status.textColor = isError ? Palette.accent : Palette.secondary
    }

    func resetSelection() { select(0) }
    func moveSelection(_ delta: Int) {
        let count = buttons.count
        select(((selectedIndex + delta) % count + count) % count)
    }
    @discardableResult func chooseSelected() -> Bool { onChoose?(selectedActionID); return true }
    @discardableResult func choose(key: String) -> Bool {
        guard let index = DashboardCatalog.actions.firstIndex(where: { $0.key == key.lowercased() }) else { return false }
        select(index)
        return chooseSelected()
    }

    private func select(_ index: Int, reveal: Bool = true) {
        selectedIndex = index
        for (offset, button) in buttons.enumerated() { button.chosen = offset == index }
        if reveal {
            let button = buttons[index]
            document.scrollToVisible(button.convert(button.bounds, to: document).insetBy(dx: 0, dy: -8))
        }
    }
    @objc private func chooseButton(_ sender: NSButton) { select(sender.tag); chooseSelected() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers.contains(.command) || modifiers.contains(.option) { super.keyDown(with: event); return }
        if modifiers == .control && (key == "n" || key == "p") { moveSelection(key == "n" ? 1 : -1); return }
        guard modifiers.isEmpty || modifiers == .shift else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: onCancel?()
        case 125, 124: moveSelection(1)
        case 126, 123: moveSelection(-1)
        case 48: moveSelection(modifiers.contains(.shift) ? -1 : 1)
        case 36, 76: chooseSelected()
        default:
            if key == "q" { onCancel?() }
            else if !choose(key: key) { super.keyDown(with: event) }
        }
    }
}
