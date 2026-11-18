import AppKit

func benchmarkWindow(_ frame: NSRect) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    return window
}

func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    let median = (sorted[(sorted.count - 1) / 2] + sorted[middle]) / 2
    let p95 = sorted[Int(ceil(0.95 * Double(sorted.count))) - 1]
    return ["median_ms": median, "p95_ms": p95]
}

func printBenchmark(_ results: [String: Any], mode: String, frame: NSRect) throws {
    var report = results
    report["mode"] = mode
    report["width"] = Int(frame.width)
    report["height"] = Int(frame.height)
    report["measurement"] = "offscreen AppKit layout and CPU bitmap painting; excludes WindowServer/GPU presentation"
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
