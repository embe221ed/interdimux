import AppKit

private final class BenchRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var count = 0
    let items: [PickerItem] = (0..<100).map { index in
        PickerItem(["id": "pane-\(index)", "kind": "pane", "name": "review-\(index)",
                    "title": "Review native rendering and Unicode 東京 👩🏽‍💻 \(index)",
                    "path": "/Users/fixture/projects/engineering/platform/customer-insights-\(index)",
                    "current": index == 2, "attention": index == 4, "agent_state": "approve"])!
    }
    let tree = PickerTreePosition(depth: 2, ancestorContinuations: [0], hasNextSibling: true, hasChildren: false)
    var cells: [Int: PickerCell] = [:]
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = cells[row] ?? PickerCell()
        cells[row] = cell
        cell.configure(items[row], tree: tree, separatesGroup: false)
        return cell
    }
}

private func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count) * 0.95)]]
}

@main
struct RenderBenchmark {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments[1]
        let rows = BenchRows()
        let frame = NSRect(x: 0, y: 0, width: 1080, height: 760)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
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
            if mode == "note" { view.table.noteNumberOfRowsChanged() }
            else { view.table.reloadData() }
            for row in 0..<count {
                (view.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PickerCell)?.configure(rows.items[row], tree: rows.tree, separatesGroup: false)
            }
            if count > 0 { view.table.selectRowIndexes(IndexSet(integer: min(2, count - 1)), byExtendingSelection: false) }
            view.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let painted = ProcessInfo.processInfo.systemUptime
            if iteration >= 12 {
                updateSamples.append((laidOut - start) * 1000)
                paintSamples.append((painted - laidOut) * 1000)
                if oldCount == 0 && count == 100 { revealSamples.append((laidOut - start) * 1000) }
            }
        }
        let report: [String: Any] = ["mode": mode, "update_layout": summary(updateSamples), "paint_bitmap": summary(paintSamples), "zero_to_100_layout": summary(revealSamples), "measurement": "offscreen AppKit layout and CPU bitmap painting; excludes WindowServer/GPU presentation"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        window.close()
    }
}
