import Foundation

@main
struct NavigationTests {
    static func main() {
        func next(_ current: Int, _ delta: Int, _ enabled: [Bool]) -> Int? {
            PickerNavigation.nextIndex(current: current, count: enabled.count, direction: delta) { enabled[$0] }
        }
        precondition(next(2, 1, [true, true, true]) == 0)
        precondition(next(0, -1, [true, true, true]) == 2)
        precondition(next(3, 1, [false, true, false, true, false]) == 1)
        precondition(next(1, -1, [false, true, false, true, false]) == 3)
        precondition(next(-1, 1, [false, true, true]) == 1)
        precondition(next(-1, -1, [true, true, false]) == 1)
        precondition(next(99, 1, [true]) == 0)
        precondition(next(0, -1, [true]) == 0)
        precondition(next(0, 1, []) == nil)
        precondition(next(0, 1, [false, false]) == nil)
        precondition(next(0, 0, [true]) == nil)
        precondition(DashboardRoute.allCases.count == 12)
        precondition(DashboardRoute(rawValue: "unknown") == nil)
        precondition(DashboardRoute.rename.operation == "rename" && DashboardRoute.rename.scope == 0)
        precondition(DashboardRoute.swap.scope == 2 && DashboardRoute.zoom.scope == 3)
        precondition(DashboardRoute.projects.operation == nil && DashboardRoute.projects.scope == 5)
        precondition(DashboardRoute.attention.scope == 4)
        precondition(DashboardRoute.allCases.filter(\.isExternalAction).map(\.rawValue) == ["next-agent", "schedule", "jobs", "health"])
        print("Navigation checks passed: bidirectional wrap, contextual rows, empty/single/unselected results, dashboard routes")
    }
}
