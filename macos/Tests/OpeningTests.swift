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

        let catalogIDs = ["session:a", "session:a/tab", "session:b", "session:b/tab", "session:c", "session:c/tab"]
        func deliver(previous: String, current: String, extraRows: Int = 0,
                     omit: String? = nil, query: String = "", scope: String = "all") {
            let rows: [[String: Any]] = ["a", "b", "c"].flatMap { name -> [[String: Any]] in
                let id = "session:\(name)"
                return [
                    ["id": id, "kind": "session", "title": name.uppercased(), "current": id == current],
                    ["id": id + "/tab", "kind": "window", "title": "\(name.uppercased()) tab", "parent_id": id]
                ]
            } + (0..<extraRows).map { ["id": "session:extra-\($0)", "kind": "session", "title": "Extra \($0)"] }
            let included = rows.filter { ($0["id"] as? String) != omit }
            picker.receive([
                "id": picker.pending, "type": "results", "query": query, "scope": scope,
                "search_field": "all", "action_filter": "", "preferred_id": previous,
                "matched": included.count, "total": included.count, "shown_matches": included.count,
                "rows": included
            ])
        }
        func selectedID() -> String? {
            let index = picker.content.table.selectedRow
            return picker.items.indices.contains(index) ? picker.items[index].id : nil
        }
        func checkLoadingEmpty(_ label: String) throws {
            try check(picker.items.isEmpty && picker.content.table.numberOfRows == 0,
                      "\(label): reused a cache without a known matching client and origin")
            try check(picker.content.table.selectedRow == -1 && picker.displayedRequest == -1,
                      "\(label): retained an actionable stale selection")
            try check(picker.loading && !picker.content.empty.isHidden,
                      "\(label): missing loading state while awaiting fresh results")
            try check(!picker.panel.isVisible, "Offscreen test unexpectedly presented a window")
        }
        func checkCached(previous: String, current: String, _ label: String) throws {
            try check(picker.items.map(\.id) == catalogIDs && picker.content.table.numberOfRows == catalogIDs.count,
                      "\(label): cached catalog was cleared or reordered before the response")
            try check(selectedID() == previous,
                      "\(label): previous session was not selected in the immediate cached frame")
            try check(picker.items.filter { $0.kind == "session" && $0.current }.map(\.id) == [current],
                      "\(label): cached current-session markers did not follow the new origin")
            try check(picker.loading && picker.content.empty.isHidden,
                      "\(label): cached list was hidden by the loading placeholder")
            try check(!picker.panel.isVisible, "Offscreen test unexpectedly presented a window")
        }
        func activatedTargets() -> [String] {
            picker.backend.requests.compactMap { request in
                request.type == "activate" ? request.fields["target_id"] as? String : nil
            }
        }
        func clearActivation() {
            // Do not deliver an activated response: dismiss() deliberately
            // returns focus to live Rex, which is outside this offscreen test.
            picker.activation = nil
        }

        picker.open(context: originA)
        try checkLoadingEmpty("first open")
        deliver(previous: "session:b", current: "session:a")
        try check(picker.items.map(\.id) == catalogIDs && selectedID() == "session:b",
                  "Fresh opening reordered the catalog instead of selecting the previous session")
        let retainedCell = picker.content.table.view(atColumn: 0, row: 2, makeIfNecessary: true)

        // A cached frame is visible and selected immediately. If history
        // changes while refresh is pending, an early Enter uses the fresh
        // preferred target rather than silently dropping the keypress.
        picker.content.table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        picker.open(context: originA)
        try checkCached(previous: "session:b", current: "session:a", "same-origin cached opening")
        try check(picker.content.table.view(atColumn: 0, row: 2, makeIfNecessary: true) === retainedCell,
                  "Cached opening replaced the retained row view")
        picker.accept()
        try check(activatedTargets().isEmpty, "Early Enter activated an unvalidated cached target")
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets() == ["session:c"] && selectedID() == "session:c"
                  && picker.items.map(\.id) == catalogIDs,
                  "Early Enter did not activate the fresh previous session without reordering")
        clearActivation()
        picker.open(context: originA)
        try checkCached(previous: "session:c", current: "session:a", "same-origin preferred cache")
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets().count == 1, "A prior Enter leaked into another opening")

        // Session changes within the same client reuse the same row order.
        // The former origin is the likely previous session until refreshed.
        picker.open(context: originB)
        try checkCached(previous: "session:a", current: "session:b", "A to B cached opening")
        deliver(previous: "session:a", current: "session:b")
        try check(picker.items.map(\.id) == catalogIDs && selectedID() == "session:a",
                  "Fresh B response changed catalog order or selected the wrong previous session")
        picker.open(context: originA)
        try checkCached(previous: "session:b", current: "session:a", "B to A cached opening")
        deliver(previous: "session:b", current: "session:a")

        // Deliberate navigation among cached rows wins over the default.
        // The selected identity survives the refresh even when preferred
        // history changes, and early Enter activates exactly that identity.
        picker.open(context: originA)
        picker.move(1)
        try check(selectedID() == "session:b/tab", "Cached rows could not be navigated while opening")
        picker.accept()
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets() == ["session:c", "session:b/tab"] && selectedID() == "session:b/tab",
                  "Fresh preferred selection overwrote deliberate cached navigation")
        clearActivation()

        picker.open(context: originA)
        picker.move(1)
        try check(selectedID() == "session:c/tab", "Removal fixture selected the wrong cached row")
        picker.accept()
        deliver(previous: "session:b", current: "session:a", omit: "session:c/tab")
        try check(activatedTargets().count == 2,
                  "Removed cached selection silently activated another target")

        // Editing a search cancels the queued opening Enter. The eventual
        // response may start a query but must never switch sessions itself.
        picker.open(context: originA)
        picker.accept()
        picker.content.search.stringValue = "tab"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.content.search))
        deliver(previous: "session:c", current: "session:a")
        deliver(previous: "session:c", current: "session:a", query: "tab")
        try check(activatedTargets().count == 2 && picker.activation == nil,
                  "Typing did not cancel the queued opening Enter")

        picker.open(context: originA)
        picker.accept()
        picker.changeScope(picker.content.scopes[1])
        deliver(previous: "session:c", current: "session:a")
        deliver(previous: "session:c", current: "session:a", scope: "session")
        try check(activatedTargets().count == 2 && picker.activation == nil,
                  "Changing scope did not cancel the queued opening Enter")

        picker.open(context: originA)
        picker.accept()
        picker.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: picker.panel))
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets().count == 2 && picker.activation == nil,
                  "Hiding the picker after changing apps did not cancel the queued Enter")

        picker.open(context: originA)
        picker.accept()
        picker.showError("Synthetic collection failure")
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets().count == 2 && picker.activation == nil,
                  "A collection error did not cancel the queued opening Enter")

        // Cached selection is made visible before presentation, instead of
        // retaining a lower viewport and scrolling only after refresh.
        picker.open(context: originA)
        deliver(previous: "session:c", current: "session:a", extraRows: 40)
        picker.content.layoutSubtreeIfNeeded()
        picker.content.table.scrollRowToVisible(picker.items.count - 1)
        try check(picker.content.scroll.contentView.bounds.minY > 0,
                  "Scrolling fixture did not leave the prior invocation below the first row")
        picker.open(context: originA)
        let selected = picker.content.table.selectedRow
        try check(selectedID() == "session:c" && picker.content.table.visibleRect.intersects(picker.content.table.rect(ofRow: selected)),
                  "Cached selected session was not visible in the immediate opening frame")
        deliver(previous: "session:c", current: "session:a", extraRows: 40)

        picker.open(context: ["client_id": "client:two", "session_id": "session:a"])
        try checkLoadingEmpty("different client")
        for context in [[:], ["client_id": "client:one"], ["session_id": "session:a"],
                        ["client_id": "", "session_id": "session:a"],
                        ["client_id": "client:one", "session_id": ""]] {
            picker.open(context: context)
            deliver(previous: "session:b", current: "session:a")
            picker.open(context: context)
            try checkLoadingEmpty("unknown origin \(context)")
        }
        // Enter is also remembered on the first invocation, before there is
        // any cached selection to display.
        picker.open(context: ["client_id": "client:cold", "session_id": "session:a"])
        try checkLoadingEmpty("cold Enter fixture")
        let beforeColdEnter = activatedTargets().count
        picker.accept()
        deliver(previous: "session:c", current: "session:a")
        try check(activatedTargets().count == beforeColdEnter + 1 && activatedTargets().last == "session:c"
                  && selectedID() == "session:c", "Cold opening dropped the first Enter")
        clearActivation()

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
        print("Opening checks passed: immediate cached catalog, previous-session selection, deferred Enter, navigation/typing and controller/sheet themes")
    }
}
