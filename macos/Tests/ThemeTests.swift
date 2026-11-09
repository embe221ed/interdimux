import AppKit

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
private func components(_ color: NSColor) -> [CGFloat] {
    let color = color.usingColorSpace(.sRGB)!
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}
private func equal(_ left: NSColor, _ right: NSColor) -> Bool {
    zip(components(left), components(right)).allSatisfy { abs($0 - $1) < 0.001 }
}
private func equal(_ left: CGColor?, _ right: NSColor) -> Bool {
    guard let left, let color = NSColor(cgColor: left) else { return false }
    return equal(color, right)
}
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
private func luminance(_ color: NSColor) -> CGFloat {
    let rgb = components(color).prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
}

private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items = [
        PickerItem(["id": "session:previous", "kind": "session", "title": "Previous session", "subtitle": "1 tab"])!,
        PickerItem(["id": "window:combined", "parent_id": "session:previous", "kind": "window", "title": "Editor", "detail": "Theme updates preserve cached metadata", "combined": true, "path": "/Users/fixture/project"])!,
        PickerItem(["id": "session:current", "kind": "session", "title": "Current session", "current": true, "subtitle": "1 tab"])!
    ]
    lazy var positions = PickerTreeLayout.positions(for: items)
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = PickerCell()
        cell.configure(items[row], tree: positions[row], separatesGroup: row == 2)
        return cell
    }
}

@main
struct ThemeTests {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let picker = PickerView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        let dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 940, height: 680))
        let windows = [picker, dashboard].map { view -> NSWindow in
            let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            return window
        }
        defer { for window in windows { window.close() } }
        let rows = Rows()
        picker.table.dataSource = rows
        picker.table.delegate = rows
        picker.empty.isHidden = true
        picker.count.stringValue = "3 places"
        picker.status.stringValue = "3 places · ⌘R refresh"
        picker.setPreviewVisible(true)
        picker.showPreview(title: "Theme preview", detail: "/Users/fixture/project", text: "$ cargo test\nTheme switching keeps text, selection, borders and previews readable.\n東京 👩🏽‍💻")
        picker.layoutSubtreeIfNeeded()
        picker.table.reloadData()
        picker.layoutSubtreeIfNeeded()
        picker.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let cell = picker.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as! PickerCell
        let oldTitleColor = cell.primary.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        let oldDetailColor = cell.primary.attributedStringValue.attribute(.foregroundColor, at: cell.primary.attributedStringValue.length - 1, effectiveRange: nil) as! NSColor
        let oldAccent = Palette.accent.withAlphaComponent(0.25)
        dashboard.updateSummary(DashboardSummary(counts: ["sessions": 3, "tabs": 6, "panes": 8, "attention": 1]))
        let themes: [(String, NSColor, NSColor, NSColor, NSAppearance.Name)] = [
            ("dark", NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1), NSColor(srgbRed: 0.92, green: 0.90, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.94, green: 0.54, blue: 0.30, alpha: 1), .darkAqua),
            ("light", NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.60, green: 0.24, blue: 0.08, alpha: 1), .aqua),
            ("custom", NSColor(srgbRed: 0.04, green: 0.13, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.65, green: 0.84, blue: 0.59, alpha: 1), .darkAqua)
        ]
        let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : nil
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for (name, background, foreground, accent, appearance) in themes {
            try check(Palette.apply(background: background, foreground: foreground, accent: accent), "\(name): changed palette was ignored")
            try check(!Palette.apply(background: background, foreground: foreground, accent: accent), "\(name): identical palette caused a refresh")
            for window in windows { window.appearance = NSAppearance(named: appearance) }
            picker.refreshTheme()
            dashboard.refreshTheme()
            try check(equal(oldTitleColor, foreground) && equal(oldDetailColor, Palette.secondary), "\(name): cached attributed title retained old colors")
            try check(equal(oldAccent, accent.withAlphaComponent(0.25)), "\(name): derived accent retained old color")
            try check(equal(picker.search.textColor!, foreground) && equal(cell.primary.textColor!, foreground), "\(name): existing controls retained old foreground")
            try check(equal(cell.path.textColor!, Palette.faint), "\(name): cached path retained old color")
            try check(!cell.configure(rows.items[1], tree: rows.positions[1], separatesGroup: false), "Theme update invalidated row metadata unnecessarily")
            try check(picker.table.view(atColumn: 0, row: 1, makeIfNecessary: false) === cell, "Theme update replaced cached row")
            try check(equal(picker.layer?.backgroundColor, background) && equal(dashboard.layer?.backgroundColor, background), "\(name): outer CG surface retained old background")
            try check(equal(picker.layer?.borderColor, Palette.border) && equal(dashboard.layer?.borderColor, Palette.border), "\(name): outer CG border retained old color")
            let preview = descendants(picker).first { $0 is PickerPreviewView }!
            try check(equal(preview.layer?.backgroundColor, Palette.insetBackground), "\(name): preview CG surface retained old color")
            let previewText = descendants(preview).compactMap { $0 as? NSTextView }.first!
            try check(equal(previewText.textColor!, foreground), "\(name): existing preview text retained old color")
            let separators = picker.subviews.filter { $0.layer?.backgroundColor != nil && $0.bounds.height <= 1 }
            try check(separators.count == 2 && separators.allSatisfy { equal($0.layer?.backgroundColor, Palette.line) }, "\(name): separator CG colors did not refresh")
            let groups = descendants(dashboard).filter { String(describing: type(of: $0)) == "DashboardGroup" }
            try check(groups.count == 4 && groups.allSatisfy { equal($0.layer?.borderColor, Palette.line) && equal($0.layer?.backgroundColor, foreground.withAlphaComponent(0.018)) }, "\(name): dashboard card CG colors did not refresh")
            let bright = max(luminance(background), luminance(foreground)), dark = min(luminance(background), luminance(foreground))
            try check((bright + 0.05) / (dark + 0.05) > 7, "\(name): unreadable foreground contrast")
            try check(picker.table.selectedRow == 1 && dashboard.selectedActionID == "switch", "\(name): theme refresh changed selection")
            for (surfaceName, window) in zip(["picker", "dashboard"], windows) {
                let view = window.contentView!
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try check(!window.isVisible, "Theme tests unexpectedly presented a window")
                if let output, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(surfaceName).png"))
                }
            }
        }
        print("Theme checks passed: existing picker/dashboard/preview, cached rows and attributed text, derived colors, CG surfaces and preserved selection across dark/light/custom changes")
    }
}
