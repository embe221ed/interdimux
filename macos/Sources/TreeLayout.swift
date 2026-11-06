import Foundation

struct PickerTreePosition: Equatable {
    let depth: Int
    let ancestorContinuations: [Int]
    let hasNextSibling: Bool
    let hasChildren: Bool
}

enum PickerTreeLayout {
    /// Work only with visible, preceding parents. Missing/forward references
    /// remain roots rather than drawing a branch to an unrelated result.
    static func positions(for items: [PickerItem]) -> [PickerTreePosition] {
        var seen: [String: Int] = [:]
        var parents: [Int?] = []
        var lastChild: [Int: Int] = [:]
        var hasChildren = Set<Int>()
        for (index, item) in items.enumerated() {
            let parent = item.parentID.flatMap { seen[$0] }
            parents.append(parent)
            if let parent {
                lastChild[parent] = index
                hasChildren.insert(parent)
            }
            seen[item.id] = index
        }
        var positions: [PickerTreePosition] = []
        positions.reserveCapacity(items.count)
        for index in items.indices {
            let parent = parents[index]
            let depth = parent.map { positions[$0].depth + 1 } ?? 0
            var continuations = parent.map { positions[$0].ancestorContinuations } ?? []
            if let parent, positions[parent].depth > 0, positions[parent].hasNextSibling {
                continuations.append(positions[parent].depth - 1)
            }
            positions.append(PickerTreePosition(depth: depth,
                ancestorContinuations: continuations,
                hasNextSibling: parent.map { lastChild[$0] != index } ?? false,
                hasChildren: hasChildren.contains(index)))
        }
        return positions
    }
}
