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
        try lazyProjectSearch()
        try remoteSessions()
        try keyboardShortcuts()
        try dashboardHandoffs()
        try rowActions()
        try themePolling()
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        let originA = ["client_id": "client:one", "session_id": "session:a"]
        let originB = ["client_id": "client:one", "session_id": "session:b"]

        let catalogIDs = ["session:a", "session:a/tab", "session:b", "session:b/tab", "session:c", "session:c/tab"]
        func deliver(previous: String, current: String, extraRows: Int = 0,
                     omit: String? = nil, query: String = "", scope: String = "all",
                     sessionOrder: [String] = ["a", "b", "c"], customRows: [[String: Any]]? = nil) {
            let rows: [[String: Any]] = sessionOrder.flatMap { name -> [[String: Any]] in
                let id = "session:\(name)"
                return [
                    ["id": id, "kind": "session", "title": name.uppercased(), "current": id == current],
                    ["id": id + "/tab", "kind": "window", "title": "\(name.uppercased()) tab", "parent_id": id]
                ]
            } + (0..<extraRows).map { ["id": "session:extra-\($0)", "kind": "session", "title": "Extra \($0)"] }
            let included = (customRows ?? rows).filter { ($0["id"] as? String) != omit }
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

        // Rex can return the same catalog in a different order after changing
        // sessions. A warm opening must keep the exact frame already shown,
        // including its viewport, even when the newly preferred root is far
        // below that viewport. Only selection should change on this reply.
        picker.open(context: originA)
        deliver(previous: "session:b", current: "session:a", extraRows: 40)
        picker.open(context: originA)
        picker.content.layoutSubtreeIfNeeded()
        let cachedOrder = picker.items.map(\.id)
        let cachedTree = picker.tree
        let cachedRows = picker.content.table.numberOfRows
        let cachedViewport = picker.content.scroll.contentView.bounds.origin
        let cachedCell = picker.content.table.view(atColumn: 0, row: 2, makeIfNecessary: true)
        let cachedRowView = picker.content.table.rowView(atRow: 2, makeIfNecessary: true)
        deliver(previous: "session:extra-39", current: "session:a", extraRows: 40,
                sessionOrder: ["c", "a", "b"])
        try check(picker.items.map(\.id) == cachedOrder && picker.tree == cachedTree
                  && picker.content.table.numberOfRows == cachedRows,
                  "Warm opening refresh replaced the cached row order/tree with a shuffled catalog")
        try check(selectedID() == "session:extra-39",
                  "Keeping the cached frame prevented selection of the fresh previous session")
        try check(picker.content.scroll.contentView.bounds.origin == cachedViewport,
                  "Warm opening refresh visibly scrolled the cached frame to its new selection")
        try check(picker.content.table.view(atColumn: 0, row: 2, makeIfNecessary: true) === cachedCell
                  && picker.content.table.rowView(atRow: 2, makeIfNecessary: true) === cachedRowView,
                  "Warm opening refresh replaced an unchanged native row/cell")
        picker.open(context: originA)
        try check(picker.items.map(\.id) == cachedOrder && selectedID() == "session:extra-39",
                  "Reopening forgot the retained catalog order or previous-session selection")
        deliver(previous: "session:b", current: "session:a", extraRows: 40,
                sessionOrder: ["b", "c", "a"])
        try check(picker.items.map(\.id) == cachedOrder,
                  "A second shuffled opening response changed the retained catalog order")

        // Membership changes still appear, without disturbing surviving root
        // groups. New children stay beside their parent, reparented children
        // follow their fresh parent, and new root groups go after old ones.
        picker.open(context: originA)
        deliver(previous: "session:b", current: "session:a", customRows: [
            ["id": "session:c", "kind": "session", "title": "C"],
            ["id": "session:c/tab", "kind": "window", "title": "C tab", "parent_id": "session:c"],
            ["id": "session:d", "kind": "session", "title": "New D"],
            ["id": "session:a", "kind": "session", "title": "A", "current": true],
            ["id": "session:a/new", "kind": "window", "title": "New A tab", "parent_id": "session:a"],
            ["id": "session:b", "kind": "session", "title": "B"],
            ["id": "session:a/tab", "kind": "window", "title": "Reparented A tab", "parent_id": "session:b"]
        ])
        try check(picker.items.map(\.id) == ["session:a", "session:a/new", "session:b", "session:a/tab", "session:c", "session:c/tab", "session:d"],
                  "Opening reconciliation lost stable groups, appended a child outside its parent, or retained removed rows")
        try check(picker.tree.map(\.depth) == [0, 1, 0, 1, 0, 1, 0]
                  && picker.items[3].parentID == "session:b" && selectedID() == "session:b",
                  "Opening reconciliation broke fresh parentage or previous-session selection")

        // Explicit refresh remains a way to request a new catalog layout.
        // Restore the small A/B/C fixture for the navigation checks below.
        picker.refresh()
        deliver(previous: "session:b", current: "session:a", sessionOrder: ["b", "c", "a"])
        try check(picker.items.map(\.id) == ["session:b", "session:b/tab", "session:c", "session:c/tab", "session:a", "session:a/tab"],
                  "Explicit refresh unexpectedly froze the prior cached catalog order")
        picker.refresh()
        deliver(previous: "session:b", current: "session:a")

        // Query relevance and mutation-triggered refreshes still use the
        // helper's new layout; the frozen frame applies only to reopening.
        picker.content.search.stringValue = "tab"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.content.search))
        deliver(previous: "session:c", current: "session:a", query: "tab", sessionOrder: ["c", "b", "a"])
        try check(picker.items.map(\.id) == ["session:c", "session:c/tab", "session:b", "session:b/tab", "session:a", "session:a/tab"],
                  "Cached opening order overrode a newly ranked search")
        picker.clearSearch()
        deliver(previous: "session:b", current: "session:a")
        picker.sendAction("rename", target: picker.items[0], extra: ["value": "Renamed fixture"])
        picker.receive(["id": picker.actionRequest!, "type": "action_done", "operation": "rename", "close_picker": false])
        deliver(previous: "session:b", current: "session:a", sessionOrder: ["b", "a", "c"])
        try check(picker.items.map(\.id) == ["session:b", "session:b/tab", "session:a", "session:a/tab", "session:c", "session:c/tab"],
                  "Mutation refresh unexpectedly retained the opening's old layout")
        picker.refresh()
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

        picker.changeScope(picker.content.scopes[0])
        deliver(previous: "session:c", current: "session:a")

        picker.open(context: originA)
        picker.accept()
        let hiddenOpeningOrder = picker.items.map(\.id)
        picker.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: picker.panel))
        deliver(previous: "session:c", current: "session:a", sessionOrder: ["c", "b", "a"])
        try check(activatedTargets().count == 2 && picker.activation == nil,
                  "Hiding the picker after changing apps did not cancel the queued Enter")
        try check(picker.openingItems.map(\.id) == hiddenOpeningOrder,
                  "A hidden opening reply reordered the cache for the next invocation")

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
        print("Opening checks passed: lazy project search, unchanged cached frame across shuffled catalogs, previous-session selection, deferred Enter, navigation/typing and controller/sheet themes")
    }

    private static func themePolling() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        let change = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: picker.panel)
        picker.windowDidChangeOcclusionState(change)
        try check(picker.themeTimer == nil, "Hidden panel scheduled a repeating timer")
        picker.setThemePolling(true)
        let first = picker.themeTimer
        picker.setThemePolling(true)
        try check(first?.isValid == true && first === picker.themeTimer, "Visible panel must schedule just one refresh timer")
        picker.windowDidChangeOcclusionState(change)
        try check(first?.isValid == false && picker.themeTimer == nil, "Occluding the panel must invalidate its timer")
        picker.setThemePolling(true)
        try check(picker.themeTimer?.isValid == true && first !== picker.themeTimer, "Showing the panel must resume theme updates")
        picker.setThemePolling(false)
    }

    private static func rowActions() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        picker.open(context: ["client_id": "client:local"])
        let rows: [[String: Any]] = [
            ["id": "session:a", "kind": "session", "title": "Context", "context_only": true],
            ["id": "pane:a", "kind": "pane", "title": "First", "actions": ["split-right"]],
            ["id": "pane:b", "kind": "pane", "title": "Second", "actions": ["split-right", "rename"]]
        ]
        picker.receive(["id": picker.pending, "type": "results", "rows": rows, "preferred_id": "pane:a"])
        picker.content.layoutSubtreeIfNeeded()
        let table = picker.content.table
        var menus: [[String]] = []
        func operations(_ menu: NSMenu) -> [String] {
            menu.items.filter(\.isEnabled).compactMap { $0.representedObject as? String }
        }
        // Exercise both hardware event entry points without tracking a visible menu.
        table.onRowMenu = { row, _ in
            picker.showRowActions(row) { menus.append(operations($0)) }
        }
        func click(_ row: Int, control: Bool) {
            let rect = table.rect(ofRow: row)
            let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: control ? .leftMouseDown : .rightMouseDown,
                location: location, modifierFlags: control ? .control : [], timestamp: 0,
                windowNumber: picker.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if control { table.mouseDown(with: event) } else { table.rightMouseDown(with: event) }
        }
        let dispatched = picker.backend.requests.count
        click(2, control: false)
        try check(table.selectedRow == 2 && menus.last?.contains("rename") == true && picker.backend.requests.count == dispatched,
                  "Cancelling a row menu must select the clicked target without dispatch")
        var keyboardActions: [String] = []
        picker.trackActionsMenu { keyboardActions = operations($0) }
        try check(menus.last == keyboardActions, "Row menu diverged from the keyboard Actions menu")
        click(1, control: true)
        try check(menus.count == 2 && table.selectedRow == 1 && menus.last?.contains("rename") == false,
                  "Control-click must present only the clicked row's capabilities")
        click(0, control: false)
        picker.showRowActions(-1) { menus.append(operations($0)) }
        try check(menus.count == 2 && table.selectedRow == 1, "Context ancestors or empty space exposed another row's actions")
        picker.showRowActions(2) { menu in
            picker.chooseAction(menu.items.first { $0.representedObject as? String == "split-right" }!)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
        try check(picker.backend.requests.count == dispatched, "Selection changes during menu tracking redirected a mutation")
        picker.showRowActions(2) { menu in
            picker.chooseAction(menu.items.first { $0.representedObject as? String == "split-right" }!)
        }
        try check(picker.backend.requests.last?.fields["target_id"] as? String == "pane:b", "Row menu sent action to the wrong pane")
        click(1, control: false)
        try check(menus.count == 2 && table.selectedRow == 2, "An in-flight action allowed another row menu")
    }

    private static func dashboardHandoffs() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        picker.open(context: ["client_id": "client:home", "origin_server": "lab", "origin_session_id": "session:remote"], dashboard: true)
        let dashboard = picker.ensureDashboard()
        try check(dashboard.choose(key: "h") && picker.deferredDashboardAction == .health,
                  "A handoff selected before collection should wait for its origin")
        func deliver(available: Bool) {
            picker.receive(["id": picker.pending, "type": "results",
                            "dashboard": ["terminal_tools_available": available], "rows": []])
        }
        deliver(available: false)
        try check(picker.deferredDashboardAction == nil && picker.dashboardRequest == nil
                  && !picker.backend.requests.contains { $0.type == "dashboard_action" },
                  "A pending terminal handoff from a remote origin dispatched against the local Rex server")
        picker.open(context: ["client_id": "client:home", "session_id": "session:local",
                              "window_id": "window:local", "block_id": "block:local"], dashboard: true)
        try check(dashboard.choose(key: "o") && picker.deferredDashboardAction == .jobs,
                  "Reopening must reconsider the new origin's capabilities")
        deliver(available: true)
        try check(picker.backend.requests.last?.fields["operation"] as? String == "jobs",
                  "A valid terminal handoff must run once the original pane is validated")
    }

    private static func keyboardShortcuts() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        let directory = ["id": "directory:example", "kind": "directory", "title": "Example"]
        picker.open(context: ["client_id": "client:one"])
        picker.receive(["id": picker.pending, "type": "results", "rows": [directory]])
        func press(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
            let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            key.flags.formUnion(flags)
            return picker.panel.performKeyEquivalent(with: NSEvent(cgEvent: key)!)
        }
        try check(press(124, .maskCommand) && picker.backend.requests.last?.fields["base_id"] as? String == "directory:example",
                  "Command-Right with hardware arrow flags must browse the selected folder")
        picker.receive(["id": picker.pending, "type": "results", "scope": "directory", "directories_loaded": true,
                        "directories_base": "/example", "rows": [directory]])
        try check(press(123, .maskCommand) && picker.backend.requests.last?.fields["parent"] as? Bool == true,
                  "Command-Left with hardware arrow flags must browse the parent")
        picker.receive(["id": picker.pending, "type": "results", "scope": "directory", "directories_loaded": true, "rows": []])
        try check(press(19, [.maskCommand, .maskAlphaShift]) && picker.scope == "session",
                  "Caps Lock must leave Command-2 scope navigation available")
    }

    private static func remoteSessions() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.panel.close() }
        let local = ["client_id": "client:one", "session_id": "session:a"]
        let remote = ["client_id": "client:one", "origin_session_id": "session:a", "origin_server": "DEVBOX"]
        let a = ["id": "session:a", "kind": "session", "title": "A"]
        let b = ["id": "session:b", "kind": "session", "title": "B"]
        let remoteID = "remote:server:session:a"
        let hostSession = ["id": remoteID, "kind": "session", "title": "Remote A", "host": "devbox", "session_id": "session:a"]
        func results(_ rows: [[String: Any]], id: Int? = nil, text: String = "", more: Bool = true) {
            picker.receive(["id": id ?? picker.pending, "type": "results", "query": text, "scope": "all",
                            "remote_pending": more, "preferred_id": "session:b", "rows": rows])
        }
        func poll() throws -> Int {
            guard let work = picker.remotePollWork else { throw TestFailure(description: "Remote poll was not scheduled") }
            work.perform()
            guard let id = picker.remotePollRequest else { throw TestFailure(description: "Scheduled work did not request a remote update") }
            return id
        }
        func deliverPoll(_ id: Int, more: Bool, changed: Bool) {
            picker.receive(["id": id, "type": "remote_update", "pending": more, "changed": changed])
        }

        picker.open(context: local)
        results([a, b])
        let openingRequest = picker.pending
        let delayedPoll = try poll()
        try check(!picker.loading && picker.displayedRequest == openingRequest,
                  "Remote poll blocked the local opening result")
        picker.accept()
        try check(picker.backend.requests.last?.type == "activate"
                  && picker.backend.requests.last?.fields["target_id"] as? String == "session:b",
                  "Waiting for a remote host prevented immediate local switching")
        deliverPoll(delayedPoll, more: true, changed: true)
        try check(picker.remoteResultsRequest == nil && picker.items.map(\.id) == ["session:a", "session:b"],
                  "Remote discovery interrupted a local switch")
        picker.activation = nil // This offscreen test never gives focus to live Rex.

        picker.open(context: local)
        results([a, b])
        let normalRequest = picker.pending
        let readyPoll = try poll()
        deliverPoll(readyPoll, more: true, changed: true)
        guard let refreshID = picker.remoteResultsRequest else {
            throw TestFailure(description: "An available host did not request updated results")
        }
        try check(picker.pending == normalRequest && picker.displayedRequest == normalRequest && !picker.loading,
                  "A remote re-query invalidated actionability of current local rows")
        let oldViewport = picker.content.scroll.contentView.bounds.origin
        results([hostSession, b, a], id: refreshID)
        try check(picker.items.map(\.id) == ["session:a", "session:b", remoteID]
                  && picker.content.table.selectedRow == 1
                  && picker.content.scroll.contentView.bounds.origin == oldViewport,
                  "A newly available host moved the existing results, selection, or viewport")
        try check(picker.remotePollWork != nil && picker.openingItems.last?.host == "devbox",
                  "A remote row was not cached while other hosts were still pending")

        let finalPoll = try poll()
        deliverPoll(finalPoll, more: false, changed: true)
        guard let staleRefreshID = picker.remoteResultsRequest else {
            throw TestFailure(description: "Last host result was dropped")
        }
        picker.content.search.stringValue = "remote"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.content.search))
        results([a], id: staleRefreshID, more: false)
        try check(picker.items.contains { $0.id == remoteID }, "A late background result replaced an actively edited search")
        results([hostSession], text: "remote", more: false)
        picker.accept()
        try check(picker.backend.requests.last?.fields["target_id"] as? String == remoteID,
                  "A remote result did not switch using its host-scoped ID")
        picker.activation = nil

        picker.open(context: remote)
        try check(picker.openingFrameHadRows && picker.items.filter(\.current).map(\.id) == [remoteID],
                  "Cached opening from a remote origin marked the same-ID local session as current")
        var aliasedOrigin = remote
        aliasedOrigin["origin_server"] = "app-server-key"
        picker.open(context: aliasedOrigin)
        try check(picker.items.filter(\.current).map(\.id) == [remoteID],
                  "A unique remote session did not resolve the app's private server key")
        results([a, b, hostSession])
        let hiddenPoll = try poll()
        picker.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: picker.panel))
        let beforeHiddenReply = picker.backend.requests.count
        deliverPoll(hiddenPoll, more: true, changed: true)
        try check(picker.backend.requests.count == beforeHiddenReply && picker.remotePollWork == nil,
                  "A dismissed picker kept polling or re-querying remote hosts")

        // The final host can finish with an unchanged catalog. There is no
        // reason to re-query, but neither kind of miss should keep its hint.
        for offerCreate in [false, true] {
            picker.open(context: local)
            results([a, b])
            picker.content.search.stringValue = "missing"
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.content.search))
            let rows = offerCreate ? [["id": "create:missing", "kind": "create", "title": "Create missing"]] : []
            results(rows, text: "missing")
            let hint = offerCreate ? picker.content.status : picker.content.emptyDetail
            try check(hint.stringValue.localizedCaseInsensitiveContains("checking remote hosts"),
                      "A miss did not indicate that hosts were still being checked")
            let lastPoll = try poll()
            let beforeFinalReply = picker.backend.requests.count
            deliverPoll(lastPoll, more: false, changed: false)
            try check(hint.stringValue == (offerCreate ? picker.createHint : picker.noMatchingHint)
                      && picker.backend.requests.count == beforeFinalReply && picker.remotePollWork == nil,
                      "An unchanged final catalog left a remote-loading hint or triggered another request")
        }
        print("Remote opening checks passed: independent local action, incremental rows, latest search, origin cache, dismissal, unchanged completion")
    }

    private static func lazyProjectSearch() throws {
        let picker = PickerApplication()
        picker.setupPanel()
        picker.panel.isReleasedWhenClosed = false
        defer { picker.cancelProjectSearch(); picker.panel.close() }
        let origin = ["client_id": "client:lazy", "session_id": "session:current"]
        func deliver(needed: Bool = false, searching: Bool = false, rows: [[String: Any]] = [], id: Int? = nil) {
            picker.receive([
                "id": id ?? picker.pending, "type": "results", "query": picker.content.search.stringValue,
                "scope": picker.scope, "search_field": picker.searchField, "action_filter": "",
                "projects_needed": needed, "projects_loading": searching,
                "rows": rows, "matched": rows.count, "total": rows.count, "shown_matches": rows.count,
                "preferred_id": rows.first?["id"] ?? NSNull()
            ])
        }
        func beginMiss(_ query: String = "older-project") {
            picker.open(context: origin)
            deliver()
            picker.content.search.stringValue = query
            picker.query()
            deliver(needed: true)
        }
        func loads() -> Int { picker.backend.requests.filter { $0.type == "load_projects" }.count }

        picker.open(context: origin)
        deliver(needed: true)
        try check(picker.projectSearchWork == nil && loads() == 0,
                  "Blank opening started optional project work")
        picker.content.search.stringValue = "live"
        picker.query()
        deliver(needed: true, rows: [["id": "session:live", "kind": "session", "title": "Live"]])
        try check(picker.projectSearchWork == nil && loads() == 0,
                  "A cached hit started optional project work")

        beginMiss()
        try check(picker.projectSearchWork != nil && loads() == 0 && !picker.loading && picker.content.search.isEnabled,
                  "Missing project blocked typing or loaded before the idle callback")
        let missingRequest = picker.pending
        picker.projectSearchWork!.perform()
        try check(loads() == 1 && picker.backend.requests.last?.type == "load_projects"
                  && picker.backend.requests.last?.fields["query"] as? String == "older-project"
                  && picker.backend.requests.last?.fields["scope"] as? String == "all",
                  "Idle callback did not request the current project search")
        let loadRequest = picker.pending
        deliver(needed: true, id: missingRequest)
        try check(picker.pending == loadRequest && picker.projectSearchWork == nil,
                  "A stale miss rescheduled loading over the current request")
        deliver(searching: true)
        try check(picker.projectSearchWork != nil && !picker.loading,
                  "Pending inventory did not schedule a nonblocking follow-up")
        let stalePoll = picker.projectSearchWork!
        stalePoll.perform()
        try check(picker.backend.requests.last?.type == "query" && loads() == 1,
                  "Pending inventory spawned another load instead of checking its result")
        let directoryID = "directory:older-project"
        deliver(rows: [["id": directoryID, "kind": "directory", "title": "Older project", "path": "/fixture/older-project"]])
        try check(picker.items.first?.id == directoryID && picker.content.table.selectedRow == 0
                  && picker.projectSearchWork == nil,
                  "Stopped typing never received the lazily loaded project")
        let completeCount = picker.backend.requests.count
        stalePoll.perform()
        try check(picker.backend.requests.count == completeCount, "Completed project work kept polling")
        picker.accept()
        try check(picker.backend.requests.last?.type == "activate"
                  && picker.backend.requests.last?.fields["target_id"] as? String == directoryID,
                  "Loaded project was not selectable with Enter")
        picker.activation = nil // Never deliver an activation that focuses live Rex.

        beginMiss("before-edit")
        let editedWork = picker.projectSearchWork!
        let beforeEditLoads = loads()
        picker.content.search.stringValue = "after-edit"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.content.search))
        editedWork.perform()
        try check(loads() == beforeEditLoads && picker.projectSearchWork == nil,
                  "Typing did not cancel the scheduled project request")

        beginMiss()
        let scopedWork = picker.projectSearchWork!
        picker.changeScope(picker.content.scopes[1])
        let scopedCount = picker.backend.requests.count
        scopedWork.perform()
        deliver(needed: true)
        try check(picker.backend.requests.count == scopedCount && picker.projectSearchWork == nil,
                  "Changing scope allowed a delayed All search to run")

        beginMiss()
        let fieldWork = picker.projectSearchWork!
        picker.content.searchField.selectItem(at: 3)
        picker.changeSearchField()
        let fieldCount = picker.backend.requests.count
        fieldWork.perform()
        deliver(needed: true)
        try check(picker.backend.requests.count == fieldCount && picker.projectSearchWork == nil,
                  "Changing search field allowed a delayed project search to run")

        beginMiss()
        let actionWork = picker.projectSearchWork!
        let oldQuery = picker.pending
        picker.sendAction("new-window")
        let ownedAction = picker.actionRequest
        let actionCount = picker.backend.requests.count
        actionWork.perform()
        deliver(needed: true, id: oldQuery)
        try check(picker.backend.requests.count == actionCount && picker.projectSearchWork == nil
                  && picker.actionRequest == ownedAction,
                  "Delayed project work replaced an action-owned request")
        picker.actionRequest = nil
        picker.setActionBusy(false)

        beginMiss()
        let dialogWork = picker.projectSearchWork!
        picker.presentingDialog = true
        let dialogCount = picker.backend.requests.count
        dialogWork.perform()
        try check(picker.backend.requests.count == dialogCount,
                  "A project timer dispatched while a dialog was active")
        picker.presentingDialog = false

        // A sheet can open after the lazy request was already dispatched.
        // Its pending reply must defer the next check until the sheet closes,
        // otherwise stopped typing would leave the eventual result unseen.
        beginMiss()
        picker.projectSearchWork!.perform()
        picker.presentingDialog = true
        deliver(searching: true)
        try check(picker.projectSearchWork == nil && picker.queryDeferred,
                  "An in-flight project reply was lost while a dialog was active")
        let resumeCount = picker.backend.requests.count
        picker.endDialog()
        try check(picker.backend.requests.count == resumeCount + 1
                  && picker.backend.requests.last?.type == "query" && !picker.queryDeferred,
                  "Closing the dialog did not resume the deferred project check")
        deliver(rows: [["id": directoryID, "kind": "directory", "title": "Older project", "path": "/fixture/older-project"]])
        try check(picker.items.first?.id == directoryID && picker.projectSearchWork == nil,
                  "Deferred project check did not display the completed inventory result")

        beginMiss()
        let hiddenWork = picker.projectSearchWork!
        picker.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: picker.panel))
        let hiddenCount = picker.backend.requests.count
        hiddenWork.perform()
        deliver(needed: true)
        try check(picker.backend.requests.count == hiddenCount && picker.projectSearchWork == nil,
                  "Hidden picker dispatched or rescheduled optional project work")

        beginMiss()
        let errorWork = picker.projectSearchWork!
        picker.showError("Synthetic project failure")
        let errorCount = picker.backend.requests.count
        errorWork.perform()
        try check(picker.backend.requests.count == errorCount && picker.projectSearchWork == nil,
                  "A failed connection retained its delayed project request")
        beginMiss()
        let reopenWork = picker.projectSearchWork!
        picker.open(context: origin)
        let reopenCount = picker.backend.requests.count
        reopenWork.perform()
        try check(picker.backend.requests.count == reopenCount && picker.projectSearchWork == nil,
                  "Reopening retained another invocation's delayed project request")
    }
}
