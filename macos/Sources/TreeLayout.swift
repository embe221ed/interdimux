import Foundation

struct PickerTreePosition: Equatable {
    let depth: Int
    let ancestorContinuations: [Int]
    let hasNextSibling: Bool
    let hasChildren: Bool
}

enum PickerTreeLayout {
    /// Refresh metadata in the cached slots. Catalog permutations must not
    /// move an already visible list; new siblings follow surviving siblings.
    static func preservingOrder(of cached: [PickerItem], in fresh: [PickerItem]) -> [PickerItem] {
        var byID: [String: PickerItem] = [:]
        for item in fresh { byID[item.id] = item }
        if cached.count == fresh.count,
           cached.allSatisfy({ byID[$0.id]?.parentID == $0.parentID && byID[$0.id] != nil }) {
            return cached.compactMap { byID[$0.id] }
        }
        var ranks: [String: Int] = [:]
        for (index, item) in cached.enumerated() { ranks[item.id] = index }
        var children: [String: [PickerItem]] = [:]
        var roots: [PickerItem] = []
        var seen = Set<String>()
        // As in positions(), only preceding parents form a visible branch.
        for item in fresh {
            if let parent = item.parentID, seen.contains(parent) {
                children[parent, default: []].append(item)
            } else { roots.append(item) }
            seen.insert(item.id)
        }
        func ordered(_ siblings: [PickerItem], roots: Bool = false) -> [PickerItem] {
            siblings.enumerated().sorted { lhs, rhs in
                if roots, (lhs.element.kind == "directory") != (rhs.element.kind == "directory") {
                    return rhs.element.kind == "directory"
                }
                let left = ranks[lhs.element.id] ?? Int.max
                let right = ranks[rhs.element.id] ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        }
        var result: [PickerItem] = []
        result.reserveCapacity(fresh.count)
        var stack = Array(ordered(roots, roots: true).reversed())
        while let item = stack.popLast() {
            result.append(item)
            if let descendants = children[item.id] {
                stack.append(contentsOf: ordered(descendants).reversed())
            }
        }
        return result
    }

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
