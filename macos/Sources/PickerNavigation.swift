import Foundation

enum PickerNavigation {
    /// A bounded walk also handles an empty list or a list containing only
    /// contextual ancestors. Missing selection starts at the appropriate end.
    static func nextIndex(current: Int, count: Int, direction: Int,
                          isSelectable: (Int) -> Bool) -> Int? {
        guard count > 0, direction != 0 else { return nil }
        let step = direction > 0 ? 1 : -1
        var index = (0..<count).contains(current) ? current : (step > 0 ? count - 1 : 0)
        for _ in 0..<count {
            index = (index + step + count) % count
            if isSelectable(index) { return index }
        }
        return nil
    }
}

enum DashboardRoute: String, CaseIterable {
    case `switch`, attention, projects, rename, close, swap, zoom, send
    case nextAgent = "next-agent", schedule, jobs, health

    var operation: String? {
        switch self {
        case .rename, .close, .swap, .zoom, .send: return rawValue
        default: return nil
        }
    }
    var scope: Int {
        switch self {
        case .attention: return 4
        case .projects: return 5
        case .swap: return 2
        case .zoom: return 3
        default: return 0
        }
    }
    var isExternalAction: Bool { [.nextAgent, .schedule, .jobs, .health].contains(self) }
    var title: String {
        switch self {
        case .switch: return "Switch"
        case .attention: return "Agents needing attention"
        case .projects: return "New session"
        case .rename: return "Rename"
        case .close: return "Close"
        case .swap: return "Swap"
        case .zoom: return "Zoom"
        case .send: return "Send"
        case .nextAgent: return "Next agent"
        case .schedule: return "Schedule"
        case .jobs: return "Jobs"
        case .health: return "Health"
        }
    }
}
