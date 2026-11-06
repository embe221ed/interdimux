import AppKit

struct DashboardAction: Equatable {
    let id: String
    let key: String
    let title: String
    let detail: String
    let symbol: String
    let group: String
    var terminal = false
}

enum DashboardCatalog {
    static let groups = ["NAVIGATE", "MANAGE", "AUTOMATE", "TOOLS"]
    static let actions: [DashboardAction] = [
        .init(id: "switch", key: "s", title: "Switch", detail: "Sessions, tabs, and panes", symbol: "arrow.left.arrow.right", group: "NAVIGATE"),
        .init(id: "attention", key: "e", title: "Agents", detail: "Waiting for approval or input", symbol: "person.crop.circle.badge.exclamationmark", group: "NAVIGATE"),
        .init(id: "next-agent", key: "j", title: "Next agent", detail: "Jump to the next waiting agent", symbol: "arrow.turn.down.right", group: "NAVIGATE"),
        .init(id: "projects", key: "n", title: "New session", detail: "Find a project directory", symbol: "plus.square", group: "NAVIGATE"),
        .init(id: "rename", key: "r", title: "Rename", detail: "Give a target a useful name", symbol: "pencil", group: "MANAGE"),
        .init(id: "close", key: "i", title: "Close", detail: "Choose a target, then confirm", symbol: "xmark", group: "MANAGE"),
        .init(id: "swap", key: "w", title: "Swap", detail: "Exchange two tabs or panes", symbol: "arrow.triangle.swap", group: "MANAGE"),
        .init(id: "zoom", key: "z", title: "Zoom", detail: "Focus or restore a pane", symbol: "arrow.up.left.and.arrow.down.right", group: "MANAGE"),
        .init(id: "send", key: "t", title: "Send", detail: "Send command text or a key", symbol: "paperplane", group: "AUTOMATE"),
        .init(id: "schedule", key: "a", title: "Schedule", detail: "Send later", symbol: "clock", group: "AUTOMATE", terminal: true),
        .init(id: "jobs", key: "o", title: "Jobs", detail: "Inspect output or cancel work", symbol: "list.bullet.rectangle", group: "AUTOMATE", terminal: true),
        .init(id: "health", key: "h", title: "Health", detail: "Check tools and setup", symbol: "checkmark.shield", group: "TOOLS", terminal: true)
    ]
}

struct DashboardSummary: Equatable {
    var sessions: Int?
    var tabs: Int?
    var panes: Int?
    var attention: Int?

    init(sessions: Int? = nil, tabs: Int? = nil, panes: Int? = nil, attention: Int? = nil) {
        self.sessions = sessions.map { max(0, $0) }
        self.tabs = tabs.map { max(0, $0) }
        self.panes = panes.map { max(0, $0) }
        self.attention = attention.map { max(0, $0) }
    }

    init(counts: [String: Int]) {
        self.init(sessions: counts["sessions"], tabs: counts["tabs"] ?? counts["windows"],
                  panes: counts["panes"], attention: counts["attention"])
    }
}

enum DashboardGeometry {
    static func panelFrame(in visible: NSRect) -> NSRect {
        let width = max(0, min(940, visible.width - 48))
        let height = max(0, min(680, visible.height - 60))
        let margin = min(30, max(0, visible.height / 2))
        let y = min(visible.midY - height / 2 + 32, visible.maxY - margin - height)
        return NSRect(x: visible.midX - width / 2, y: max(visible.minY + margin, y), width: width, height: height)
    }

    static func groups(width: CGFloat, rowHeight: CGFloat = 44) -> (frames: [NSRect], height: CGFloat) {
        let padding: CGFloat = min(28, max(0, width / 8))
        let available = max(0, width - padding * 2)
        let gap: CGFloat = 14
        let upperHeight = 48 + rowHeight * 4
        let lowerHeight = 48 + rowHeight * 3
        if width >= 620 {
            let column = max(0, (available - gap) / 2)
            return ([NSRect(x: padding, y: 0, width: column, height: upperHeight),
                     NSRect(x: padding + column + gap, y: 0, width: column, height: upperHeight),
                     NSRect(x: padding, y: upperHeight + gap, width: column, height: lowerHeight),
                     NSRect(x: padding + column + gap, y: upperHeight + gap, width: column, height: lowerHeight)], upperHeight + gap + lowerHeight)
        }
        let heights: [CGFloat] = [upperHeight, upperHeight, lowerHeight, 148]
        var y: CGFloat = 0
        let frames = heights.map { height -> NSRect in
            defer { y += height + gap }
            return NSRect(x: padding, y: y, width: available, height: height)
        }
        return (frames, max(0, y - gap))
    }
}
