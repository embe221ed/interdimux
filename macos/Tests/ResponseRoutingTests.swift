import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ route: PickerResponseRoute, _ expected: PickerResponseRoute, _ scenario: String) throws {
    if route != expected { throw TestFailure(description: "\(scenario): routed as \(route), expected \(expected)") }
}

@main
struct ResponseRoutingTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        // A project/create action may start while a previous query is pending.
        // Both a delayed error and delayed results use the query's ID. Neither
        // may reach showError/results and release the in-flight action guard.
        for response in ["error", "results"] {
            try expect(PickerResponseRouting.route(id: 21, actionRequest: 22, activation: nil, pending: 21),
                       .ignored, "delayed query \(response) during create action")
            try expect(PickerResponseRouting.route(id: 21, actionRequest: nil, activation: nil, pending: 21, dashboardRequest: 22),
                       .ignored, "delayed query \(response) during dashboard handoff")
        }
        try expect(PickerResponseRouting.route(id: 22, actionRequest: nil, activation: nil, pending: 21, dashboardRequest: 22),
                   .dashboardAction, "dashboard completion remains owned by handoff")
        try expect(PickerResponseRouting.route(id: -1, actionRequest: nil, activation: nil, pending: -1, dashboardRequest: -1),
                   .ignored, "invalid dashboard response")
        try expect(PickerResponseRouting.route(id: 22, actionRequest: 22, activation: nil, pending: 21),
                   .action, "create completion remains owned by the action")
        try expect(PickerResponseRouting.route(id: 20, actionRequest: 22, activation: nil, pending: 21),
                   .ignored, "older unrelated response during action")

        // The controller starts a fresh query/refresh after completing the
        // action. Its new ID becomes valid; old query/action replies do not.
        for old in [20, 21, 22] {
            try expect(PickerResponseRouting.route(id: old, actionRequest: nil, activation: nil, pending: 23),
                       .ignored, "stale response \(old) after action completion")
        }
        try expect(PickerResponseRouting.route(id: 23, actionRequest: nil, activation: nil, pending: 23),
                   .query, "fresh results after action completion")

        try expect(PickerResponseRouting.route(id: 30, actionRequest: nil, activation: 31, pending: 30),
                   .ignored, "query cannot interrupt activation")
        try expect(PickerResponseRouting.route(id: 31, actionRequest: nil, activation: 31, pending: 30),
                   .activation, "matching activation response")
        try expect(PickerResponseRouting.route(id: 32, actionRequest: nil, activation: 31, pending: 30),
                   .ignored, "unowned response during activation")

        // These controller states are intended to be exclusive. If a future
        // caller violates that invariant, an action retains conservative priority.
        try expect(PickerResponseRouting.route(id: 41, actionRequest: 40, activation: 41, pending: 42),
                   .ignored, "activation cannot override an active mutation")
        try expect(PickerResponseRouting.route(id: 40, actionRequest: 40, activation: 41, pending: 42),
                   .action, "action wins conflicting ownership")
        try expect(PickerResponseRouting.route(id: 40, actionRequest: 40, activation: 40, pending: 40),
                   .action, "action wins identical conflicting IDs")

        for absent in [-1, Int.min] {
            try expect(PickerResponseRouting.route(id: absent, actionRequest: absent, activation: absent, pending: absent),
                       .ignored, "missing or negative ID cannot match state")
        }
        try expect(PickerResponseRouting.route(id: 51, actionRequest: nil, activation: nil, pending: 51),
                   .query, "ordinary current query")
        try expect(PickerResponseRouting.route(id: 50, actionRequest: nil, activation: nil, pending: 51),
                   .ignored, "ordinary stale query")
        print("passed: delayed query errors/results, action ownership, post-action refresh, activation, conflicting state, missing IDs")
    }
}
