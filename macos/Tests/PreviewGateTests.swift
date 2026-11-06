import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

private func take(_ gate: inout PickerPreviewGate, at now: Double, target: String) throws -> PickerPreviewRequest {
    guard let request = gate.begin(at: now), request.targetID == target else {
        throw Failure(description: "Expected capture of \(target) at \(now)")
    }
    return request
}

@main
struct PreviewGateTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        var gate = PickerPreviewGate(debounce: 0.2)
        try check(gate.nextDeadline == nil && gate.begin(at: 0) == nil, "No selection must produce no work")
        gate.select("pane:a", at: 1)
        try check(gate.nextDeadline == 1.2, "Selection establishes one debounce deadline")
        gate.select("pane:a", at: 1.1)
        try check(gate.nextDeadline == 1.2, "Duplicate selection must not postpone or multiply capture")
        try check(gate.begin(at: 1.19) == nil, "Capture must wait for debounce")
        let first = try take(&gate, at: 1.2, target: "pane:a")
        try check(gate.nextDeadline == nil && gate.begin(at: 10) == nil, "Only one physical request may be in flight")
        try check(gate.finish(first), "Matching current preview should be accepted")
        gate.select("pane:a", at: 11)
        try check(gate.nextDeadline == nil && gate.begin(at: 100) == nil,
                  "Stable selection must not become a periodic capture loop")
        try check(!gate.finish(first), "Duplicate response is ignored")

        // Rapid keyboard navigation creates only the latest request, never one
        // RPC per intermediate selection, even when old timers still fire.
        gate.select("pane:b", at: 20)
        gate.select("pane:c", at: 20.1)
        gate.select("pane:d", at: 20.2)
        try check(gate.begin(at: 20.21) == nil, "Old debounce callback cannot capture a new selection early")
        let latest = try take(&gate, at: 20.5, target: "pane:d")
        gate.select("pane:e", at: 20.6)
        gate.select("pane:f", at: 20.7)
        try check(gate.nextDeadline == nil && gate.begin(at: 30) == nil,
                  "Selection changes coalesce while the worker remains occupied")
        try check(!gate.finish(latest), "Previous selection's response must be discarded")
        let coalesced = try take(&gate, at: 30, target: "pane:f")
        try check(gate.finish(coalesced), "Only the newest coalesced selection is accepted")

        // Search input often changes before its result/selection notification.
        gate.select("pane:g", at: 40)
        for tick in 1...100 {
            let now = 40 + Double(tick) * 0.05
            gate.noteInput(at: now)
            try check(gate.begin(at: now + 0.01) == nil, "Typing must postpone captures, including old timer callbacks")
        }
        let afterTyping = try take(&gate, at: 45.3, target: "pane:g")
        try check(gate.finish(afterTyping), "One capture follows settled input")
        gate.noteInput(at: 46)
        try check(gate.nextDeadline == nil, "Input alone must not recapture an unchanged target")

        gate.select("pane:typing", at: 47)
        let beforeInput = try take(&gate, at: 47.3, target: "pane:typing")
        gate.noteInput(at: 47.4)
        try check(!gate.finish(beforeInput), "Typing immediately invalidates in-flight content before new results arrive")
        try check(gate.begin(at: 47.5) == nil, "Replacement must wait for typing to settle")
        let settledInput = try take(&gate, at: 47.7, target: "pane:typing")
        try check(gate.finish(settledInput), "Typing coalesces one replacement for the current target")

        // A -> B -> A is a new selection revision, not permission to display an
        // old response merely because its target string happens to match again.
        gate.select("pane:a", at: 50)
        let oldA = try take(&gate, at: 50.3, target: "pane:a")
        gate.select("pane:b", at: 50.4)
        gate.select("pane:a", at: 50.5)
        try check(!gate.finish(oldA), "Returning to a target must not accept an obsolete revision")
        let newA = try take(&gate, at: 51, target: "pane:a")
        try check(newA.generation != oldA.generation && gate.finish(newA), "New revision remains independently capturable")

        // Hidden/disabled state never starts work. If the worker stays alive,
        // its physical slot remains occupied until that stale response arrives.
        gate.select("pane:h", at: 60)
        let hidden = try take(&gate, at: 60.3, target: "pane:h")
        gate.invalidate()
        try check(gate.nextDeadline == nil && gate.begin(at: 70) == nil, "Hidden state must not capture")
        gate.select("pane:i", at: 70)
        try check(gate.begin(at: 71) == nil, "Reopen cannot queue behind an undrained old request")
        try check(!gate.finish(hidden), "Hidden/context-invalidated content must be discarded")
        let reopened = try take(&gate, at: 71, target: "pane:i")
        try check(gate.finish(reopened), "Latest selection resumes after old request drains")

        // A stopped/replaced worker cannot hold the slot forever, and an old
        // callback cannot free the new worker's request even for the same ID.
        gate.select("pane:j", at: 80)
        let stopped = try take(&gate, at: 80.3, target: "pane:j")
        gate.invalidate(cancelInFlight: true)
        gate.select("pane:j", at: 81)
        let replacement = try take(&gate, at: 81.3, target: "pane:j")
        try check(!gate.finish(stopped), "Stopped worker callback cannot cross lifecycle generations")
        try check(gate.begin(at: 82) == nil, "Stale callback must not release a current request's slot")
        try check(gate.finish(replacement), "Replacement response is accepted")
        gate.select("pane:k", at: 90)
        gate.select(nil, at: 90.1)
        try check(gate.nextDeadline == nil && gate.begin(at: 91) == nil, "Missing/context-only selection cancels queued capture")
        gate.select("", at: 92)
        try check(gate.nextDeadline == nil, "Empty target is not a capture request")
        print("passed: preview debounce, typing deferral, one in-flight request, latest-selection coalescing, no polling, stale replies, hide/reopen/replaced-worker lifecycle")
    }
}
