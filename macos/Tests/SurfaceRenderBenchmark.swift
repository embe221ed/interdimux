import AppKit

private func dashboardBenchmark(window: NSWindow, frame: NSRect) -> [String: Any] {
    let started = ProcessInfo.processInfo.systemUptime
    let view = DashboardView(frame: frame)
    window.contentView = view
    view.setLoading(false)
    view.updateSummary(DashboardSummary(sessions: 7, tabs: 21, panes: 36, attention: 2))
    view.layoutSubtreeIfNeeded()
    let initial = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let down = NSEvent(cgEvent: CGEvent(keyboardEventSource: nil, virtualKey: 125, keyDown: true)!)!
    var navigation: [Double] = [], counts: [Double] = [], paint: [Double] = []
    var visited = Set<String>()
    for iteration in 0..<36 {
        let start = ProcessInfo.processInfo.systemUptime
        view.keyDown(with: down)
        view.layoutSubtreeIfNeeded()
        let moved = ProcessInfo.processInfo.systemUptime
        let count = (iteration % 12) + 1
        view.updateSummary(DashboardSummary(sessions: count, tabs: count * 2, panes: count * 3, attention: iteration % 4))
        view.layoutSubtreeIfNeeded()
        let updated = ProcessInfo.processInfo.systemUptime
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let painted = ProcessInfo.processInfo.systemUptime
        visited.insert(view.selectedActionID)
        if iteration >= 12 {
            navigation.append((moved - start) * 1_000)
            counts.append((updated - moved) * 1_000)
            paint.append((painted - updated) * 1_000)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    precondition(visited.count == DashboardCatalog.actions.count, "Navigation must exercise every action")
    return ["initial_layout_ms": initial, "key_layout": summary(navigation), "summary_layout": summary(counts),
            "paint_bitmap": summary(paint), "samples": paint.count]
}

private func previewBenchmark(window: NSWindow, frame: NSRect) -> [String: Any] {
    let view = PickerPreviewView(frame: frame)
    window.contentView = view
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    let output = (0..<40).map { "src/module/remote/terminal-\($0): Build step 東京 completed (10ms)." }.joined(separator: "\n")
    let results = [output, output + "\nTests completed"]
    let titles = ["Agent summary", "Test suite"]
    let detail = "/Users/fixture/source/workspaces/interdimux"
    var changed: [Double] = [], repeated: [Double] = [], paint: [Double] = []
    for iteration in 0..<72 {
        let index = iteration % results.count
        let start = ProcessInfo.processInfo.systemUptime
        view.show(title: titles[index], detail: detail, text: results[index], loading: false)
        view.layoutSubtreeIfNeeded()
        let updated = ProcessInfo.processInfo.systemUptime
        view.show(title: titles[index], detail: detail, text: results[index], loading: false)
        view.layoutSubtreeIfNeeded()
        let reapplied = ProcessInfo.processInfo.systemUptime
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let painted = ProcessInfo.processInfo.systemUptime
        if iteration >= 12 {
            changed.append((updated - start) * 1_000)
            repeated.append((reapplied - updated) * 1_000)
            paint.append((painted - reapplied) * 1_000)
        }
    }
    return ["changed_layout": summary(changed), "repeated_layout": summary(repeated),
            "paint_bitmap": summary(paint), "samples": paint.count]
}

@main
struct SurfaceRenderBenchmark {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let mode = CommandLine.arguments[1]
        let size: NSSize
        if mode == "preview" { size = NSSize(width: 388, height: 560) }
        else if CommandLine.arguments.contains("--compact") { size = NSSize(width: 680, height: 560) }
        else { size = NSSize(width: 940, height: 680) }
        let frame = NSRect(origin: .zero, size: size)
        let window = benchmarkWindow(frame)
        let results = mode == "preview" ? previewBenchmark(window: window, frame: frame)
                                        : dashboardBenchmark(window: window, frame: frame)
        try printBenchmark(results, mode: mode, frame: frame)
        window.close()
    }
}
