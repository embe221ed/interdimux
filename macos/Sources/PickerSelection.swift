struct PickerSearchIdentity: Equatable {
    var query = ""
    var scope = "all"
    var field = "all"
    var actionFilter = ""
    var directoryBase: String?
    var directoryDeep = false
}

enum PickerSelection {
    static func index(in items: [PickerItem], previousID: String?, preferredID: String?,
                      previousSearch: PickerSearchIdentity?, search: PickerSearchIdentity) -> Int? {
        // Refreshes preserve deliberate navigation; editing the search selects
        // its best match instead of retaining a weaker, previously selected hit.
        if previousSearch == search, let previousID,
           let index = items.firstIndex(where: { $0.id == previousID && !$0.contextOnly }) {
            return index
        }
        if let preferredID,
           let index = items.firstIndex(where: { $0.id == preferredID && !$0.contextOnly }) {
            return index
        }
        return items.firstIndex(where: { !$0.contextOnly })
    }
}
