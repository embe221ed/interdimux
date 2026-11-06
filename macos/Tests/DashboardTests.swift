import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(description: message) }
}
private func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
    inner.minX >= outer.minX && inner.maxX <= outer.maxX && inner.minY >= outer.minY && inner.maxY <= outer.maxY
}

@main
struct DashboardTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let actions = DashboardCatalog.actions
        try check(actions.count == 12 && Set(actions.map(\.id)).count == 12 && Set(actions.map(\.key)).count == 12,
                  "Dashboard IDs and letter shortcuts must remain unique")
        try check(Dictionary(uniqueKeysWithValues: actions.map { ($0.key, $0.id) }) == [
            "s": "switch", "e": "attention", "j": "next-agent", "n": "projects", "r": "rename", "i": "close",
            "w": "swap", "z": "zoom", "t": "send", "a": "schedule", "o": "jobs", "h": "health"
        ], "Dashboard keys diverged from the terminal dashboard")
        try check(Set(actions.filter(\.terminal).map(\.id)) == Set(["schedule", "jobs", "health"]),
                  "Only the three terminal handoffs should be marked Terminal")
        try check(DashboardSummary(counts: ["sessions": 3, "windows": 8, "panes": 12, "attention": -1]) == DashboardSummary(sessions: 3, tabs: 8, panes: 12, attention: 0),
                  "Summary decoding must accept window counts and clamp invalid negative counts")
        for screen in [NSRect(x: 0, y: 25, width: 1512, height: 919), NSRect(x: -1280, y: -720, width: 1280, height: 695), NSRect(x: 0, y: 0, width: 720, height: 480)] {
            let panel = DashboardGeometry.panelFrame(in: screen)
            try check(contains(screen.insetBy(dx: 24, dy: 30), panel), "Dashboard escapes a compact or secondary screen")
        }
        for width: CGFloat in [520, 620, 680, 940] {
            let layout = DashboardGeometry.groups(width: width)
            let bounds = NSRect(x: 0, y: 0, width: width, height: layout.height)
            try check(layout.frames.count == 4 && layout.frames.allSatisfy { contains(bounds, $0) }, "Group card escapes scroll document")
            for first in layout.frames.indices {
                for second in layout.frames.indices where second > first {
                    try check(!layout.frames[first].intersects(layout.frames[second]), "Dashboard group cards overlap")
                }
            }
        }

        let view = DashboardView(frame: NSRect(x: 0, y: 0, width: 940, height: 680))
        var choices: [String] = []
        var cancelled = 0
        view.onChoose = { choices.append($0) }
        view.onCancel = { cancelled += 1 }
        view.setLoading(true)
        try check(view.choose(key: "N") && choices.last == "projects", "Native actions must be available before summary loads")
        view.updateSummary(DashboardSummary(sessions: 4, tabs: 13, panes: 24, attention: 2))
        try check(view.selectedActionID == "projects", "Summary refresh must not steal keyboard selection")
        view.resetSelection()
        view.moveSelection(-1)
        try check(view.selectedActionID == "health", "Up from first action should wrap")
        view.moveSelection(1)
        try check(view.selectedActionID == "switch", "Down from last action should wrap")
        for action in actions {
            try check(view.choose(key: action.key) && choices.last == action.id, "Wrong direct action mapping for \(action.key)")
        }
        let count = choices.count
        try check(!view.choose(key: "?") && choices.count == count, "Unknown keys must not dispatch an action")
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        view.resetSelection()
        key("n", code: 45, modifiers: .control)
        try check(view.selectedActionID == "attention", "Control-N must navigate without opening New session")
        key("\r", code: 36)
        try check(choices.last == "attention", "Return should open the selected action")
        key("\t", code: 48, modifiers: .shift)
        try check(view.selectedActionID == "switch", "Shift-Tab should navigate backwards")
        key("q", code: 12)
        key("\u{1b}", code: 53)
        try check(cancelled == 2, "Escape and q should dismiss")
        let compactLayout = DashboardGeometry.groups(width: 680, rowHeight: 35)
        try check(compactLayout.height <= 560 - 154 - 51, "All dashboard tools must fit the compact two-column panel")

        let smallFrame = NSRect(x: 0, y: 0, width: 520, height: 480)
        let smallWindow = NSWindow(contentRect: smallFrame, styleMask: .borderless, backing: .buffered, defer: false)
        smallWindow.isReleasedWhenClosed = false
        let smallDashboard = DashboardView(frame: smallFrame)
        smallWindow.contentView = smallDashboard
        smallDashboard.layoutSubtreeIfNeeded()
        smallDashboard.moveSelection(-1)
        smallDashboard.layoutSubtreeIfNeeded()
        let scroll = smallDashboard.subviews.compactMap { $0 as? NSScrollView }.first!
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let health = descendants(smallDashboard).first { $0.accessibilityIdentifier() == "health" }!
        try check(scroll.documentVisibleRect.contains(health.convert(health.bounds, to: scroll.documentView)),
                  "Keyboard navigation must reveal tools below the compact viewport")
        try check((health as? NSButton)?.refusesFirstResponder == true,
                  "A queued action click must leave dashboard letter navigation available")
        smallWindow.close()

        if CommandLine.arguments.count > 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, size, loading) in [
                ("dashboard-wide", NSSize(width: 940, height: 680), false),
                ("dashboard-compact", NSSize(width: 680, height: 560), false),
                ("dashboard-narrow", NSSize(width: 520, height: 480), false),
                ("dashboard-loading", NSSize(width: 940, height: 680), true)
            ] {
                let frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                let dashboard = DashboardView(frame: frame)
                window.contentView = dashboard
                if !loading { dashboard.updateSummary(DashboardSummary(sessions: 4, tabs: 13, panes: 24, attention: 2)) }
                dashboard.setLoading(loading)
                dashboard.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let bitmap = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds) else {
                    throw TestFailure(description: "Unable to render dashboard")
                }
                dashboard.cacheDisplay(in: dashboard.bounds, to: bitmap)
                let destination = output.appendingPathComponent(name + ".png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
                print(destination.path)
                window.close()
            }
        }
        print("Dashboard checks passed: keyboard routes, immediate actions, count refresh, compact geometry")
    }
}
