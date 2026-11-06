import AppKit

enum Palette {
    static let accent = NSColor(srgbRed: 231/255, green: 138/255, blue: 78/255, alpha: 1)
    static let text = NSColor(srgbRed: 221/255, green: 213/255, blue: 197/255, alpha: 1)
    static let secondary = NSColor(srgbRed: 158/255, green: 151/255, blue: 138/255, alpha: 1)
    static let faint = NSColor(srgbRed: 145/255, green: 139/255, blue: 128/255, alpha: 1)
    static let background = NSColor(srgbRed: 36/255, green: 37/255, blue: 35/255, alpha: 1)
    static let line = NSColor.white.withAlphaComponent(0.07)
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Palette.text) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.lineBreakMode = .byTruncatingTail
    view.maximumNumberOfLines = 1
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

func icon(_ symbol: String, size: CGFloat, color: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    view.contentTintColor = color
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

final class PickerPanel: NSPanel {
    var onCommand: ((String) -> Bool)?
    var onShortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers, onCommand?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class PickerTable: NSTableView {
    var onNavigate: ((Int) -> Void)?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onType: ((NSEvent) -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onNavigate?(1)
        case 126: onNavigate?(-1)
        case 36, 76: onAccept?()
        case 53: onCancel?()
        default: onType?(event)
        }
    }
}

final class PickerRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 9, dy: 3)
        Palette.accent.withAlphaComponent(0.075).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        Palette.accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 9, y: 10, width: 3, height: bounds.height - 20), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class PickerCell: NSTableCellView {
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["terminal", "macwindow", "square.stack.3d.up", "folder", "plus.circle"] {
            images[name] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        return images
    }()
    let symbol = NSImageView()
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let sessionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let truncatedTitleStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let indent: CGFloat = 22
    private static let rootCenter: CGFloat = 34
    // Lightweight native cells retain AppKit's grapheme-aware truncation
    // without three NSTextField view/layer/layout hierarchies per result.
    private static func textCell(size: CGFloat, color: NSColor) -> NSTextFieldCell {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = .systemFont(ofSize: size)
        cell.textColor = color
        cell.isBordered = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.isSelectable = false
        cell.wraps = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
    let primary = PickerCell.textCell(size: 13, color: Palette.text)
    let path = PickerCell.textCell(size: 10.5, color: Palette.faint)
    let kind = PickerCell.textCell(size: 9, color: Palette.faint)
    private(set) var isCurrent = false
    private(set) var textFrames = PickerGeometry.rowFrames(width: 0, depth: 0)
    private var configuredItem: PickerItem?
    private var tree = PickerTreePosition(depth: 0, ancestorContinuations: [], hasNextSibling: false, hasChildren: false)
    private var separatesGroup = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.translatesAutoresizingMaskIntoConstraints = true
        addSubview(symbol)
        symbol.contentTintColor = Palette.secondary
        path.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        path.lineBreakMode = .byTruncatingHead
        kind.font = .systemFont(ofSize: 9, weight: .medium)
        kind.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Rows have a fixed height and bounded columns. Frame layout avoids
    // re-solving hundreds of intrinsic text-size constraints on each query.
    override func layout() {
        super.layout()
        let frames = PickerGeometry.rowFrames(width: bounds.width, depth: tree.depth)
        textFrames = frames
        symbol.frame = frames.symbol
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if separatesGroup {
            NSColor.white.withAlphaComponent(0.045).setFill()
            NSRect(x: 24, y: 0, width: max(0, bounds.width - 48), height: 1).fill()
        }
        let lines = NSBezierPath()
        lines.lineWidth = 1
        let middle = bounds.midY
        func vertical(_ column: Int, _ from: CGFloat, _ to: CGFloat) {
            let x = Self.rootCenter + CGFloat(column) * Self.indent + 0.5
            lines.move(to: NSPoint(x: x, y: from))
            lines.line(to: NSPoint(x: x, y: to))
        }
        for column in tree.ancestorContinuations { vertical(column, 0, bounds.height) }
        if tree.depth > 0 {
            vertical(tree.depth - 1, 0, tree.hasNextSibling ? bounds.height : middle)
            let x = Self.rootCenter + CGFloat(tree.depth - 1) * Self.indent + 0.5
            lines.move(to: NSPoint(x: x, y: middle))
            lines.line(to: NSPoint(x: x + Self.indent - 11, y: middle))
        }
        if tree.hasChildren { vertical(tree.depth, middle + 11, bounds.height) }
        Palette.secondary.withAlphaComponent(0.28).setStroke()
        lines.stroke()
        primary.draw(withFrame: textFrames.title, in: self)
        if textFrames.path.width > 0 { path.draw(withFrame: textFrames.path, in: self) }
        kind.draw(withFrame: textFrames.kind, in: self)
        if isCurrent {
            Palette.accent.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: textFrames.current).fill()
        }
    }

    @discardableResult
    func configure(_ item: PickerItem, tree: PickerTreePosition, separatesGroup: Bool) -> Bool {
        // Most incremental queries retain many visible rows. Keep their
        // attributed strings and accessibility values until metadata or tree
        // position actually changes; resizing still invokes normal layout.
        guard configuredItem != item || self.tree != tree || self.separatesGroup != separatesGroup else { return false }
        configuredItem = item
        self.tree = tree
        self.separatesGroup = separatesGroup
        primary.font = item.kind == "session" ? Self.sessionFont : Self.titleFont
        primary.textColor = item.contextOnly ? Palette.secondary : Palette.text
        // Keep editable pane labels visible even when the terminal publishes a
        // conversation title; otherwise a successful rename appears to do nothing.
        let identity = item.kind == "pane" && !item.name.isEmpty ? item.name : item.title
        let detail = item.combined ? item.detail : identity != item.title ? item.title : ""
        if !detail.isEmpty && detail != identity {
            let title = NSMutableAttributedString(string: identity, attributes: [.font: Self.titleFont, .paragraphStyle: Self.truncatedTitleStyle, .foregroundColor: item.contextOnly ? Palette.secondary : Palette.text])
            title.append(NSAttributedString(string: "  ·  " + detail, attributes: [.font: Self.titleFont, .paragraphStyle: Self.truncatedTitleStyle, .foregroundColor: Palette.secondary]))
            primary.attributedStringValue = title
        } else { primary.stringValue = identity }
        path.stringValue = item.path
        kind.stringValue = item.attention ? (item.agentState == "approve" ? "APPROVAL" : "INPUT") : item.kindLabel
        kind.textColor = item.attention ? Palette.accent : Palette.faint
        isCurrent = item.current
        symbol.contentTintColor = item.kind == "session" && !item.contextOnly ? Palette.accent : Palette.secondary
        alphaValue = item.contextOnly ? 0.72 : 1
        let image = Self.images[item.symbol]
        if symbol.image !== image { symbol.image = image }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(identity)\(identity != item.title ? ", " + item.title : ""), \(item.kindLabel)\(item.combined ? ", single pane: " + item.detail : ""), level \(tree.depth + 1), \(item.subtitle), \(item.path)\(item.current ? ", current" : "")\(item.contextOnly ? ", parent context" : "")\(item.attention ? ", needs " + (item.agentState == "approve" ? "approval" : "input") : "")")
        toolTip = [identity, item.title, item.detail, item.subtitle, item.path, item.agentState ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        needsLayout = true
        needsDisplay = true
        return true
    }
}

final class ScopeButton: NSButton {
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor.white.withAlphaComponent(0.065).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: chosen ? .semibold : .regular),
            .foregroundColor: (chosen ? Palette.text : Palette.secondary).withAlphaComponent(isEnabled ? 1 : 0.4)
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class PickerView: NSView {
    let search = NSTextField()
    let table = PickerTable()
    let scroll = NSScrollView()
    let count = label("", size: 10, color: Palette.faint)
    let status = label("Connecting to Rex…", size: 11, color: Palette.secondary)
    let emptyTitle = label("Loading your workspace", size: 17, weight: .medium)
    let emptyDetail = label("Sessions, tabs and panes, together.", size: 12, color: Palette.secondary)
    let empty = NSStackView()
    var scopes: [ScopeButton] = []
    let clear = NSButton()
    let actions = ScopeButton(title: "Actions  ⌘K", target: nil, action: nil)
    let dashboardButton = ScopeButton(title: "‹ Dashboard", target: nil, action: nil)
    private let origin = label("REX  /  QUICK SWITCH", size: 9, weight: .medium, color: Palette.faint)
    private let shortcuts = label("↑↓ navigate   ↩ switch   esc close", size: 10, color: Palette.faint)
    let previewButton = ScopeButton(title: "Preview  ⌘P", target: nil, action: nil)
    let searchField = NSPopUpButton(frame: .zero, pullsDown: false)
    let directoryUp = NSButton()
    let directoryHome = ScopeButton(title: "Recents", target: nil, action: nil)
    let directoryDeep = ScopeButton(title: "Deep search", target: nil, action: nil)
    private let directoryPath = label("Recent projects", size: 10.5, color: Palette.secondary)
    private let directoryBar = NSView()
    private let resultsArea = NSView()
    private let preview = PickerPreviewView(frame: .zero)
    private var directoryHeight: NSLayoutConstraint!
    private(set) var previewVisible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        // The old 95%-opaque wash hid the blur while retaining a full-window
        // WindowServer backdrop dependency. A solid surface keeps the same
        // Gruvbox appearance without recompositing the terminal underneath.
        layer?.backgroundColor = Palette.background.cgColor

        let brandIcon = icon("square.stack.3d.up", size: 12, color: Palette.accent)
        let brand = label("INTERDIMUX", size: 10, weight: .semibold, color: Palette.secondary)
        let glass = icon("magnifyingglass", size: 20, color: Palette.accent)
        for view in [brandIcon, brand, origin, glass, search, clear, searchField, count, directoryBar, resultsArea, status, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        search.font = .systemFont(ofSize: 23, weight: .regular)
        search.textColor = Palette.text
        search.drawsBackground = false
        search.isBordered = false
        search.focusRingType = .none
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        search.placeholderAttributedString = NSAttributedString(string: "Where do you want to go?", attributes: [.foregroundColor: Palette.faint, .font: NSFont.systemFont(ofSize: 23, weight: .regular)])
        search.setAccessibilityLabel("Search sessions, tabs, panes and projects")
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")
        clear.isBordered = false
        clear.contentTintColor = Palette.faint
        clear.isHidden = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.bezelStyle = .rounded
        searchField.setAccessibilityLabel("Search field")
        searchField.toolTip = "Choose which fields to search"
        for (title, field) in [("All fields", "all"), ("Names", "name"), ("Paths", "path"), ("Commands", "command")] {
            searchField.addItem(withTitle: title)
            searchField.lastItem?.representedObject = field
        }
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.spacing = 4
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        let scopeWidths: [CGFloat] = [48, 76, 50, 54, 110, 76]
        for (index, title) in ["All", "Sessions", "Tabs", "Panes", "Attention 0", "Projects"].enumerated() {
            let button = ScopeButton(title: title, target: nil, action: nil)
            button.isBordered = false
            button.tag = index
            button.chosen = index == 0
            button.setAccessibilityLabel("\(title), Command \(index + 1)")
            button.toolTip = "⌘\(index + 1)"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: scopeWidths[index]).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tabs.addArrangedSubview(button)
            scopes.append(button)
        }
        let separator = NSView(), footerLine = NSView()
        for line in [separator, footerLine] {
            line.translatesAutoresizingMaskIntoConstraints = false
            line.wantsLayer = true
            line.layer?.backgroundColor = Palette.line.cgColor
            addSubview(line)
            line.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            line.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        addSubview(shortcuts)
        for button in [actions, previewButton, dashboardButton] {
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        actions.setAccessibilityLabel("Actions, Command K")
        dashboardButton.isHidden = true
        dashboardButton.setAccessibilityLabel("Back to dashboard")
        dashboardButton.toolTip = "Return to dashboard (Escape)"
        previewButton.setAccessibilityLabel("Toggle preview, Command P")
        previewButton.toolTip = "Show or hide the inline preview (⌘P)"
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate")))
        table.headerView = nil
        table.rowHeight = 38
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.setAccessibilityLabel("Sessions, tabs, panes and projects")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        resultsArea.addSubview(scroll)
        resultsArea.addSubview(preview)
        preview.isHidden = true
        preview.onCancel = { [weak self] in self?.table.onCancel?() }

        directoryBar.isHidden = true
        directoryHeight = directoryBar.heightAnchor.constraint(equalToConstant: 0)
        directoryHeight.isActive = true
        directoryUp.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Parent directory")
        directoryUp.contentTintColor = Palette.secondary
        directoryUp.toolTip = "Parent directory (⌘←)"
        directoryHome.setAccessibilityLabel("Recent projects")
        directoryDeep.setAccessibilityLabel("Search subdirectories, Control F")
        directoryDeep.toolTip = "Search subdirectories (⌃F)"
        directoryPath.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        directoryPath.lineBreakMode = .byTruncatingHead
        directoryPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [directoryUp, directoryHome, directoryPath, directoryDeep] {
            view.translatesAutoresizingMaskIntoConstraints = false
            directoryBar.addSubview(view)
        }
        for button in [directoryUp, directoryHome, directoryDeep] { button.isBordered = false }
        NSLayoutConstraint.activate([
            directoryUp.leadingAnchor.constraint(equalTo: directoryBar.leadingAnchor, constant: 22),
            directoryUp.centerYAnchor.constraint(equalTo: directoryBar.centerYAnchor),
            directoryUp.widthAnchor.constraint(equalToConstant: 26), directoryUp.heightAnchor.constraint(equalToConstant: 26),
            directoryHome.leadingAnchor.constraint(equalTo: directoryUp.trailingAnchor, constant: 4),
            directoryHome.centerYAnchor.constraint(equalTo: directoryBar.centerYAnchor),
            directoryHome.widthAnchor.constraint(equalToConstant: 66), directoryHome.heightAnchor.constraint(equalToConstant: 26),
            directoryPath.leadingAnchor.constraint(equalTo: directoryHome.trailingAnchor, constant: 12),
            directoryPath.centerYAnchor.constraint(equalTo: directoryBar.centerYAnchor),
            directoryPath.trailingAnchor.constraint(lessThanOrEqualTo: directoryDeep.leadingAnchor, constant: -12),
            directoryDeep.trailingAnchor.constraint(equalTo: directoryBar.trailingAnchor, constant: -18),
            directoryDeep.centerYAnchor.constraint(equalTo: directoryBar.centerYAnchor),
            directoryDeep.widthAnchor.constraint(equalToConstant: 92), directoryDeep.heightAnchor.constraint(equalToConstant: 26)
        ])
        empty.orientation = .vertical
        empty.spacing = 10
        empty.addArrangedSubview(icon("sparkle.magnifyingglass", size: 26, color: Palette.faint))
        empty.addArrangedSubview(emptyTitle)
        empty.addArrangedSubview(emptyDetail)
        NSLayoutConstraint.activate([
            brandIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26), brandIcon.topAnchor.constraint(equalTo: topAnchor, constant: 23), brandIcon.widthAnchor.constraint(equalToConstant: 14), brandIcon.heightAnchor.constraint(equalToConstant: 14),
            brand.leadingAnchor.constraint(equalTo: brandIcon.trailingAnchor, constant: 8), brand.centerYAnchor.constraint(equalTo: brandIcon.centerYAnchor),
            dashboardButton.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 18), dashboardButton.centerYAnchor.constraint(equalTo: brand.centerYAnchor), dashboardButton.widthAnchor.constraint(equalToConstant: 100), dashboardButton.heightAnchor.constraint(equalToConstant: 26),
            origin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27), origin.centerYAnchor.constraint(equalTo: brand.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27), glass.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 26), glass.widthAnchor.constraint(equalToConstant: 23), glass.heightAnchor.constraint(equalToConstant: 26),
            search.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -10), search.centerYAnchor.constraint(equalTo: glass.centerYAnchor), search.heightAnchor.constraint(equalToConstant: 34),
            clear.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -14), clear.centerYAnchor.constraint(equalTo: glass.centerYAnchor), clear.widthAnchor.constraint(equalToConstant: 24), clear.heightAnchor.constraint(equalToConstant: 24),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25), searchField.centerYAnchor.constraint(equalTo: glass.centerYAnchor), searchField.widthAnchor.constraint(equalToConstant: 136), searchField.heightAnchor.constraint(equalToConstant: 26),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22), tabs.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 20),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27), count.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: tabs.trailingAnchor, constant: 12),
            separator.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14),
            directoryBar.topAnchor.constraint(equalTo: separator.bottomAnchor), directoryBar.leadingAnchor.constraint(equalTo: leadingAnchor), directoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsArea.topAnchor.constraint(equalTo: directoryBar.bottomAnchor, constant: 7), resultsArea.leadingAnchor.constraint(equalTo: leadingAnchor), resultsArea.trailingAnchor.constraint(equalTo: trailingAnchor), resultsArea.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -7),
            footerLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -42),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25), status.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: shortcuts.leadingAnchor, constant: -15),
            shortcuts.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -12), shortcuts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            previewButton.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6), previewButton.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), previewButton.widthAnchor.constraint(equalToConstant: 106), previewButton.heightAnchor.constraint(equalToConstant: 28),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17), actions.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), actions.widthAnchor.constraint(equalToConstant: 94), actions.heightAnchor.constraint(equalToConstant: 28),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -64)
        ])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyDetail.maximumNumberOfLines = 3
        emptyDetail.lineBreakMode = .byWordWrapping
        emptyDetail.alignment = .center
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let frames = PickerGeometry.contentFrames(in: resultsArea.bounds, preview: previewVisible)
        scroll.frame = frames.list
        preview.frame = frames.preview
        if table.frame.width != scroll.contentSize.width {
            table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        if !visible, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: preview) {
            window?.makeFirstResponder(search)
        }
        previewVisible = visible
        preview.isHidden = !visible
        previewButton.chosen = visible
        needsLayout = true
    }

    func setDashboardRoute(_ title: String?) {
        dashboardButton.isHidden = title == nil
        origin.stringValue = "REX  /  " + (title?.uppercased() ?? "QUICK SWITCH")
        shortcuts.stringValue = title == nil ? "↑↓ navigate   ↩ switch   esc close" : "↑↓ navigate   ↩ choose   esc back"
    }

    func showPreview(title: String, detail: String, text: String, loading: Bool = false) {
        preview.show(title: title, detail: detail, text: text, loading: loading)
    }

    func setDirectoryVisible(_ visible: Bool) {
        directoryBar.isHidden = !visible
        directoryHeight.constant = visible ? 36 : 0
        needsLayout = true
    }

    func setDirectoryLocation(path: String?, deep: Bool) {
        directoryPath.stringValue = path ?? "Recent projects"
        directoryPath.toolTip = path ?? "Recent projects and configured project roots"
        directoryUp.isEnabled = path != nil && path != "/"
        directoryDeep.chosen = deep
    }
}
