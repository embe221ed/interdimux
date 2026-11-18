import AppKit

private final class BenchRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var count = 0
    var reuseRows = false
    let items: [PickerItem] = (0..<100).map { index in
        PickerItem(["id": "pane-\(index)", "kind": "pane", "name": "review-\(index)",
                    "title": "Review native rendering and Unicode 東京 👩🏽‍💻 \(index)",
                    "path": "/Users/fixture/projects/engineering/platform/customer-insights-\(index)",
                    "current": index == 2, "attention": index == 4, "agent_state": "approve"])!
    }
    let tree = PickerTreePosition(depth: 2, ancestorContinuations: [0], hasNextSibling: true, hasChildren: false)
    var cells: [Int: PickerCell] = [:]
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard reuseRows else { return PickerRow() }
        let identifier = NSUserInterfaceItemIdentifier("place-row")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? PickerRow { return view }
        let view = PickerRow()
        view.identifier = identifier
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = cells[row] ?? PickerCell()
        cells[row] = cell
        cell.configure(items[row], tree: tree, separatesGroup: false)
        return cell
    }
}

@main
struct RenderBenchmark {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments[1]
        let rows = BenchRows()
        rows.reuseRows = mode == "note"
        let compact = CommandLine.arguments.contains("--compact")
        let frame = NSRect(x: 0, y: 0, width: compact ? 680 : 1080, height: compact ? 560 : 760)
        let window = benchmarkWindow(frame)
        let view = PickerView(frame: frame)
        window.contentView = view
        view.empty.isHidden = true
        view.table.dataSource = rows
        view.table.delegate = rows
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        var updateSamples: [Double] = [], paintSamples: [Double] = [], revealSamples: [Double] = []
        for iteration in 0..<120 {
            let count = [0, 100, 10, 100, 99, 100][iteration % 6]
            let oldCount = rows.count
            let start = ProcessInfo.processInfo.systemUptime
            rows.count = count
            if mode == "note" {
                view.table.noteNumberOfRowsChanged()
                view.table.enumerateAvailableRowViews { rowView, index in
                    guard (0..<count).contains(index), rowView.numberOfColumns > 0,
                          let cell = rowView.view(atColumn: 0) as? PickerCell else { return }
                    cell.configure(rows.items[index], tree: rows.tree, separatesGroup: false)
                }
            } else {
                view.table.reloadData()
                for index in 0..<count {
                    (view.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PickerCell)?
                        .configure(rows.items[index], tree: rows.tree, separatesGroup: false)
                }
            }
            if count > 0 { view.table.selectRowIndexes(IndexSet(integer: min(2, count - 1)), byExtendingSelection: false) }
            view.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let painted = ProcessInfo.processInfo.systemUptime
            if count > 0 {
                precondition(view.table.numberOfRows == count && view.table.selectedRow >= 0)
                precondition(view.table.view(atColumn: 0, row: view.table.selectedRow, makeIfNecessary: false) is PickerCell)
            }
            if iteration >= 12 {
                updateSamples.append((laidOut - start) * 1000)
                paintSamples.append((painted - laidOut) * 1000)
                if oldCount == 0 && count == 100 { revealSamples.append((laidOut - start) * 1000) }
            }
        }
        try printBenchmark(["update_layout": summary(updateSamples), "paint_bitmap": summary(paintSamples),
                            "zero_to_100_layout": summary(revealSamples), "samples": updateSamples.count],
                           mode: mode, frame: frame)
        window.close()
    }
}
