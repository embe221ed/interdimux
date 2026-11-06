import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func item(_ id: String, _ kind: String, parent: String? = nil, context: Bool = false) -> PickerItem {
    var value: [String: Any] = [
        "id": id, "kind": kind, "title": "Same display name 東京 🧑🏽‍💻",
        "subtitle": "same command", "path": "/a/long/path/with/a/distinctive/tail",
        "context_only": context
    ]
    if let parent { value["parent_id"] = parent }
    return PickerItem(value)!
}

private struct Expected {
    let depth: Int
    let continuations: [Int]
    let next: Bool?
    let children: Bool

    init(_ depth: Int, _ continuations: [Int], _ next: Bool?, _ children: Bool) {
        self.depth = depth
        self.continuations = continuations
        self.next = next
        self.children = children
    }
}

private func expect(_ items: [PickerItem], _ expected: [Expected], _ scenario: String) throws {
    let positions = PickerTreeLayout.positions(for: items)
    try check(positions.count == expected.count, "\(scenario): wrong position count")
    for (index, value) in positions.enumerated() {
        let wanted = expected[index]
        let prefix = "\(scenario), \(items[index].id)"
        try check(value.depth == wanted.depth, "\(prefix): depth \(value.depth), expected \(wanted.depth)")
        try check(value.ancestorContinuations == wanted.continuations,
                  "\(prefix): continuation columns \(value.ancestorContinuations), expected \(wanted.continuations)")
        if let next = wanted.next {
            try check(value.hasNextSibling == next, "\(prefix): incorrect next-sibling branch")
        }
        try check(value.hasChildren == wanted.children, "\(prefix): incorrect child downstroke")
    }
}

@main
struct TreeLayoutTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        try expect([], [], "empty results")
        try expect([item("session", "session")], [Expected(0, [], nil, false)], "empty session")

        // Equal labels deliberately ensure hierarchy depends on native IDs.
        let tree = [
            item("s1", "session"),
            item("t1", "window", parent: "s1"),
            item("p11", "pane", parent: "t1"),
            item("p12", "pane", parent: "t1"),
            item("t2", "window", parent: "s1"),
            item("p21", "pane", parent: "t2"),
            item("s2", "session"),
            item("t3", "window", parent: "s2"),
            item("p31", "pane", parent: "t3"),
            item("t4", "window", parent: "s2")
        ]
        try expect(tree, [
            Expected(0, [], nil, true),
            Expected(1, [], true, true),
            Expected(2, [0], true, false),
            Expected(2, [0], false, false),
            Expected(1, [], false, true),
            Expected(2, [], false, false),
            Expected(0, [], nil, true),
            Expected(1, [], true, true),
            Expected(2, [0], false, false),
            Expected(1, [], false, false)
        ], "two independent sessions with multiple tabs and panes")

        let filtered = [
            item("s1", "session", context: true),
            item("t1", "window", parent: "s1", context: true),
            item("p12", "pane", parent: "t1"),
            item("t2", "window", parent: "s1", context: true),
            item("p21", "pane", parent: "t2")
        ]
        try check(filtered[0].contextOnly && filtered[1].contextOnly && !filtered[2].contextOnly,
                  "Context-only flags were not decoded")
        try check(filtered[2].parentID == "t1", "Native parent ID was not decoded")
        try expect(filtered, [
            Expected(0, [], nil, true), Expected(1, [], true, true), Expected(2, [0], false, false),
            Expected(1, [], false, true), Expected(2, [], false, false)
        ], "filtered matches retain contextual ancestor branches")
        try expect(Array(filtered.prefix(3)), [
            Expected(0, [], nil, true), Expected(1, [], false, true), Expected(2, [], false, false)
        ], "one matching chain has no phantom sibling trunk")

        try expect([
            item("missing-parent-pane", "pane", parent: "not-present"),
            item("forward-parent-pane", "pane", parent: "late-tab"),
            item("s", "session"), item("late-tab", "window", parent: "s")
        ], [
            Expected(0, [], nil, false), Expected(0, [], nil, false),
            Expected(0, [], nil, true), Expected(1, [], false, false)
        ], "missing and forward parents become roots without backwards branches")

        try expect([
            item("orphan-tab", "window", parent: "missing-session"),
            item("child", "pane", parent: "orphan-tab"),
            item("independent", "session")
        ], [Expected(0, [], nil, true), Expected(1, [], false, false), Expected(0, [], nil, false)],
        "depth follows visible ancestry rather than row kind")

        try expect([
            item("forward-tab", "window", parent: "later-session"),
            item("child", "pane", parent: "forward-tab"),
            item("later-session", "session")
        ], [Expected(0, [], nil, true), Expected(1, [], false, false), Expected(0, [], nil, false)],
        "valid child of a forward-parent root stays attached locally")

        try expect([
            item("self-parent", "window", parent: "self-parent"),
            item("child", "pane", parent: "self-parent")
        ], [Expected(0, [], nil, true), Expected(1, [], false, false)], "self reference cannot recurse")

        // Result count stays unchanged while ranking exchanges two subtrees.
        // A reused row slot must receive new continuation metadata by position.
        let beforeReordering = Array(tree.prefix(6))
        let originalPositions = PickerTreeLayout.positions(for: beforeReordering)
        let reordered = [tree[0], tree[4], tree[5], tree[1], tree[2], tree[3]]
        try check(beforeReordering.count == reordered.count && originalPositions[2].ancestorContinuations == [0],
                  "Reordering fixture must start with a continued first-tab branch")
        try expect(reordered, [
            Expected(0, [], nil, true), Expected(1, [], true, true), Expected(2, [0], false, false),
            Expected(1, [], false, true), Expected(2, [], true, false), Expected(2, [], false, false)
        ], "reranked subtrees recompute their branch continuations")

        var capped = [item("s", "session"), item("t", "window", parent: "s")]
        capped += (0..<98).map { item("p\($0)", "pane", parent: "t") }
        let cappedPositions = PickerTreeLayout.positions(for: capped)
        try check(cappedPositions.count == 100, "Display cap fixture lost rows")
        try check(cappedPositions[98].hasNextSibling && !cappedPositions[99].hasNextSibling,
                  "The final visible pane must terminate its branch")
        try check(cappedPositions.allSatisfy { $0.ancestorContinuations.isEmpty },
                  "A capped single-tab tree gained a phantom continuation")
        print("Tree layout checks passed: branches, roots, filtered ancestors, missing/forward parents, reordering, 100-row boundary")
    }
}
