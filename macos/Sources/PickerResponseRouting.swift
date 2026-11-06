// Keep response ownership independent of AppKit, so delayed query replies
// cannot release the controller's action guard or replace its action status.
enum PickerResponseRoute: Equatable {
    case action, dashboardAction, activation, query, ignored
}

enum PickerResponseRouting {
    static func route(id: Int, actionRequest: Int?, activation: Int?, pending: Int, dashboardRequest: Int? = nil) -> PickerResponseRoute {
        guard id >= 0 else { return .ignored }
        if let dashboardRequest {
            return id == dashboardRequest ? .dashboardAction : .ignored
        }
        if let actionRequest {
            return id == actionRequest ? .action : .ignored
        }
        if let activation {
            return id == activation ? .activation : .ignored
        }
        return id == pending ? .query : .ignored
    }
}
