import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

@main
struct OpeningTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        let originA = ["client_id": "client:one", "session_id": "session:a"]
        let originB = ["client_id": "client:one", "session_id": "session:b"]

        func deliver(previous: String, current: String, extraRows: Int = 0) {
            let rows: [[String: Any]] = [
                ["id": previous, "kind": "session", "title": "Previous"],
                ["id": previous + "/tab", "kind": "window", "title": "Previous tab", "parent_id": previous],
                ["id": current, "kind": "session", "title": "Current", "current": true]
            ] + (0..<extraRows).map { ["id": "session:extra-\($0)", "kind": "session", "title": "Extra \($0)"] }
            picker.receive([
                "id": picker.pending, "type": "results", "query": "", "scope": "all",
                "search_field": "all", "action_filter": "", "preferred_id": previous,
                "matched": rows.count, "total": rows.count, "shown_matches": rows.count,
                "rows": rows
            ])
        }
        func checkLoadingEmpty(_ label: String) throws {
            try check(picker.items.isEmpty && picker.content.table.numberOfRows == 0,
                      "\(label): painted unverified cached session order")
            try check(picker.content.table.selectedRow == -1 && picker.displayedRequest == -1,
                      "\(label): retained an actionable stale selection")
            try check(picker.loading && !picker.content.empty.isHidden,
                      "\(label): missing loading state while awaiting fresh results")
            try check(!picker.panel.isVisible, "Offscreen test unexpectedly presented a window")
        }

        picker.open(context: originA)
        try checkLoadingEmpty("first open")
        deliver(previous: "session:b", current: "session:a")
        try check(picker.items.first?.id == "session:b" && picker.content.table.selectedRow == 0,
                  "Fresh opening did not select the backend's previous session")

        // Returning to the same session does not prove that its previous
        // session is unchanged: Rex can have visited C and returned to A while
        // this picker was closed. Never paint the old B-first frame or a stale
        // selection before the authoritative response arrives.
        picker.content.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        picker.open(context: originA)
        try checkLoadingEmpty("same origin with changed history")
        deliver(previous: "session:c", current: "session:a")
        try check(picker.items.first?.id == "session:c" && picker.content.table.selectedRow == 0,
                  "Same-origin reopening did not display/select the new previous session first")
        picker.open(context: originA)
        try checkLoadingEmpty("same origin with unchanged history")
        deliver(previous: "session:c", current: "session:a")
        try check(picker.items.first?.id == "session:c" && picker.content.table.selectedRow == 0,
                  "Repeated opening did not retain the authoritative order/selection")

        // A prior invocation can leave the table scrolled far below row zero.
        // Its first fresh frame must already show the previous session at the
        // top, rather than visibly scrolling into place after presentation.
        picker.open(context: originA)
        deliver(previous: "session:c", current: "session:a", extraRows: 40)
        picker.content.layoutSubtreeIfNeeded()
        picker.content.table.scrollRowToVisible(picker.items.count - 1)
        try check(picker.content.scroll.contentView.bounds.minY > 0,
                  "Scrolling fixture did not leave the prior invocation below the first row")
        picker.open(context: originA)
        try checkLoadingEmpty("same origin after scrolling")
        try check(picker.content.scroll.contentView.bounds.minY == 0,
                  "Opening retained the prior invocation's scroll offset")
        deliver(previous: "session:b", current: "session:a", extraRows: 40)
        try check(picker.items.first?.id == "session:b" && picker.content.table.selectedRow == 0
                  && picker.content.scroll.contentView.bounds.minY == 0,
                  "First authoritative frame did not show/select the previous session at the top")

        // The session that was previously first is now current. Its old cached
        // position must never appear as this invocation's first session.
        picker.open(context: originB)
        try checkLoadingEmpty("A to B reopen")
        deliver(previous: "session:a", current: "session:b")
        try check(picker.items.first?.id == "session:a" && picker.content.table.selectedRow == 0,
                  "Fresh B results did not show/select previous A first")
        picker.open(context: originA)
        try checkLoadingEmpty("B to A reopen")
        deliver(previous: "session:b", current: "session:a")
        picker.open(context: ["client_id": "client:two", "session_id": "session:a"])
        try checkLoadingEmpty("different client")

        // Anonymous/partial contexts may receive valid results, but two missing
        // IDs are not evidence that subsequent invocations share an origin.
        for context in [[:], ["client_id": "client:one"], ["session_id": "session:a"],
                        ["client_id": "", "session_id": "session:a"],
                        ["client_id": "client:one", "session_id": ""]] {
            picker.open(context: context)
            deliver(previous: "session:b", current: "session:a")
            picker.open(context: context)
            try checkLoadingEmpty("unknown origin \(context)")
        }
        // Change the theme on the same controller and retained view instances.
        // Palette refresh must not reopen the picker or disturb the work in it.
        picker.open(context: originA)
        deliver(previous: "session:b", current: "session:a")
        picker.content.search.stringValue = "existing query"
        picker.scope = "window"
        picker.content.searchField.selectItem(at: 1)
        picker.content.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        picker.content.setPreviewVisible(true)
        picker.content.showPreview(title: "Retained preview", detail: "Fixture", text: "Preview remains intact")
        let dashboard = picker.ensureDashboard()
        dashboard.moveSelection(2)
        let dashboardSelection = dashboard.selectedActionID
        let pending = picker.pending
        let identities = picker.items.map(\.id)
        let displayedRequest = picker.displayedRequest
        let content = picker.content
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let previewText = descendants(content).compactMap { $0 as? NSTextView }
            .first { $0.string == "Preview remains intact" }!
        func sameColor(_ actual: NSColor?, _ expected: NSColor) -> Bool {
            guard let actual = actual?.usingColorSpace(.sRGB),
                  let expected = expected.usingColorSpace(.sRGB) else { return false }
            return abs(actual.redComponent - expected.redComponent) < 0.0001
                && abs(actual.greenComponent - expected.greenComponent) < 0.0001
                && abs(actual.blueComponent - expected.blueComponent) < 0.0001
                && abs(actual.alphaComponent - expected.alphaComponent) < 0.0001
        }
        let themes = [
            RexTheme(isDark: false, name: "Light", background: .white, foreground: .black, accent: .systemBlue),
            RexTheme(isDark: true, name: "Dark", background: .black, foreground: .white, accent: .systemOrange),
            RexTheme(isDark: true, name: "Custom", background: NSColor(srgbRed: 0.11, green: 0.08, blue: 0.22, alpha: 1),
                     foreground: NSColor(srgbRed: 0.89, green: 0.91, blue: 0.81, alpha: 1),
                     accent: NSColor(srgbRed: 0.31, green: 0.85, blue: 0.75, alpha: 1))
        ]
        for theme in themes {
            picker.applyTheme(theme)
            try check(picker.panel.appearance?.bestMatch(from: [.darkAqua, .aqua]) == (theme.isDark ? .darkAqua : .aqua),
                      "\(theme.name): panel appearance did not follow Rex")
            try check(sameColor(content.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), theme.background),
                      "\(theme.name): existing picker retained its old CG background")
            try check(sameColor(dashboard.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), theme.background),
                      "\(theme.name): detached dashboard retained its old CG background")
            try check(sameColor(content.search.textColor, theme.foreground) && sameColor(previewText.textColor, theme.foreground),
                      "\(theme.name): retained search/preview colors did not update")
            try check(picker.content === content && picker.items.map(\.id) == identities
                      && content.search.stringValue == "existing query" && picker.scope == "window"
                      && content.searchField.indexOfSelectedItem == 1 && content.table.selectedRow == 1
                      && content.previewVisible && previewText.string == "Preview remains intact"
                      && dashboard.selectedActionID == dashboardSelection,
                      "\(theme.name): theme switching changed picker navigation or preview state")
            try check(picker.pending == pending && picker.displayedRequest == displayedRequest,
                      "\(theme.name): theme switching issued a query or invalidated current results")
            picker.applyTheme(theme)
            try check(picker.pending == pending && !picker.panel.isVisible,
                      "\(theme.name): repeated theme application changed state or presented a window")
        }
        // A confirmation can remain attached while the appearance changes.
        // Keep both windows outside the desktop and dispatch no system input.
        picker.themeTimer?.invalidate()
        picker.panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let sheet = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        picker.panel.beginSheet(sheet)
        defer {
            picker.panel.endSheet(sheet)
            sheet.orderOut(nil)
            sheet.close()
        }
        try check(picker.panel.attachedSheet === sheet, "Offscreen confirmation sheet did not attach")
        for theme in themes.prefix(2) {
            picker.applyTheme(theme)
            try check(sheet.appearance?.bestMatch(from: [.darkAqua, .aqua]) == (theme.isDark ? .darkAqua : .aqua),
                      "\(theme.name): attached confirmation kept its previous appearance")
            try check(picker.pending == pending && content.search.stringValue == "existing query"
                      && content.table.selectedRow == 1,
                      "\(theme.name): confirmation theme refresh disturbed picker state")
        }
        print("Opening checks passed: authoritative previous-session first frame, changed-history reopening and controller/sheet themes preserving query/selection/scope/preview")
    }
}
