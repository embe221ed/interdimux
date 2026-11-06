import Foundation

@main
struct SelectionTests {
    static func main() {
        let items = [
            PickerItem(["id": "parent", "kind": "session", "context_only": true])!,
            PickerItem(["id": "exact", "kind": "directory", "title": "fluid-packages-sui"])!,
            PickerItem(["id": "fuzzy", "kind": "window", "title": "a weaker match"])!
        ]
        let current = PickerSearchIdentity(query: "fluid")
        func choose(_ previous: PickerSearchIdentity?, previousID: String? = "fuzzy", preferredID: String? = "exact") -> Int? {
            PickerSelection.index(in: items, previousID: previousID, preferredID: preferredID, previousSearch: previous, search: current)
        }
        precondition(choose(PickerSearchIdentity(query: "flui")) == 1)
        precondition(choose(PickerSearchIdentity(query: "fluid", scope: "window")) == 1)
        precondition(choose(PickerSearchIdentity(query: "fluid", field: "name")) == 1)
        precondition(choose(PickerSearchIdentity(query: "fluid", actionFilter: "rename")) == 1)
        precondition(choose(PickerSearchIdentity(query: "fluid", directoryBase: "/another-project")) == 1)
        precondition(choose(PickerSearchIdentity(query: "fluid", directoryDeep: true)) == 1)
        precondition(choose(nil) == 1, "Reopening must use the new preferred target")
        precondition(choose(current) == 2, "Same-search refresh preserves manual selection")
        precondition(choose(current, previousID: "gone") == 1)
        precondition(choose(current, previousID: "parent") == 1)
        precondition(choose(nil, preferredID: "parent") == 1)
        precondition(choose(nil, preferredID: "gone") == 1)
        precondition(choose(nil, previousID: nil, preferredID: nil) == 1)
        precondition(PickerSelection.index(in: [], previousID: nil, preferredID: nil, previousSearch: nil, search: current) == nil)
        precondition(PickerSelection.index(in: [items[0]], previousID: "parent", preferredID: "parent", previousSearch: current, search: current) == nil)
        // A late reply is filtered by response routing before selection runs.
        // Only the last applied search identity matters after rapid typing.
        precondition(choose(PickerSearchIdentity(query: "f")) == 1)
        print("Selection checks passed: best new-query match, field/scope/action changes, refresh preservation, context and stale targets")
    }
}
