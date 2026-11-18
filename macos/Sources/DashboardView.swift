import AppKit

private final class DashboardDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class DashboardAttentionButton: NSButton {
    // Keep this action's hit target and header layout stable as counts change.
    private var caption = "Agents"
    private var hasWaitingAgents = false
    private static let style: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    override var isFlipped: Bool { true }

    func update(count: Int?) {
        if let count {
            caption = count == 0 ? "No agents waiting" : "\(count) \(count == 1 ? "agent" : "agents") waiting"
        } else {
            caption = "Agents"
        }
        hasWaitingAgents = (count ?? 0) > 0
        needsDisplay = true
    }

    override func accessibilityLabel() -> String? { "\(caption), show agents needing attention" }

    override func draw(_ dirtyRect: NSRect) {
        let tint = hasWaitingAgents || isHighlighted ? Palette.accent : Palette.secondary
        let arrowX = bounds.maxX - 5
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - 3, y: bounds.midY - 3))
        arrow.line(to: NSPoint(x: arrowX, y: bounds.midY))
        arrow.line(to: NSPoint(x: arrowX - 3, y: bounds.midY + 3))
        arrow.lineWidth = 1.3
        tint.setStroke()
        arrow.stroke()
        (caption as NSString).draw(in: NSRect(x: 0, y: bounds.midY - 8, width: max(0, arrowX - 9), height: 17),
                                   withAttributes: [.font: Self.textFont, .foregroundColor: tint, .paragraphStyle: Self.style])
    }
}

private final class DashboardActionButton: NSButton {
    let descriptor: DashboardAction
    private let symbol = NSImageView()
    private var tracking: NSTrackingArea?
    var detail: String { didSet { if oldValue != detail { needsDisplay = true; updateDescription() } } }
    var chosen = false { didSet {
        if oldValue != chosen {
            state = chosen ? .on : .off
            symbol.contentTintColor = chosen ? Palette.accent : Palette.secondary
            needsDisplay = true
        }
    } }
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    var onHover: (() -> Void)?
    override var isFlipped: Bool { true }

    private static let textStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let keyStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()
    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let detailFont = NSFont.systemFont(ofSize: 11.5)
    private let shortcut: NSString

    init(_ descriptor: DashboardAction) {
        shortcut = descriptor.key.uppercased() as NSString
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
        symbol.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: 18, height: 18)
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
        let mid = bounds.midY
        if chosen || hovered || isHighlighted {
            Palette.accent.withAlphaComponent(isHighlighted ? 0.20 : chosen ? 0.13 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        let keyRect = NSRect(x: max(0, bounds.width - 31), y: mid - 10, width: 22, height: 20)
        (chosen ? Palette.accent : Palette.text).withAlphaComponent(chosen ? 0.16 : 0.075).setFill()
        NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4).fill()
        shortcut.draw(in: keyRect.offsetBy(dx: 0, dy: 2), withAttributes: [
            .font: Self.keyFont, .foregroundColor: chosen ? Palette.accent : Palette.secondary,
            .paragraphStyle: Self.keyStyle
        ])
        let textWidth = max(0, keyRect.minX - 44)
        (descriptor.title as NSString).draw(in: NSRect(x: 38, y: mid - 16, width: textWidth, height: 18), withAttributes: [
            .font: Self.titleFont, .foregroundColor: Palette.text, .paragraphStyle: Self.textStyle
        ])
        (detail as NSString).draw(in: NSRect(x: 38, y: mid + 2, width: textWidth, height: 16), withAttributes: [
            .font: Self.detailFont, .foregroundColor: Palette.secondary, .paragraphStyle: Self.textStyle
        ])
    }
}

private final class DashboardGroup: NSView {
    let heading: NSTextField
    let buttons: [DashboardActionButton]
    var horizontal = false { didSet { if oldValue != horizontal { needsLayout = true } } }
    var rowHeight: CGFloat = 48 { didSet { if oldValue != rowHeight { needsLayout = true } } }
    override var isFlipped: Bool { true }

    init(title: String, buttons: [DashboardActionButton]) {
        self.buttons = buttons
        heading = label(title, size: 12, weight: .semibold, color: Palette.secondary)
        super.init(frame: .zero)
        heading.translatesAutoresizingMaskIntoConstraints = true
        addSubview(heading)
        for button in buttons { addSubview(button) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 8, y: 3, width: max(0, bounds.width - 16), height: 17)
        let column = horizontal ? bounds.width / CGFloat(buttons.count) : bounds.width
        for (index, button) in buttons.enumerated() {
            let x = horizontal ? column * CGFloat(index) : 0
            let y = DashboardGeometry.headingHeight + (horizontal ? 0 : rowHeight * CGFloat(index))
            button.frame = NSRect(x: x, y: y, width: column, height: rowHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.line.setFill()
        NSRect(x: 8, y: DashboardGeometry.headingHeight - 5, width: max(0, bounds.width - 16), height: 1).fill()
    }
}

final class DashboardView: NSView {
    var onChoose: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let brandIcon = icon("square.stack.3d.up.fill", size: 24, color: Palette.accent)
    private let title = label("Workspace", size: 23, weight: .semibold)
    private let inventory = label("Rex sessions, tabs and panes", size: 12, color: Palette.secondary)
    private let attention = DashboardAttentionButton()
    private let status = label("Choose a tool or press its key", size: 11, color: Palette.secondary)
    private let shortcuts = label("", size: 11, color: Palette.secondary)
    private let scroll = NSScrollView()
    private let document = DashboardDocument()
    private var buttons: [DashboardActionButton] = []
    private var groups: [DashboardGroup] = []
    private var selectedIndex = 0
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
        layer?.borderColor = Palette.border.cgColor
        layer?.borderWidth = 1
        brandIcon.wantsLayer = true
        brandIcon.layer?.cornerRadius = 9
        brandIcon.layer?.backgroundColor = Palette.accent.withAlphaComponent(0.10).cgColor
        attention.isBordered = false
        attention.refusesFirstResponder = true
        attention.setButtonType(.momentaryPushIn)
        attention.setAccessibilityRole(.button)
        attention.target = self
        attention.action = #selector(chooseAttention)
        shortcuts.alignment = .right
        attention.setAccessibilityIdentifier("dashboard-attention-summary")
        attention.toolTip = "Show agents needing attention"
        for view in [brandIcon, title, inventory, attention, status, shortcuts, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for (index, descriptor) in DashboardCatalog.actions.enumerated() {
            let button = DashboardActionButton(descriptor)
            button.tag = index
            button.target = self
            button.action = #selector(chooseButton(_:))
            button.onHover = { [weak self] in
                guard let self, self.buttons[index].isEnabled else { return }
                self.select(index)
            }
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
        buttons[0].chosen = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshTheme() {
        layer?.backgroundColor = Palette.background.cgColor
        layer?.borderColor = Palette.border.cgColor
        brandIcon.layer?.backgroundColor = Palette.accent.withAlphaComponent(0.10).cgColor
        Palette.invalidate(view: self)
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 26
        let header: CGFloat = bounds.height < 510 ? 78 : 88
        brandIcon.frame = NSRect(x: margin, y: (header - 42) / 2, width: 42, height: 42)
        let textX = brandIcon.frame.maxX + 12
        let attentionWidth = min(160, bounds.width * 0.36)
        attention.frame = NSRect(x: bounds.width - margin - attentionWidth, y: (header - 28) / 2,
                                 width: attentionWidth, height: 28)
        let textWidth = max(0, attention.frame.minX - textX - 6)
        title.frame = NSRect(x: textX, y: header / 2 - 24, width: textWidth, height: 29)
        inventory.frame = NSRect(x: textX + 1, y: header / 2 + 5, width: textWidth, height: 17)
        let footer: CGFloat = 41
        let top = header + 12
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - footer - 8))
        // All twelve actions fit a compact two-column panel. Small single-column
        // windows keep full-size rows and scroll the focused item into view.
        let wide = scroll.contentSize.width >= DashboardGeometry.horizontalThreshold
        let rowHeight = wide ? min(58, max(38, floor((scroll.contentSize.height - 76) / 6))) : 46
        let geometry = DashboardGeometry.groups(width: scroll.contentSize.width, rowHeight: rowHeight)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: geometry.height)
        for (index, group) in groups.enumerated() {
            group.rowHeight = rowHeight
            group.horizontal = wide && index == groups.count - 1
            group.frame = geometry.frames[index]
        }
        let shortcutsWidth: CGFloat = wide ? 240 : 210
        shortcuts.frame = NSRect(x: max(margin, bounds.width - margin - shortcutsWidth), y: bounds.height - 28,
                                 width: shortcutsWidth, height: 16)
        let hint = wide ? "↑↓←→  Navigate     ↩  Open     esc  Close" : "↑↓  Navigate   ↩  Open   esc  Close"
        if shortcuts.stringValue != hint { shortcuts.stringValue = hint }
        status.frame = NSRect(x: margin, y: bounds.height - 28, width: max(0, shortcuts.frame.minX - margin - 10), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.insetBackground.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height < 510 ? 78 : 88).fill()
        Palette.line.setFill()
        NSRect(x: 0, y: bounds.height < 510 ? 77 : 87, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 41, width: bounds.width, height: 1).fill()
    }

    @objc private func chooseAttention() { _ = choose(key: "e") }

    func updateSummary(_ summary: DashboardSummary) {
        guard self.summary != summary else { return }
        let old = self.summary
        self.summary = summary
        if (old.terminalToolsAvailable == false) != (summary.terminalToolsAvailable == false) {
            for button in buttons where button.descriptor.terminal {
                button.isEnabled = summary.terminalToolsAvailable != false
                button.alphaValue = button.isEnabled ? 1 : 0.55
                button.detail = button.isEnabled ? button.descriptor.detail : "Requires a local Rex pane"
            }
            if !buttons[selectedIndex].isEnabled { resetSelection() }
        }
        func count(_ value: Int?, _ one: String) -> String {
            "\(value.map(String.init) ?? "—") \(one)\(value == 1 ? "" : "s")"
        }
        if old.sessions != summary.sessions || old.tabs != summary.tabs || old.panes != summary.panes {
            inventory.stringValue = [count(summary.sessions, "session"), count(summary.tabs, "tab"), count(summary.panes, "pane")].joined(separator: "   ·   ")
        }
        guard old.attention != summary.attention else { return }
        attention.update(count: summary.attention)
        buttons[1].detail = summary.attention.map { "\($0) waiting for approval or input" } ?? buttons[1].descriptor.detail
    }

    func setLoading(_ loading: Bool) {
        setStatus(loading ? "Updating workspace…" : "Choose a tool or press its key")
    }

    func setStatus(_ message: String, isError: Bool = false) {
        status.stringValue = message
        status.toolTip = message
        status.textColor = isError ? Palette.accent : Palette.secondary
    }

    func resetSelection() { select(0) }
    func moveSelection(_ delta: Int) {
        if let next = PickerNavigation.nextIndex(current: selectedIndex, count: buttons.count, direction: delta,
                isSelectable: { self.buttons[$0].isEnabled }) { select(next) }
    }
    @discardableResult func chooseSelected() -> Bool { onChoose?(selectedActionID); return true }
    @discardableResult func choose(key: String) -> Bool {
        guard let index = DashboardCatalog.actions.firstIndex(where: { $0.key == key.lowercased() }) else { return false }
        guard buttons[index].isEnabled else {
            setStatus("Open the dashboard from a local Rex pane to use " + buttons[index].descriptor.title + ".")
            return true
        }
        select(index)
        return chooseSelected()
    }

    private func moveHorizontally(_ direction: Int) {
        guard bounds.width >= DashboardGeometry.horizontalThreshold else { moveSelection(direction); return }
        layoutSubtreeIfNeeded()
        let source = buttons[selectedIndex]
        let frame = source.convert(source.bounds, to: document)
        // Switch to the closest row across the gutter; the terminal strip has
        // three adjacent choices. A missing or unavailable neighbor is a no-op.
        let neighbors = buttons.filter { button in
            guard button !== source, button.isEnabled else { return false }
            let other = button.convert(button.bounds, to: document)
            return frame.minY < other.maxY && frame.maxY > other.minY &&
                (other.midX - frame.midX) * CGFloat(direction) > 0
        }
        if let next = neighbors.min(by: {
            abs($0.convert($0.bounds, to: document).midX - frame.midX) <
                abs($1.convert($1.bounds, to: document).midX - frame.midX)
        }) { select(next.tag) }
    }

    private func select(_ index: Int, reveal: Bool = true) {
        if selectedIndex != index {
            buttons[selectedIndex].chosen = false
            selectedIndex = index
            buttons[index].chosen = true
        }
        if reveal {
            let button = buttons[index]
            document.scrollToVisible(button.convert(button.bounds, to: document).insetBy(dx: 0, dy: -8))
        }
    }
    @objc private func chooseButton(_ sender: NSButton) { select(sender.tag); chooseSelected() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.pickerModifiers
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers.contains(.command) || modifiers.contains(.option) { super.keyDown(with: event); return }
        if modifiers == .control && (key == "n" || key == "p") { moveSelection(key == "n" ? 1 : -1); return }
        guard modifiers.isEmpty || modifiers == .shift else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: onCancel?()
        case 125: moveSelection(1)
        case 126: moveSelection(-1)
        case 123, 124: moveHorizontally(event.keyCode == 124 ? 1 : -1)
        case 48: moveSelection(modifiers.contains(.shift) ? -1 : 1)
        case 36, 76: chooseSelected()
        default:
            if key == "q" { onCancel?() }
            else if !choose(key: key) { super.keyDown(with: event) }
        }
    }
}
