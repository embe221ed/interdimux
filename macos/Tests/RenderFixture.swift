import AppKit

private final class FixtureRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items: [PickerItem]
    let tree: [PickerTreePosition]

    init(_ items: [PickerItem]) {
        self.items = items
        tree = PickerTreeLayout.positions(for: items)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("fixture-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PickerCell ?? PickerCell()
        cell.identifier = identifier
        cell.configure(items[row], tree: tree[row], separatesGroup: row > 0 && tree[row].depth == 0)
        return cell
    }
}

private struct Scenario {
    let name: String
    let size: NSSize
    let projects: Bool
    let preview: Bool
    var empty = false
}

@main
struct RenderFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "RenderFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected fixture JSON and output directory"])
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let values = json["rows"] as! [[String: Any]]
        let items = values.compactMap(PickerItem.init)
        let wide = NSSize(width: 1080, height: 760)
        let narrow = NSSize(width: 720, height: 620)
        let scenarios = [
            Scenario(name: "wide-tree", size: wide, projects: false, preview: false),
            Scenario(name: "wide-tree-preview", size: wide, projects: false, preview: true),
            Scenario(name: "wide-projects", size: wide, projects: true, preview: false),
            Scenario(name: "wide-projects-preview", size: wide, projects: true, preview: true),
            Scenario(name: "narrow-tree-preview", size: narrow, projects: false, preview: true),
            Scenario(name: "narrow-projects-preview", size: narrow, projects: true, preview: true),
            Scenario(name: "narrow-empty-preview", size: narrow, projects: true, preview: true, empty: true)
        ]
        for scenario in scenarios {
            let rows = FixtureRows(scenario.empty ? [] : items.filter { ($0.kind == "directory") == scenario.projects })
            let frame = NSRect(origin: .zero, size: scenario.size)
            // No orderFront, activation or app run loop: bitmap rendering uses
            // the same AppKit view tree without presenting a desktop window.
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let content = PickerView(frame: frame)
            window.contentView = content
            content.table.dataSource = rows
            content.table.delegate = rows
            content.empty.isHidden = !scenario.empty
            content.emptyTitle.stringValue = "No matching projects"
            content.emptyDetail.stringValue = "Try Search deeper, browse another folder, or open a folder with ⌘O."
            content.search.stringValue = scenario.empty ? "not-a-real-project" : ""
            content.clear.isHidden = !scenario.empty
            content.count.stringValue = "\(rows.items.count) \(scenario.projects ? "projects" : "places")"
            content.status.stringValue = scenario.projects ? "↵ open session · ⌘→ browse folder · ⌃F search deeper" : "3 places · ⌘R refresh"
            for (index, scope) in content.scopes.enumerated() { scope.chosen = index == (scenario.projects ? 5 : 0) }
            content.setDirectoryVisible(scenario.projects)
            content.setDirectoryLocation(path: scenario.projects ? "/Users/fixture/projects/company/platform/services/customer-experience" : nil, deep: false)
            content.setPreviewVisible(scenario.preview)
            let selected = min(2, max(0, rows.items.count - 1))
            if let item = rows.items.indices.contains(selected) ? rows.items[selected] : nil {
                let text = scenario.projects ? """
                \(item.path)

                Project directory
                Python · analytics pipeline

                Open in a Rex session with Return.
                Browse subdirectories with ⌘→.

                This fixture is read-only.
                """ : """
                $ cargo test --locked
                    Finished test profile in 0.42s
                     Running native picker tests

                running 4 tests
                test query::unicode_paths ... ok
                test rows::tree_ancestors ... ok
                test preview::stale_reply ... ok
                test projects::exact_path ... ok

                test result: ok. 4 passed; 0 failed

                東京 👩🏽‍💻 — terminal output remains readable.
                A long output line wraps within the preview panel instead of expanding the native picker past the visible screen.
                """
                content.showPreview(title: item.title, detail: item.path, text: text)
            } else {
                content.showPreview(title: "Preview", detail: "No selected target", text: "Choose a terminal or project to inspect.")
            }
            content.layoutSubtreeIfNeeded()
            content.table.reloadData()
            if !rows.items.isEmpty { content.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw NSError(domain: "RenderFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create view bitmap"])
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let destination = output.appendingPathComponent(scenario.name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
            print(destination.path)
            window.close()
        }
    }
}
