import AppKit

enum Palette {
    private static var backgroundValue = NSColor(srgbRed: 36/255, green: 37/255, blue: 35/255, alpha: 1)
    private static var foregroundValue = NSColor(srgbRed: 221/255, green: 213/255, blue: 197/255, alpha: 1)
    private static var accentValue = NSColor(srgbRed: 231/255, green: 138/255, blue: 78/255, alpha: 1)
    private static var secondaryValue = subdued(dark: 0.34, light: 0.18)
    private static var faintValue = subdued(dark: 0.42, light: 0.24)

    private static func subdued(dark: CGFloat, light: CGFloat) -> NSColor {
        let fraction = backgroundValue.brightnessComponent > foregroundValue.brightnessComponent ? light : dark
        return foregroundValue.blended(withFraction: fraction, of: backgroundValue) ?? foregroundValue
    }

    // Keep the color objects themselves stable: labels, icons and cached
    // attributed row titles must resolve the current palette when redrawn.
    static let accent = NSColor(name: nil) { _ in accentValue }
    static let text = NSColor(name: nil) { _ in foregroundValue }
    static let secondary = NSColor(name: nil) { _ in secondaryValue }
    static let faint = NSColor(name: nil) { _ in faintValue }
    static let background = NSColor(name: nil) { _ in backgroundValue }
    static let line = NSColor(name: nil) { _ in foregroundValue.withAlphaComponent(0.10) }
    static let border = NSColor(name: nil) { _ in foregroundValue.withAlphaComponent(0.14) }
    static let insetBackground = NSColor(name: nil) { _ in backgroundValue.blended(withFraction: 0.035, of: foregroundValue) ?? backgroundValue }

    @discardableResult
    static func apply(background: NSColor, foreground: NSColor, accent: NSColor) -> Bool {
        guard let background = background.usingColorSpace(.sRGB),
              let foreground = foreground.usingColorSpace(.sRGB),
              let accent = accent.usingColorSpace(.sRGB) else { return false }
        guard background != backgroundValue || foreground != foregroundValue || accent != accentValue else { return false }
        backgroundValue = background
        foregroundValue = foreground
        accentValue = accent
        secondaryValue = subdued(dark: 0.34, light: 0.18)
        faintValue = subdued(dark: 0.42, light: 0.24)
        return true
    }

    static func invalidate(view: NSView) {
        view.needsDisplay = true
        for child in view.subviews { invalidate(view: child) }
    }
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

extension NSEvent {
    var pickerModifiers: ModifierFlags {
        var flags = modifierFlags.intersection([.command, .option, .control, .shift, .function])
        // AppKit sets .function on physical arrow keys, even with Fn released.
        if (123...126).contains(keyCode) { flags.remove(.function) }
        return flags
    }
}

final class PickerPanel: NSPanel {
    var onCommand: ((String) -> Bool)?
    var onShortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true { return true }
        if event.pickerModifiers == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), onCommand?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class PickerTable: NSTableView {
    var onNavigate: ((Int) -> Void)?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onType: ((NSEvent) -> Void)?
    var onRowMenu: ((Int, NSEvent) -> Void)?
    var onBranch: ((Bool) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
    override func rightMouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { onRowMenu?(index, event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if (123...124).contains(event.keyCode), event.pickerModifiers.isEmpty, let onBranch {
            onBranch(event.keyCode == 124)
            return
        }
        switch event.keyCode {
        case 125: onNavigate?(1)
        case 126: onNavigate?(-1)
        case 36, 76: onAccept?()
        case 53: onCancel?()
        case 48: super.keyDown(with: event)
        default: onType?(event)
        }
    }
}

final class PickerRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 9, dy: 2)
        Palette.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        Palette.accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 9, y: 10, width: 3, height: bounds.height - 20), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class PickerCell: NSTableCellView, NSViewToolTipOwner {
    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["terminal", "macwindow", "square.stack.3d.up", "folder", "plus.circle"] {
            images[name] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        return images
    }()
    let symbol = NSImageView()
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let sessionFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
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
    let kind = PickerCell.textCell(size: 10.5, color: Palette.faint)
    private(set) var isCurrent = false
    private(set) var textFrames = PickerGeometry.rowFrames(width: 0, depth: 0)
    private var configuredItem: PickerItem?
    private var toolTipRect = NSRect.zero
    private var toolTipTag: NSView.ToolTipTag?
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
        kind.font = .systemFont(ofSize: 10.5, weight: .regular)
        kind.alignment = .right
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Rows have a fixed height and bounded columns. Frame layout avoids
    // re-solving hundreds of intrinsic text-size constraints on each query.
    override func layout() {
        super.layout()
        let frames = PickerGeometry.rowFrames(width: bounds.width, depth: tree.depth, project: configuredItem?.kind == "directory")
        textFrames = frames
        symbol.frame = frames.symbol
        if toolTipRect != bounds {
            if let toolTipTag { removeToolTip(toolTipTag) }
            toolTipRect = bounds
            toolTipTag = bounds.isEmpty ? nil : addToolTip(bounds, owner: self, userData: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if separatesGroup, configuredItem?.kind == "session" {
            Palette.text.withAlphaComponent(0.045).setFill()
            NSRect(x: 24, y: 0, width: max(0, bounds.width - 48), height: 1).fill()
        }
        if tree.hasChildren || tree.depth > 0 { drawBranches() }
        primary.draw(withFrame: textFrames.title, in: self)
        if textFrames.path.width > 0 && !path.stringValue.isEmpty { path.draw(withFrame: textFrames.path, in: self) }
        kind.draw(withFrame: textFrames.kind, in: self)
        if isCurrent {
            Palette.accent.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: textFrames.current).fill()
        }
    }

    private func drawBranches() {
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
    }

    @discardableResult
    func configure(_ item: PickerItem, tree: PickerTreePosition, separatesGroup: Bool) -> Bool {
        // Most incremental queries retain many visible rows. Keep their
        // attributed strings and accessibility values until metadata or tree
        // position actually changes; resizing still invokes normal layout.
        let previous = configuredItem
        guard previous != item || self.tree != tree || self.separatesGroup != separatesGroup else { return false }
        if previous == nil || tree.depth != self.tree.depth || (previous?.kind == "directory") != (item.kind == "directory") {
            needsLayout = true
        }
        configuredItem = item
        self.tree = tree
        self.separatesGroup = separatesGroup
        if previous?.kind != item.kind {
            primary.font = item.kind == "session" ? Self.sessionFont : Self.titleFont
            symbol.image = Self.images[item.symbol]
        }
        if previous?.contextOnly != item.contextOnly {
            primary.textColor = item.contextOnly ? Palette.secondary : Palette.text
            alphaValue = item.contextOnly ? 0.72 : 1
        }
        if previous?.kind != item.kind || previous?.contextOnly != item.contextOnly {
            symbol.contentTintColor = item.kind == "session" && !item.contextOnly ? Palette.accent : Palette.secondary
        }
        let identity = item.rowTitle
        let host = item.hostLabel
        let detail = host ?? (item.combined ? item.detail : identity != item.title ? item.title : "")
        if !detail.isEmpty && (host != nil || detail != identity) {
            let identityFont = item.kind == "session" ? Self.sessionFont : Self.titleFont
            let title = NSMutableAttributedString(string: identity, attributes: [.font: identityFont, .paragraphStyle: Self.truncatedTitleStyle, .foregroundColor: item.contextOnly ? Palette.secondary : Palette.text])
            title.append(NSAttributedString(string: "  ·  " + detail, attributes: [.font: Self.titleFont, .paragraphStyle: Self.truncatedTitleStyle, .foregroundColor: Palette.secondary]))
            primary.attributedStringValue = title
        } else { primary.stringValue = identity }
        // The leading column already displays the project name. Reserve the
        // path column's visible suffix for the parent that distinguishes it.
        if item.kind == "directory", let slash = item.path.lastIndex(of: "/"),
           item.path[item.path.index(after: slash)...] == identity {
            path.stringValue = slash == item.path.startIndex ? "/" : String(item.path[..<slash])
        } else {
            path.stringValue = item.path
        }
        let caption = item.attention ? (item.agentState == "approve" ? "Approval" : "Input") : item.kindLabel
        if kind.stringValue != caption { kind.stringValue = caption }
        if previous?.attention != item.attention { kind.textColor = item.attention ? Palette.accent : Palette.faint }
        isCurrent = item.current
        needsDisplay = true
        return true
    }

    // Native hover and accessibility callbacks can read the current reused
    // cell directly instead of building two descriptions on every keystroke.
    override func accessibilityLabel() -> String? {
        guard let item = configuredItem else { return super.accessibilityLabel() }
        let identity = item.rowTitle
        let host = item.hostLabel
        let subtitle = host == nil ? item.subtitle : ""
        return "\(identity)\(identity != item.title ? ", " + item.title : ""), \(item.kindLabel)\(item.combined ? ", single pane: " + item.detail : "")\(host.map { ", host " + $0 } ?? ""), level \(tree.depth + 1), \(subtitle), \(item.path)\(item.current ? ", current" : "")\(item.contextOnly ? ", parent context" : "")\(item.attention ? ", needs " + (item.agentState == "approve" ? "approval" : "input") : "")"
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let item = configuredItem else { return "" }
        let identity = item.rowTitle
        let context = item.hostLabel ?? item.subtitle
        return [identity, identity == item.title ? "" : item.title, context, item.detail, item.path, item.agentState ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

final class ScopeButton: NSButton {
    var chosen = false {
        didSet {
            guard chosen != oldValue else { return }
            state = chosen ? .on : .off
            needsDisplay = true
        }
    }
    var scopeTab = false
    var shortcut: String?
    override func draw(_ dirtyRect: NSRect) {
        let activeTab = scopeTab && chosen
        if isHighlighted || (chosen && !scopeTab) {
            Palette.text.withAlphaComponent(isHighlighted ? 0.12 : 0.075).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: chosen ? .semibold : .regular),
            .foregroundColor: (chosen || shortcut != nil ? Palette.text : Palette.secondary)
                .withAlphaComponent(isEnabled ? 1 : 0.4)
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let midY = bounds.midY
        let shortcutWidth: CGFloat = shortcut == nil ? 0 : 32
        let left = floor((bounds.width - size.width - shortcutWidth) / 2)
        (title as NSString).draw(at: NSPoint(x: left, y: floor(midY - size.height / 2)), withAttributes: attrs)
        if activeTab {
            Palette.accent.setFill()
            NSRect(x: max(4, left - 4), y: isFlipped ? bounds.maxY - 2 : 0,
                   width: min(bounds.width - 8, ceil(size.width + 8)), height: 2).fill()
        }
        if let shortcut {
            let key = NSRect(x: left + ceil(size.width) + 6, y: midY - 8, width: 26, height: 16)
            Palette.text.withAlphaComponent(0.075).setFill()
            NSBezierPath(roundedRect: key, xRadius: 4, yRadius: 4).fill()
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Palette.secondary.withAlphaComponent(isEnabled ? 1 : 0.4)
            ]
            let keySize = (shortcut as NSString).size(withAttributes: keyAttrs)
            (shortcut as NSString).draw(at: NSPoint(x: floor(key.midX - keySize.width / 2),
                                                    y: floor(key.midY - keySize.height / 2)), withAttributes: keyAttrs)
        }
    }
}

final class PickerView: NSView {
    let search = NSTextField()
    let table = PickerTable()
    let scroll = NSScrollView()
    let count = label("", size: 10, color: Palette.faint)
    let status = label("Connecting to Rex…", size: 11, color: Palette.secondary)
    let emptyTitle = label("Loading your workspace", size: 17, weight: .medium)
    let emptyDetail = label("Fetching sessions and projects…", size: 12, color: Palette.secondary)
    let empty = NSStackView()
    var scopes: [ScopeButton] = []
    let clear = NSButton()
    let actions = ScopeButton(title: "Actions", target: nil, action: nil)
    let dashboardButton = NSButton()
    private let glass = icon("magnifyingglass", size: 20, color: Palette.secondary)
    private var dashboardRoute: String?
    private let shortcuts = label("↑↓ Navigate     ↩ Switch", size: 11, color: Palette.secondary)
    let previewButton = ScopeButton(title: "Preview", target: nil, action: nil)
    let searchField = NSPopUpButton(frame: .zero, pullsDown: false)
    let directoryUp = NSButton()
    let directoryHome = ScopeButton(title: "Recents", target: nil, action: nil)
    let directoryDeep = ScopeButton(title: "Deep search", target: nil, action: nil)
    private let directoryPath = label("Recent projects", size: 10.5, color: Palette.secondary)
    private let directoryBar = NSView()
    private let resultsArea = NSView()
    private let preview = PickerPreviewView(frame: .zero)
    private var separatorViews: [NSView] = []
    private var directoryHeight: NSLayoutConstraint!
    private(set) var previewVisible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderColor = Palette.border.cgColor
        layer?.borderWidth = 1
        // A solid themed surface avoids a full-window backdrop dependency.
        layer?.backgroundColor = Palette.background.cgColor

        for view in [glass, search, clear, searchField, count, directoryBar, resultsArea, status, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        search.font = .systemFont(ofSize: 22, weight: .regular)
        search.textColor = Palette.text
        search.drawsBackground = false
        search.isBordered = false
        search.focusRingType = .none
        search.cell?.isScrollable = true
        search.cell?.wraps = false
        search.setAccessibilityHelp("Press Tab to focus the results.")
        search.toolTip = "Press Tab to focus the results. Use Left and Right to move between parents and children."
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")
        clear.isBordered = false
        clear.contentTintColor = Palette.faint
        clear.isHidden = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.bezelStyle = .rounded
        searchField.isBordered = false
        searchField.setAccessibilityLabel("Search field")
        searchField.toolTip = "Choose which fields to search"
        for (title, field) in [("All fields", "all"), ("Names", "name"), ("Paths", "path"), ("Commands", "command")] {
            searchField.addItem(withTitle: title)
            searchField.lastItem?.representedObject = field
        }
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.spacing = 2
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        let scopeWidths: [CGFloat] = [40, 70, 48, 52, 98, 68]
        for (index, title) in ["All", "Sessions", "Tabs", "Panes", "Attention", "Projects"].enumerated() {
            let button = ScopeButton(title: title, target: nil, action: nil)
            button.isBordered = false
            button.scopeTab = true
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
        separatorViews = [separator, footerLine]
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
        actions.shortcut = "⌘K"
        previewButton.shortcut = "⌘P"
        dashboardButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        dashboardButton.contentTintColor = Palette.text
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
        table.setAccessibilityHelp("Use the Up and Down arrows to navigate, Left to select a parent, or Right to select a child. Press Return to choose.")
        table.onFocusChange = { [weak self] in self?.updateShortcutHints(resultsFocused: $0) }
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
        updateSearchContext()
        directoryHeight = directoryBar.heightAnchor.constraint(equalToConstant: 0)
        directoryHeight.isActive = true
        directoryUp.isEnabled = false
        directoryUp.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Parent directory")
        directoryUp.contentTintColor = Palette.secondary
        directoryUp.toolTip = "Parent directory (⌘←)"
        directoryHome.setAccessibilityLabel("Recent projects")
        directoryDeep.setAccessibilityLabel("Search subdirectories, Control F")
        directoryDeep.toolTip = "Search subdirectories (⌃F)"
        directoryPath.toolTip = "Recent projects and configured project roots"
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
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25), glass.topAnchor.constraint(equalTo: topAnchor, constant: 22), glass.widthAnchor.constraint(equalToConstant: 21), glass.heightAnchor.constraint(equalToConstant: 24),
            dashboardButton.centerXAnchor.constraint(equalTo: glass.centerXAnchor), dashboardButton.centerYAnchor.constraint(equalTo: glass.centerYAnchor), dashboardButton.widthAnchor.constraint(equalToConstant: 30), dashboardButton.heightAnchor.constraint(equalToConstant: 30),
            search.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12), search.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -6), search.centerYAnchor.constraint(equalTo: glass.centerYAnchor), search.heightAnchor.constraint(equalToConstant: 32),
            clear.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8), clear.centerYAnchor.constraint(equalTo: glass.centerYAnchor), clear.widthAnchor.constraint(equalToConstant: 22), clear.heightAnchor.constraint(equalToConstant: 24),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), searchField.centerYAnchor.constraint(equalTo: glass.centerYAnchor), searchField.widthAnchor.constraint(equalToConstant: 98), searchField.heightAnchor.constraint(equalToConstant: 26),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), tabs.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 11),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25), count.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: tabs.trailingAnchor, constant: 8),
            separator.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            directoryBar.topAnchor.constraint(equalTo: separator.bottomAnchor), directoryBar.leadingAnchor.constraint(equalTo: leadingAnchor), directoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsArea.topAnchor.constraint(equalTo: directoryBar.bottomAnchor, constant: 7), resultsArea.leadingAnchor.constraint(equalTo: leadingAnchor), resultsArea.trailingAnchor.constraint(equalTo: trailingAnchor), resultsArea.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -7),
            footerLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -42),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25), status.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: shortcuts.leadingAnchor, constant: -15),
            shortcuts.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -12), shortcuts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            previewButton.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6), previewButton.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), previewButton.widthAnchor.constraint(equalToConstant: 92), previewButton.heightAnchor.constraint(equalToConstant: 28),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17), actions.centerYAnchor.constraint(equalTo: shortcuts.centerYAnchor), actions.widthAnchor.constraint(equalToConstant: 90), actions.heightAnchor.constraint(equalToConstant: 28),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -64)
        ])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyDetail.maximumNumberOfLines = 3
        emptyDetail.lineBreakMode = .byWordWrapping
        emptyDetail.alignment = .center
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshTheme() {
        // CGColors are resolved values, unlike the dynamic NSColors retained
        // by controls. Replace these whenever Rex's palette changes.
        layer?.backgroundColor = Palette.background.cgColor
        layer?.borderColor = Palette.border.cgColor
        for line in separatorViews { line.layer?.backgroundColor = Palette.line.cgColor }
        preview.refreshTheme()
        Palette.invalidate(view: self)
    }

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
        guard dashboardRoute != title else { return }
        dashboardRoute = title
        dashboardButton.isHidden = title == nil
        glass.isHidden = title != nil
        updateSearchContext()
    }

    private func updateSearchContext() {
        let prompt: String
        if let dashboardRoute {
            prompt = dashboardRoute + " · Search targets…"
            search.setAccessibilityLabel("Search targets for " + dashboardRoute)
        } else if directoryBar.isHidden {
            prompt = "Search your workspace…"
            search.setAccessibilityLabel("Search sessions, tabs, panes and projects")
        } else {
            prompt = "Search projects…"
            search.setAccessibilityLabel("Search projects")
        }
        let font = search.font ?? .systemFont(ofSize: 22)
        search.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [.foregroundColor: Palette.secondary, .font: font])
        updateShortcutHints(resultsFocused: window?.firstResponder === table)
    }

    private func updateShortcutHints(resultsFocused: Bool) {
        let hint = resultsFocused && scopes.first?.chosen == true ? "←→ Tree     ↩ Switch" : "↑↓ Navigate     ↩ Switch"
        shortcuts.stringValue = directoryBar.isHidden && dashboardRoute == nil ? hint : ""
    }

    func showPreview(title: String, detail: String, text: String, loading: Bool = false) {
        preview.show(title: title, detail: detail, text: text, loading: loading)
    }

    func setDirectoryVisible(_ visible: Bool) {
        guard directoryBar.isHidden == visible else { return }
        directoryBar.isHidden = !visible
        updateSearchContext()
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
