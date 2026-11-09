import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func wait(_ description: String, until condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    try check(condition(), "Timed out: \(description)")
}

private func key(_ code: UInt16, _ characters: String, to window: NSWindow,
                 modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: code)!
    // Dispatch inside this test application, never through the system event
    // stream or into the user's picker/Rex instance.
    NSApp.sendEvent(event)
}

private final class Confirmation {
    let parent = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    var answer: Bool?
    var completions = 0

    init() throws {
        parent.isReleasedWhenClosed = false
        PickerDialogs.confirm(on: parent, title: "Close disposable test tab?",
                              message: "Offscreen confirmation regression", submit: "Close tab") { [weak self] answer in
            self?.answer = answer
            self?.completions += 1
        }
        try wait("confirmation sheet") { parent.attachedSheet != nil }
        try wait("initial Cancel focus") { (sheet.firstResponder as? NSButton)?.title == "Cancel" }
    }

    var sheet: NSWindow { parent.attachedSheet! }

    func tab(backwards: Bool = false) throws {
        let expected = backwards ? "Cancel" : "Close tab"
        key(48, backwards ? "\u{19}" : "\t", to: sheet, modifiers: backwards ? [.shift] : [])
        try wait("keyboard focus on \(expected)") { (sheet.firstResponder as? NSButton)?.title == expected }
        try check(answer == nil, "Tab navigation must not answer the confirmation")
    }

    func expect(_ expected: Bool, code: UInt16, characters: String, label: String) throws {
        key(code, characters, to: sheet)
        try wait(label) { answer != nil }
        try check(answer == expected, "\(label): expected \(expected), received \(String(describing: answer))")
        try check(completions == 1, "\(label): confirmation completed more than once")
    }

    func close() {
        if let sheet = parent.attachedSheet { parent.endSheet(sheet, returnCode: .abort) }
        parent.close()
    }
}

@main
struct PickerDialogTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()

        for (code, characters, name) in [(UInt16(36), "\r", "Return"), (UInt16(76), "\u{03}", "keypad Enter")] {
            let initial = try Confirmation()
            defer { initial.close() }
            try initial.expect(false, code: code, characters: characters, label: "initial \(name) cancels")

            let focused = try Confirmation()
            defer { focused.close() }
            try focused.tab()
            try focused.expect(true, code: code, characters: characters, label: "Tab then \(name) confirms Close tab")
        }

        let escape = try Confirmation()
        defer { escape.close() }
        try escape.tab()
        try escape.expect(false, code: 53, characters: "\u{1b}", label: "Escape cancels with Close tab focused")

        let backwards = try Confirmation()
        defer { backwards.close() }
        try backwards.tab()
        try backwards.tab(backwards: true)
        try backwards.expect(false, code: 36, characters: "\r", label: "Shift-Tab returns to Cancel")

        let space = try Confirmation()
        defer { space.close() }
        try space.tab()
        try space.expect(true, code: 49, characters: " ", label: "Space confirms the focused Close tab button")

        let scoped = try Confirmation()
        defer { scoped.close() }
        try scoped.tab()
        key(36, "\r", to: scoped.parent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(scoped.answer == nil, "A Return event for another window answered the confirmation")
        try scoped.expect(false, code: 53, characters: "\u{1b}", label: "scoped confirmation remains usable")

        print("Dialog checks passed: focused Return/keypad Enter, default Cancel, Escape, Tab/Shift-Tab, Space, window-scoped events")
    }
}
