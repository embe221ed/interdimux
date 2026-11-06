import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func contains(_ parent: NSRect, _ child: NSRect) -> Bool {
    let tolerance: CGFloat = 0.001
    return child.minX >= parent.minX - tolerance && child.maxX <= parent.maxX + tolerance
        && child.minY >= parent.minY - tolerance && child.maxY <= parent.maxY + tolerance
}

@main
struct PickerGeometryTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        // Visible frames include the menu bar and Dock offsets, and may have
        // negative origins on a secondary display.
        let screens = [
            NSRect(x: 0, y: 25, width: 1512, height: 919),
            NSRect(x: -1920, y: -1080, width: 1920, height: 1055),
            NSRect(x: 1512, y: 100, width: 1280, height: 720),
            NSRect(x: 0, y: 0, width: 720, height: 480),
            NSRect(x: 100, y: 200, width: 500, height: 300),
            NSRect(x: 3, y: 4, width: 20, height: 20),
            NSRect(x: 3, y: 4, width: 0, height: 0)
        ]
        for screen in screens {
            let frame = PickerGeometry.panelFrame(in: screen)
            try check(contains(screen, frame), "Panel escapes visible screen: \(screen) -> \(frame)")
            try check(frame.width >= 0 && frame.height >= 0, "Panel has a negative dimension")
            try check(frame.width <= 1080 && frame.height <= 760, "Panel exceeds preferred size")
            try check(abs(frame.midX - screen.midX) < 0.001, "Panel is not horizontally centered")
            if screen.width >= 48 {
                try check(frame.minX >= screen.minX + 24 && frame.maxX <= screen.maxX - 24,
                          "Panel loses horizontal screen margin")
            }
            if screen.height >= 60 {
                try check(frame.minY >= screen.minY + 30 && frame.maxY <= screen.maxY - 30,
                          "Upward placement consumes the screen margin")
            }
        }
        try check(PickerGeometry.panelFrame(in: screens[0]).size == NSSize(width: 1080, height: 760),
                  "Large screens should use the requested 1080 × 760 panel")

        // At the minimum supported panel width, opening the preview must leave
        // enough room for the deepest tree identity. Hiding restores all width.
        for width: CGFloat in [0, 200, 321, 500, 672, 720, 1080] {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 520)
            let hidden = PickerGeometry.contentFrames(in: bounds, preview: false)
            try check(hidden.list == bounds && hidden.preview == .zero, "Hidden preview consumes list width")
            let shown = PickerGeometry.contentFrames(in: bounds, preview: true)
            try check(contains(bounds, shown.list) && contains(bounds, shown.preview), "Preview split escapes bounds")
            try check(shown.list.maxX == shown.preview.minX && shown.preview.maxX == width,
                      "Preview split has a gap or overlap")
            try check(shown.list.width + shown.preview.width == width, "Preview split loses width")
            if width >= 720 {
                try check(shown.preview.width >= 280 && shown.preview.width <= 400, "Preview width is not bounded")
                try check(shown.list.width >= 440, "Preview starves the list on a small panel")
            }
        }

        for width: CGFloat in [0, 40, 200, 321, 392, 440, 600, 680, 720, 1080] {
            for depth in 0...2 {
                let row = PickerGeometry.rowFrames(width: width, depth: depth)
                let bounds = NSRect(x: 0, y: 0, width: width, height: 38)
                for rect in [row.symbol, row.title, row.path, row.kind, row.current] {
                    try check(contains(bounds, rect), "Row field exceeds viewport at \(width), depth \(depth): \(rect)")
                }
                try check(row.path.width <= 340, "Path column exceeds its maximum")
                if width >= 392 {
                    try check(row.title.width >= 150, "Preview leaves less than 150 pt for a tree identity")
                    try check(row.symbol.maxX < row.title.minX, "Icon overlaps the title")
                    try check(row.title.maxX <= row.path.minX, "Title overlaps the path")
                    try check(row.path.maxX < row.current.minX && row.current.maxX < row.kind.minX,
                              "Path, current marker and type columns overlap")
                }
            }
        }
        let narrow = PickerGeometry.rowFrames(width: 392, depth: 2)
        try check(narrow.path.width == 0 && narrow.title.width >= 150,
                  "At narrow widths the path must yield before the pane name")
        for width: CGFloat in [392, 440, 680, 1080] {
            let root = PickerGeometry.rowFrames(width: width, depth: 0)
            let pane = PickerGeometry.rowFrames(width: width, depth: 2)
            try check(root.path == pane.path && root.kind == pane.kind,
                      "Tree rows should retain aligned path and type columns at \(width) pt")
        }
        print("Picker geometry checks passed: screen margins, preview split, bounded columns, tree identity space")
    }
}
