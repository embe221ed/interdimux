struct PickerPreviewRequest: Equatable {
    let generation: UInt64
    let targetID: String
}

/// Pure scheduling state. The controller owns its timer and independent preview
/// worker; no polling, capture, or timer is created by this gate.
struct PickerPreviewGate {
    private let debounce: Double
    private var generation: UInt64 = 0
    private var selectedID: String?
    private var queued = false
    private var lastActivity = -Double.infinity
    private var inFlight: PickerPreviewRequest?

    init(debounce: Double = 0.18) {
        precondition(debounce.isFinite && debounce >= 0)
        self.debounce = debounce
    }

    /// Empty/nil means no eligible selection. Repeated selection notifications
    /// for the same target do not recapture it or postpone its existing deadline.
    mutating func select(_ targetID: String?, at now: Double) {
        let targetID = targetID.flatMap { $0.isEmpty ? nil : $0 }
        guard targetID != selectedID else { return }
        selectedID = targetID
        generation += 1
        queued = targetID != nil
        lastActivity = max(lastActivity, now)
    }

    /// Call on search edits, including IME composition, even before new results
    /// arrive. Typing invalidates an in-flight capture immediately and postpones
    /// the one coalesced replacement; it never queues parallel requests.
    mutating func noteInput(at now: Double) {
        lastActivity = max(lastActivity, now)
        if let request = inFlight, request.generation == generation, selectedID != nil {
            generation += 1
            queued = true
        }
    }

    /// Schedule one callback for this uptime, only when the worker is ready.
    /// A completing request may expose an already-due coalesced replacement.
    var nextDeadline: Double? {
        guard queued, selectedID != nil, inFlight == nil else { return nil }
        return lastActivity + debounce
    }

    /// Takes at most one slot. Checking again while the worker is occupied
    /// cannot enqueue more requests, regardless of how often selection changes.
    mutating func begin(at now: Double) -> PickerPreviewRequest? {
        guard let deadline = nextDeadline, now >= deadline, let targetID = selectedID else { return nil }
        let request = PickerPreviewRequest(generation: generation, targetID: targetID)
        inFlight = request
        queued = false
        return request
    }

    /// Always finish a matching worker response, even if the panel is hidden.
    /// The return value says whether its content still belongs to the current
    /// selection. A stale response frees its slot but cannot consume newer work.
    mutating func finish(_ request: PickerPreviewRequest) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        return selectedID == request.targetID && generation == request.generation
    }

    /// Hide, mutation, context change, or preview disable makes old content
    /// invalid. Preserve the physical worker slot until its reply unless the
    /// controller has stopped/replaced that worker (cancelInFlight: true).
    mutating func invalidate(cancelInFlight: Bool = false) {
        generation += 1
        selectedID = nil
        queued = false
        if cancelInFlight { inFlight = nil }
    }
}
