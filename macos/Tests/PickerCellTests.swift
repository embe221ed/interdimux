import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private final class ReusedRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var items: [PickerItem] = []
    var cells: [Int: PickerCell] = [:]
    let tree = PickerTreePosition(depth: 0, ancestorContinuations: [], hasNextSibling: false, hasChildren: false)
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = cells[row] ?? PickerCell()
        cells[row] = cell
        cell.configure(items[row], tree: tree, separatesGroup: false)
        return cell
    }
}

@main
struct PickerCellTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var value: [String: Any] = [
            "id": "s1/t1/p1", "kind": "pane", "title": "Review terminal rendering",
            "name": "review", "path": "/workspace/東京/project", "subtitle": "codex",
            "agent_state": "working", "attention": false
        ]
        var item = PickerItem(value)!
        var tree = PickerTreePosition(depth: 2, ancestorContinuations: [0], hasNextSibling: true, hasChildren: false)
        let cell = PickerCell(frame: NSRect(x: 0, y: 0, width: 680, height: 38))
        cell.configure(item, tree: tree, separatesGroup: false)
        cell.layout()
        try check(cell.primary.stringValue == "review  ·  Review terminal rendering", "Pane identity and conversation detail missing")
        try check(cell.path.stringValue == "/workspace/東京/project", "Path missing")

        try check(!cell.configure(item, tree: tree, separatesGroup: false), "Identical row should reuse its configuration")

        value["title"] = "Explain grapheme handling 👩🏽‍💻"
        item = PickerItem(value)!
        try check(cell.configure(item, tree: tree, separatesGroup: false), "Changed title must reconfigure")
        try check(cell.primary.stringValue.contains("Explain grapheme handling 👩🏽‍💻"),
                  "Changed conversation title did not invalidate the cell")

        value["path"] = "/workspace/another/long/directory/終点"
        item = PickerItem(value)!
        try check(cell.configure(item, tree: tree, separatesGroup: false), "Changed path must reconfigure")
        try check(cell.path.stringValue == value["path"] as? String,
                  "Changed path did not invalidate the cell")
        try check(cell.path.lineBreakMode == .byTruncatingHead, "Paths must preserve their suffix when clipped")

        value["agent_state"] = "approve"
        value["attention"] = true
        item = PickerItem(value)!
        try check(cell.configure(item, tree: tree, separatesGroup: false), "Changed attention must reconfigure")
        try check(cell.kind.stringValue == "APPROVAL", "Blocked state was hidden by the cache")
        try check(cell.accessibilityLabel()?.contains("needs approval") == true,
                  "Changed attention state must update accessibility")

        value["agent_state"] = "done"
        value["attention"] = false
        value["current"] = true
        item = PickerItem(value)!
        try check(cell.configure(item, tree: tree, separatesGroup: false), "Resolved attention/current state must reconfigure")
        try check(cell.kind.stringValue == "PANE" && cell.isCurrent,
                  "Resolved attention/current state was hidden by the cache")

        tree = PickerTreePosition(depth: 1, ancestorContinuations: [], hasNextSibling: false, hasChildren: false)
        try check(cell.configure(item, tree: tree, separatesGroup: false), "A changed tree position must invalidate branches and identity placement")
        cell.layout()
        try check(cell.textFrames.title.minX == 73, "A cached cell retained its old indentation")

        try check(cell.configure(item, tree: tree, separatesGroup: true), "A changed group divider must invalidate drawing")

        // Width is deliberately not part of the data cache: AppKit lays out a
        // resized cell without rebuilding its unchanged attributed text.
        cell.setFrameSize(NSSize(width: 440, height: 38))
        cell.layout()
        let expected = PickerGeometry.rowFrames(width: 440, depth: 1)
        try check(cell.textFrames.title == expected.title && cell.textFrames.path == expected.path,
                  "The configuration cache prevented responsive layout")
        try check(cell.subviews.count == 1, "Text fields and the current marker should not allocate per-row view hierarchies")
        let create = PickerItem(["id": "create:project", "kind": "create", "title": "Create session ‘project’", "path": "/workspace/project"])!
        cell.configure(create, tree: tree, separatesGroup: false)
        try check(cell.symbol.image != nil && cell.kind.stringValue == "CREATE", "Create-session row must have a visible plus icon and caption")
        try countTransitions()
        print("Picker cell checks passed: unchanged reuse, title/path/status freshness, tree branches, resize")
    }

    private static func countTransitions() throws {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 620)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PickerView(frame: frame)
        let rows = ReusedRows()
        window.contentView = view
        view.table.dataSource = rows
        view.table.delegate = rows
        view.layoutSubtreeIfNeeded()
        for (generation, count) in [100, 7, 70, 0, 12, 12, 1].enumerated() {
            let previousCount = rows.items.count
            rows.items = (0..<count).map { index in
                let target = generation.isMultiple(of: 2) ? index : count - index - 1
                return PickerItem(["id": "target-\(generation)-\(target)", "kind": "pane",
                                   "title": "Target \(generation)/\(target)", "path": "/workspace/\(generation)/\(target)"])!
            }
            if previousCount != count { view.table.noteNumberOfRowsChanged() }
            for index in rows.items.indices {
                (view.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PickerCell)?.configure(rows.items[index], tree: rows.tree, separatesGroup: false)
            }
            if count > 0 {
                view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                view.table.scrollRowToVisible(0)
            }
            view.layoutSubtreeIfNeeded()
            try check(view.table.numberOfRows == count, "Native table retained the wrong row count")
            let visible = view.table.rows(in: view.table.visibleRect)
            for index in visible.location..<NSMaxRange(visible) where index < count {
                guard let shown = view.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? PickerCell else {
                    throw TestFailure(description: "Missing visible row \(index)")
                }
                try check(shown.primary.stringValue == rows.items[index].title && shown.path.stringValue == rows.items[index].path,
                          "A count/ranking change retained another target's visible metadata")
                let rect = view.table.rect(ofRow: index)
                let hit = view.table.row(at: NSPoint(x: rect.midX, y: rect.midY))
                try check(hit == index && rows.items[hit].title == shown.primary.stringValue,
                          "Hit-tested row target differs from the displayed target")
            }
        }
        print("Native table transition checks passed: 0/100/7/70/0/12/12/1, reranking, hit-tested target identity")
    }
}
