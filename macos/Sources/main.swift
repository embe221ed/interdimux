import AppKit

final class PickerApplication: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let backend = PickerBackend()
    // Terminal capture is intentionally isolated from the query helper: even
    // a slow Rex preview cannot put keystrokes behind it on the JSON pipe.
    private let previewBackend = PickerBackend()
    private var previewGate = PickerPreviewGate()
    private var previewWork: DispatchWorkItem?
    private var previewOpening: Int?
    private var previewRequest: (id: Int, request: PickerPreviewRequest)?
    private var previewReady = false
    private var previewFailed = false
    private var previewTargetID: String?
    private let content = PickerView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
    private var dashboard: DashboardView?
    private var dashboardVisible = false
    private var dashboardOrigin = false
    private var dashboardCounts: [String: Int] = [:]
    private var targetRoute: DashboardRoute?
    private var deferredDashboardAction: DashboardRoute?
    private var dashboardRequest: Int?
    private var panel: PickerPanel!
    private var items: [PickerItem] = []
    private var tree: [PickerTreePosition] = []
    private var openingItems: [PickerItem] = []
    private var openingClientID: String?
    private var openingTotal = 0
    // The protocol caps each result at 100. Keep cells for those bounded row
    // slots across count changes, including no-match -> results transitions.
    private var cells: [Int: PickerCell] = [:]
    private var context: [String: String] = [:]
    private var scope = "all"
    private var directoriesLoaded = false
    private var directoryBase: String?
    private var directoryDeep = false
    private var searchField: String { content.searchField.selectedItem?.representedObject as? String ?? "all" }
    private var pending = 0
    private var displayedRequest = -1
    private var activation: Int?
    private var actionRequest: Int?
    private var presentingDialog = false
    private var queryDeferred = false
    private var menuChoice: String?
    private var swapSource: PickerItem?
    private var loading = false
    private var hasOpened = false
    private var originApplication: NSRunningApplication?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var requestedAt = ProcessInfo.processInfo.systemUptime
    private var benchmarkSamples: [Double] = []
    private var benchmarkStages: [[String: Double]] = []
    private var benchmarkQueries: [String] = []
    private var benchmarkIndex = 0
    private var benchmarking = false
    private var benchmarkOutput: String?
    private var capturePath: String?
    private var openBenchmarkOutput: String?
    private var openBenchmarkSamples: [[String: Any]] = []
    private var cachedFrameMS: Double?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupMenu()
        backend.onMessage = { [weak self] message in self?.receive(message) }
        backend.onFailure = { [weak self] message in self?.showError(message) }
        previewBackend.onMessage = { [weak self] message in self?.receivePreview(message) }
        previewBackend.onFailure = { [weak self] message in self?.previewFailure(message) }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--benchmark-output"), index + 1 < arguments.count {
            benchmarkOutput = arguments[index + 1]
            benchmarkQueries = Array(repeating: ["", "a", "ag", "agent", "src", "project", "zz-no-matches", "", "window", "pane", "λ", "東京"], count: 10).flatMap { $0 }
        }
        if let index = arguments.firstIndex(of: "--capture"), index + 1 < arguments.count { capturePath = arguments[index + 1] }
        if let index = arguments.firstIndex(of: "--benchmark-open-output"), index + 1 < arguments.count {
            openBenchmarkOutput = arguments[index + 1]
        }
        // Launch Services delivers URL events just after launch. Avoid a second
        // collection for that URL, while supporting opening the app from Finder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.hasOpened else { return }
            self.open(context: [:], dashboard: arguments.contains("--dashboard"))
        }
    }

    func setupPanel() {
        panel = PickerPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Interdimux Picker"
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onCommand = { [weak self] key in self?.command(key) ?? false }
        panel.onShortcut = { [weak self] event in self?.shortcut(event) ?? false }
        content.search.delegate = self
        content.table.dataSource = self
        content.table.delegate = self
        content.table.target = self
        content.table.doubleAction = #selector(acceptClickedRow)
        content.table.onAccept = { [weak self] in self?.accept() }
        content.table.onCancel = { [weak self] in self?.dismiss() }
        content.table.onNavigate = { [weak self] delta in self?.move(delta) }
        content.table.onType = { [weak self] event in
            guard let self else { return }
            self.panel.makeFirstResponder(self.content.search)
            self.content.search.currentEditor()?.keyDown(with: event)
        }
        content.clear.target = self
        content.clear.action = #selector(clearSearch)
        content.actions.target = self
        content.actions.action = #selector(showActions)
        content.dashboardButton.target = self
        content.dashboardButton.action = #selector(returnToDashboard)
        content.searchField.target = self
        content.searchField.action = #selector(changeSearchField)
        content.previewButton.target = self
        content.previewButton.action = #selector(togglePreview)
        content.directoryUp.target = self
        content.directoryUp.action = #selector(browseParent)
        content.directoryHome.target = self
        content.directoryHome.action = #selector(browseRecent)
        content.directoryDeep.target = self
        content.directoryDeep.action = #selector(searchDeeper)
        for button in content.scopes { button.target = self; button.action = #selector(changeScope(_:)) }
    }

    func setupMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Interdimux Picker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editRoot = NSMenuItem(); editRoot.submenu = editMenu; menu.addItem(editRoot)
        NSApp.mainMenu = menu
    }

    @objc func openURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: value), url.scheme == "interdimux-picker",
              ["open", "dashboard"].contains(url.host ?? "") else { return }
        let showDashboard = url.host == "dashboard"
        var supplied: [String: String] = [:]
        for item in url.queryItems ?? [] where ["client_id", "session_id", "window_id", "block_id"].contains(item.name) {
            if let value = item.value, !value.isEmpty { supplied[item.name] = value }
        }
        if panel == nil {
            DispatchQueue.main.async { [weak self] in self?.open(context: supplied, dashboard: showDashboard) }
        } else { open(context: supplied, dashboard: showDashboard) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { open(context: [:]) }
        return true
    }

    func open(context supplied: [String: String], dashboard showDashboard: Bool = false) {
        guard activation == nil, actionRequest == nil, dashboardRequest == nil, !presentingDialog else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        loading = true
        cachedFrameMS = nil
        hasOpened = true
        queryDeferred = false
        dashboardVisible = showDashboard
        dashboardOrigin = false
        targetRoute = nil
        deferredDashboardAction = nil
        content.setDashboardRoute(nil)
        stopPreview()
        context = supplied
        // Launch Services can deliver a URL after activating this app. Never
        // replace the real origin with ourselves when reopening the picker.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            originApplication = frontmost
        } else if !panel.isVisible {
            originApplication = nil
        }
        scope = "all"
        directoriesLoaded = false
        directoryBase = nil
        directoryDeep = false
        content.searchField.selectItem(at: 0)
        content.setDirectoryVisible(false)
        swapSource = nil
        content.search.stringValue = ""
        content.clear.isHidden = true
        for button in content.scopes { button.chosen = button.tag == 0 }
        items = openingClientID == supplied["client_id"] ? openingItems : []
        tree = PickerTreeLayout.positions(for: items)
        displayedRequest = -1
        if !showDashboard {
            updateTable()
            content.table.deselectAll(nil)
        }
        content.count.stringValue = items.isEmpty ? "" : "\(openingTotal) places"
        content.empty.isHidden = !items.isEmpty
        content.emptyTitle.stringValue = "Loading your workspace"
        content.emptyDetail.stringValue = "Sessions, tabs and panes, together."
        if content.previewVisible { content.showPreview(title: "Preview", detail: "", text: "Choose a terminal or project to inspect.") }
        content.status.stringValue = items.isEmpty ? "Connecting to Rex…" : "Refreshing…"
        content.status.textColor = Palette.secondary
        if showDashboard {
            let view = ensureDashboard()
            view.updateSummary(DashboardSummary(counts: openingClientID == supplied["client_id"] ? dashboardCounts : [:]))
            view.resetSelection()
            view.setLoading(true)
            view.setStatus("Refreshing your workspace…")
        }
        presentSurface()
        panel.makeKeyAndOrderFront(nil)
        if showDashboard { panel.makeFirstResponder(ensureDashboard()) }
        else { focusSearch() }
        if openBenchmarkOutput != nil && (!items.isEmpty || showDashboard) {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            cachedFrameMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        }
        do {
            try backend.start()
            pending = backend.send("open", fields: ["context": context])
        } catch { showError("Could not start the search helper: \(error.localizedDescription)") }
    }

    private func focusSearch() {
        panel.makeFirstResponder(content.search)
        if let editor = content.search.currentEditor() as? NSTextView {
            editor.insertionPointColor = Palette.accent
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
    }

    private func ensureDashboard() -> DashboardView {
        if let dashboard { return dashboard }
        let view = DashboardView(frame: NSRect(x: 0, y: 0, width: 940, height: 680))
        view.onChoose = { [weak self] in self?.chooseDashboard($0) }
        view.onCancel = { [weak self] in self?.dismiss() }
        dashboard = view
        return view
    }

    private func presentSurface() {
        let view: NSView = dashboardVisible ? ensureDashboard() : content
        if panel.contentView !== view { panel.contentView = view }
        panel.title = dashboardVisible ? "Interdimux Dashboard" : "Interdimux Picker"
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let frame = dashboardVisible ? DashboardGeometry.panelFrame(in: visible) : PickerGeometry.panelFrame(in: visible)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
        }
    }

    private func chooseDashboard(_ value: String) {
        guard dashboardVisible, let route = DashboardRoute(rawValue: value),
              dashboardRequest == nil, deferredDashboardAction == nil,
              activation == nil, actionRequest == nil, !presentingDialog else { return }
        if route.isExternalAction {
            if loading {
                deferredDashboardAction = route
                dashboard?.setStatus("\(route.title) · waiting for workspace…")
            } else { runDashboardAction(route) }
            return
        }
        dashboardVisible = false
        dashboardOrigin = true
        targetRoute = route
        content.setDashboardRoute(route.title)
        presentSurface()
        updateTable()
        content.table.deselectAll(nil)
        content.status.stringValue = "\(route.title) · choose a target · esc returns to dashboard"
        changeScope(content.scopes[route.scope])
        focusSearch()
    }

    private func runDashboardAction(_ route: DashboardRoute) {
        guard !loading, dashboardRequest == nil else { return }
        deferredDashboardAction = nil
        dashboard?.setLoading(true)
        dashboard?.setStatus(route == .nextAgent ? "Finding the next agent…" : "Opening \(route.title)…")
        dashboardRequest = backend.send("dashboard_action", fields: ["operation": route.rawValue])
    }

    @objc func returnToDashboard() {
        guard dashboardOrigin, actionRequest == nil, activation == nil, dashboardRequest == nil, !presentingDialog else { return }
        stopPreview()
        swapSource = nil
        targetRoute = nil
        dashboardOrigin = false
        dashboardVisible = true
        content.setDashboardRoute(nil)
        content.search.stringValue = ""
        content.clear.isHidden = true
        content.searchField.selectItem(at: 0)
        scope = "all"
        for button in content.scopes { button.chosen = button.tag == 0 }
        let view = ensureDashboard()
        view.updateSummary(DashboardSummary(counts: dashboardCounts))
        view.setLoading(loading)
        view.setStatus(loading ? "Refreshing your workspace…" : "Choose a tool or press its key")
        presentSurface()
        panel.makeFirstResponder(view)
        query()
    }

    func receive(_ message: [String: Any]) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let id = (message["id"] as? NSNumber)?.intValue ?? -1
        let type = message["type"] as? String ?? ""
        let route = PickerResponseRouting.route(id: id, actionRequest: actionRequest, activation: activation, pending: pending, dashboardRequest: dashboardRequest)
        if route == .dashboardAction {
            dashboardRequest = nil
            dashboard?.setLoading(false)
            guard type == "action_done" else {
                showError(message["message"] as? String ?? "Could not open that tool.")
                return
            }
            if message["close_picker"] as? Bool == true { dismiss(returnToDashboard: false) }
            else { dashboard?.setStatus(message["message"] as? String ?? "No agents need attention.") }
            return
        }
        if route == .action {
            actionRequest = nil
            setActionBusy(false)
            guard type == "action_done" else {
                showError(message["message"] as? String ?? "The action failed. Refresh before retrying.")
                return
            }
            if message["operation"] as? String == "swap" { swapSource = nil }
            if message["close_picker"] as? Bool == true { dismiss(returnToDashboard: false); return }
            if message["operation"] as? String == "preview" {
                presentingDialog = true
                PickerDialogs.preview(on: panel, title: "Terminal preview", text: message["text"] as? String ?? "No terminal output") { [weak self] in self?.endDialog() }
            } else { refresh() }
            return
        }
        if route == .activation {
            self.activation = nil
            if type == "activated" { dismiss(returnToDashboard: false) }
            else { showError(message["message"] as? String ?? "Could not switch to that target.") }
            return
        }
        guard route == .query else { return }
        if type == "error" { showError(message["message"] as? String ?? "Unable to load Rex sessions."); return }
        guard type == "results" else { return }
        let wasLoading = loading
        loading = false
        // A query typed during collection must run against the new snapshot.
        let resultQuery = message["query"] as? String ?? ""
        let resultScope = message["scope"] as? String ?? "all"
        let resultField = message["search_field"] as? String ?? "all"
        let resultAction = message["action_filter"] as? String ?? ""
        if let summary = message["dashboard"] as? [String: Any] {
            dashboardCounts = summary.compactMapValues { ($0 as? NSNumber)?.intValue }
            dashboard?.updateSummary(DashboardSummary(counts: dashboardCounts))
        }
        directoriesLoaded = message["directories_loaded"] as? Bool ?? directoriesLoaded
        directoryBase = message["directories_base"] as? String
        directoryDeep = message["directories_deep"] as? Bool ?? false
        content.setDirectoryLocation(path: directoryBase, deep: directoryDeep)
        if scope == "directory" && !directoriesLoaded { loadDirectories(); return }
        if resultQuery != content.search.stringValue || resultScope != scope || resultField != searchField || resultAction != (targetRoute?.operation ?? "") { query(); return }
        let previous = content.table.selectedRow >= 0 && content.table.selectedRow < items.count ? items[content.table.selectedRow].id : nil
        items = (message["rows"] as? [[String: Any]] ?? []).compactMap(PickerItem.init)
        tree = PickerTreeLayout.positions(for: items)
        displayedRequest = id
        if !dashboardVisible { updateTable() }
        if !dashboardVisible, let first = items.firstIndex(where: { !$0.contextOnly }) {
            let preferred = message["preferred_id"] as? String
            let selected = items.firstIndex(where: { $0.id == previous && !$0.contextOnly })
                ?? items.firstIndex(where: { $0.id == preferred && !$0.contextOnly }) ?? first
            content.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            content.table.scrollRowToVisible(selected)
        }
        let matched = (message["matched"] as? NSNumber)?.intValue ?? items.count
        let total = (message["total"] as? NSNumber)?.intValue ?? items.count
        let shown = (message["shown_matches"] as? NSNumber)?.intValue ?? items.count
        let attention = (message["attention_count"] as? NSNumber)?.intValue ?? 0
        if scope == "all", resultQuery.isEmpty, searchField == "all", resultAction.isEmpty {
            openingItems = items
            openingClientID = context["client_id"]
            openingTotal = matched
        }
        content.scopes[4].title = "Attention \(attention)"
        content.scopes[4].setAccessibilityLabel("Attention, \(attention) agents, Command 5")
        content.scopes[4].needsDisplay = true
        content.count.stringValue = content.search.stringValue.isEmpty ? "\(matched) \(scope == "directory" ? "projects" : "places")" : "\(matched) of \(total)"
        content.status.stringValue = matched > shown ? "Top \(shown) matches · keep typing to narrow" : "\(matched == 1 ? "1 place" : "\(matched) places") · ⌘R refresh"
        content.status.textColor = Palette.secondary
        if scope == "directory" { content.status.stringValue = "↵ open session · ⌘→ browse folder · ⌃F search deeper" }
        if items.contains(where: { $0.kind == "create" }) {
            content.count.stringValue = "New session"
            content.status.stringValue = "↵ create session · keep typing to search"
        }
        if let source = swapSource {
            content.status.stringValue = "Swap \(source.title) → choose destination · esc cancels"
            content.status.textColor = Palette.accent
        } else if let operation = targetRoute?.operation {
            content.status.stringValue = "\(operation.capitalized) · choose a target · esc returns to dashboard"
        }
        if dashboardVisible {
            dashboard?.setLoading(false)
            dashboard?.setStatus("Choose a tool or press its key")
        }
        content.empty.isHidden = !items.isEmpty
        content.emptyTitle.stringValue = scope == "attention" && attention == 0 ? "No agents need attention" : "No matching places"
        content.emptyDetail.stringValue = scope == "attention" ? "Only agents waiting for your approval or input appear here. ⌘R refreshes their status." : scope == "directory" ? "Try Search deeper, browse another folder, or open a folder with ⌘O." : "Try another query or choose All fields."
        let preparedAt = ProcessInfo.processInfo.systemUptime
        // This measures through native layout/display submission, not physical
        // monitor presentation. Never report it as GPU or end-to-end latency.
        let measureDisplay = benchmarkOutput != nil || openBenchmarkOutput != nil || capturePath != nil
        if measureDisplay { panel.contentView?.layoutSubtreeIfNeeded() }
        let laidOutAt = ProcessInfo.processInfo.systemUptime
        if measureDisplay { panel.displayIfNeeded() }
        let displayedAt = ProcessInfo.processInfo.systemUptime
        updatePreviewSelection()
        if wasLoading {
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            FileHandle.standardError.write(Data(String(format: "picker snapshot + native update: %.2f ms\n", elapsed).utf8))
        }
        if let output = openBenchmarkOutput, wasLoading {
            var sample: [String: Any] = ["ready_ms": (displayedAt - startedAt) * 1000,
                                       "surface": dashboardVisible ? "dashboard" : "picker",
                                       "cached_rows": !dashboardVisible && cachedFrameMS != nil]
            if let cachedFrameMS { sample[dashboardVisible ? "dashboard_frame_ms" : "cached_frame_ms"] = cachedFrameMS }
            if let timings = message["open_timing_ms"] { sample["helper_stages"] = timings }
            openBenchmarkSamples.append(sample)
            if openBenchmarkSamples.count == 12 {
                let report: [String: Any] = ["samples": openBenchmarkSamples,
                    "measurement": "native open handler through cached/fresh display submission; excludes hotkey/Launch Services and compositor/GPU presentation"]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: output)) }
                NSApp.terminate(nil)
            } else {
                panel.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    self.open(context: self.context, dashboard: self.dashboardVisible)
                }
            }
            return
        }
        if let path = capturePath {
            capturePath = nil
            if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        if let action = deferredDashboardAction, dashboardVisible { runDashboardAction(action) }
        if benchmarkOutput != nil {
            if benchmarking {
                benchmarkSamples.append((displayedAt - requestedAt) * 1000)
                benchmarkStages.append(["transport_and_match_ms": (receivedAt - requestedAt) * 1000,
                    "prepare_rows_ms": (preparedAt - receivedAt) * 1000,
                    "layout_ms": (laidOutAt - preparedAt) * 1000,
                    "display_ms": (displayedAt - laidOutAt) * 1000,
                    "helper_ms": (message["elapsed_ms"] as? NSNumber)?.doubleValue ?? 0])
            }
            benchmarking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.nextBenchmarkQuery() }
        }
    }

    func nextBenchmarkQuery() {
        guard let output = benchmarkOutput else { return }
        guard benchmarkIndex < benchmarkQueries.count else {
            let measured = Array(benchmarkSamples.dropFirst(12)).sorted()
            let report: [String: Any] = ["samples_ms": benchmarkSamples, "stages": benchmarkStages, "median_ms": measured[measured.count / 2], "p95_ms": measured[min(measured.count - 1, Int(Double(measured.count) * 0.95))], "measurement": "query dispatch through IPC, matching, native layout and display submission; excludes compositor/GPU/monitor presentation", "warmup_queries": 12]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: output)) }
            benchmarkOutput = nil
            NSApp.terminate(nil)
            return
        }
        content.search.stringValue = benchmarkQueries[benchmarkIndex]
        benchmarkIndex += 1
        query()
    }

    func query() {
        guard !loading, activation == nil, actionRequest == nil, dashboardRequest == nil else { return }
        // Results can arrive while AppKit tracks a menu or sheet. Remember a
        // corrective query instead of leaving old rows permanently unselectable.
        if presentingDialog { queryDeferred = true; return }
        queryDeferred = false
        previewGate.noteInput(at: ProcessInfo.processInfo.systemUptime)
        previewGate.select(nil, at: ProcessInfo.processInfo.systemUptime)
        previewWork?.cancel()
        requestedAt = ProcessInfo.processInfo.systemUptime
        pending = backend.send("query", fields: ["query": content.search.stringValue, "scope": scope, "search_field": searchField,
            "action_filter": targetRoute?.operation ?? "", "allow_create": swapSource == nil && targetRoute?.operation == nil])
    }

    func controlTextDidChange(_ notification: Notification) {
        content.clear.isHidden = content.search.stringValue.isEmpty
        previewGate.noteInput(at: ProcessInfo.processInfo.systemUptime)
        previewGate.select(nil, at: ProcessInfo.processInfo.systemUptime)
        previewWork?.cancel()
        if (content.search.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        query()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): accept()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func move(_ delta: Int) {
        guard !items.isEmpty, !loading, actionRequest == nil, activation == nil else { return }
        guard let next = PickerNavigation.nextIndex(current: content.table.selectedRow,
                count: items.count, direction: delta, isSelectable: { !self.items[$0].contextOnly }) else { return }
        content.table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        content.table.scrollRowToVisible(next)
    }

    @objc func clearSearch() {
        guard !loading, actionRequest == nil, activation == nil, !presentingDialog else { return }
        content.search.stringValue = ""
        content.clear.isHidden = true
        panel.makeFirstResponder(content.search)
        query()
    }

    @objc func changeScope(_ sender: NSButton) {
        guard actionRequest == nil, activation == nil, !presentingDialog else { return }
        if targetRoute?.operation != nil && sender.tag == 5 {
            content.status.stringValue = "Choose a live target, or press Escape to return to the dashboard."
            return
        }
        guard swapSource == nil || sender.tag != 5 else {
            content.status.stringValue = "Choose a swap destination, or press Escape to cancel the swap."
            return
        }
        scope = ["all", "session", "window", "pane", "attention", "directory"][sender.tag]
        content.setDirectoryVisible(scope == "directory")
        for button in content.scopes { button.chosen = button.tag == sender.tag }
        panel.makeFirstResponder(content.search)
        if scope == "directory" && !directoriesLoaded { loadDirectories() }
        else { query() }
    }

    @objc func changeSearchField() {
        panel.makeFirstResponder(content.search)
        query()
    }

    func loadDirectories(_ extra: [String: Any] = [:], clearQuery: Bool = false) {
        guard !loading, actionRequest == nil, activation == nil, !presentingDialog, swapSource == nil, targetRoute?.operation == nil else { return }
        stopPreview()
        if clearQuery { content.search.stringValue = ""; content.clear.isHidden = true }
        scope = "directory"
        content.setDirectoryVisible(true)
        for button in content.scopes { button.chosen = button.tag == 5 }
        loading = true
        startedAt = ProcessInfo.processInfo.systemUptime
        content.status.stringValue = extra["deep"] as? Bool == true ? "Searching project directories…" : "Loading project directories…"
        var fields = extra
        fields["query"] = content.search.stringValue
        fields["search_field"] = searchField
        pending = backend.send("directories", fields: fields)
    }

    @objc func browseRecent() { loadDirectories(["reset": true], clearQuery: true) }
    @objc func browseParent() { if directoryBase != nil { loadDirectories(["parent": true], clearQuery: true) } }
    @objc func searchDeeper() { loadDirectories(["deep": true]) }

    func browseSelectedDirectory() {
        guard let selected = selectedItem, selected.kind == "directory" else { return }
        loadDirectories(["base_id": selected.id], clearQuery: true)
    }

    func command(_ key: String) -> Bool {
        guard !presentingDialog else { return false }
        if dashboardVisible {
            if key == "r" { refresh(); return true }
            if key == "w" { dismiss(returnToDashboard: false); return true }
            if key == "q" { NSApp.terminate(nil); return true }
            return false
        }
        if let number = Int(key), (1...6).contains(number) { changeScope(content.scopes[number - 1]); return true }
        if key == "r" {
            refresh()
            return true
        }
        if key == "k" { showActions(); return true }
        if key == "f" { panel.makeFirstResponder(content.search); content.search.selectText(nil); return true }
        let actions = ["e": "rename", "s": "swap", "t": "send", "n": "new-window", "o": "project", "p": "preview"]
        if let operation = actions[key] { performAction(operation); return true }
        if key == "w" { dismiss(returnToDashboard: false); return true }
        if key == "q" { NSApp.terminate(nil); return true }
        return false
    }

    private var selectedItem: PickerItem? {
        let row = content.table.selectedRow
        guard !loading, actionRequest == nil, activation == nil,
              pending == displayedRequest, items.indices.contains(row), !items[row].contextOnly else { return nil }
        return items[row]
    }

    func shortcut(_ event: NSEvent) -> Bool {
        if dashboardVisible { return false }
        guard !presentingDialog,
              (content.search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == [.command, .shift], key == "n" { performAction("create-session"); return true }
        if modifiers == .command, event.keyCode == 51 { performAction("close"); return true }
        if modifiers == .command {
            if event.keyCode == 124, selectedItem?.kind == "directory" { browseSelectedDirectory(); return true }
            if event.keyCode == 123, scope == "directory" { browseParent(); return true }
        }
        if modifiers == .control {
            if key == "n" { move(1); return true }
            if key == "p" { move(-1); return true }
            let actions = ["e": "rename", "x": "close", "z": "zoom", "s": "swap", "t": "send", "o": "project", "/": "preview"]
            if let operation = actions[key] { performAction(operation); return true }
            if key == "g" { showActions(); return true }
            if key == "r" { refresh(); return true }
            if key == "f" { searchDeeper(); return true }
        }
        if modifiers == .option {
            let actions = ["n": "new-window", "v": "split-right", "h": "split-down"]
            if let operation = actions[key] { performAction(operation); return true }
            if event.keyCode == 36 { performAction("create-session"); return true }
        }
        return false
    }

    @objc func showActions() {
        guard !presentingDialog, actionRequest == nil, activation == nil else { return }
        let selected = selectedItem
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ operation: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(chooseAction(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = operation
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if swapSource != nil {
            add("Cancel swap", "cancel-swap")
        } else {
            let heading = NSMenuItem(title: selected.map { String($0.title.prefix(70)) } ?? "Choose a target for editing", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            func can(_ operation: String) -> Bool { selected?.actions.contains(operation) == true }
            add("Rename…", "rename", "e", enabled: can("rename"))
            add("Close…", "close", "\u{7f}", enabled: can("close"))
            add("Zoom pane", "zoom", "z", .control, enabled: can("zoom"))
            add("Swap with…", "swap", "s", enabled: can("swap"))
            add("Send text or key…", "send", "t", enabled: can("send"))
            add(content.previewVisible ? "Hide preview" : "Show preview", "preview", "p")
            menu.addItem(.separator())
            add("New tab…", "new-window", "n", enabled: can("new-window"))
            add("Split right", "split-right", "v", .option, enabled: can("split-right"))
            add("Split down", "split-down", "h", .option, enabled: can("split-down"))
            menu.addItem(.separator())
            add("Open project folder…", "project", "o", enabled: !loading)
            add("Recent projects", "directories", "6", enabled: !loading)
            if scope == "directory" {
                add("Browse selected folder", "browse-directory", enabled: selected?.kind == "directory")
                add("Parent folder", "parent-directory", enabled: directoryBase != nil && !loading)
                add("Search deeper", "deep-directories", "f", .control, enabled: !loading)
            }
            add("Find or create session…", "create-session", "n", [.command, .shift], enabled: !loading)
            add("Agents needing attention", "attention", "5")
            add("Refresh", "refresh", "r")
        }
        presentingDialog = true
        menuChoice = nil
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: content.actions.bounds.height), in: content.actions)
        presentingDialog = false
        if let choice = menuChoice { performAction(choice) }
        else if !panel.isKeyWindow { stopPreview(); panel.orderOut(nil) }
        else { updatePreviewSelection() }
        if queryDeferred && panel.isVisible { query() }
    }

    @objc func chooseAction(_ sender: NSMenuItem) { menuChoice = sender.representedObject as? String }

    func performAction(_ operation: String) {
        guard !presentingDialog, actionRequest == nil, activation == nil else { return }
        if operation == "cancel-swap" { cancelSwap(); return }
        guard swapSource == nil else { showError("Choose a swap destination, or press Escape to cancel the swap."); return }
        if operation == "refresh" { refresh(); return }
        if operation == "preview" { togglePreview(); return }
        if operation == "directories" { changeScope(content.scopes[5]); return }
        if operation == "browse-directory" { browseSelectedDirectory(); return }
        if operation == "parent-directory" { browseParent(); return }
        if operation == "deep-directories" { searchDeeper(); return }
        if operation == "attention" { changeScope(content.scopes[4]); return }
        if operation == "project" {
            guard !loading else { return }
            presentingDialog = true
            PickerDialogs.directory(on: panel) { [weak self] path in
                guard let self else { return }
                self.endDialog()
                if let path { self.sendAction("create-session", extra: ["value": path]) }
            }
            return
        }
        if operation == "create-session" {
            guard !loading else { return }
            presentingDialog = true
            PickerDialogs.prompt(on: panel, title: "Find or create a session", message: "Enter a session name or project directory. Existing project sessions are reused.", value: content.search.stringValue, placeholder: "Session name or /path/to/project", submit: "Open") { [weak self] value in
                guard let self else { return }
                self.endDialog()
                if let value { self.sendAction(operation, extra: ["value": value]) }
            }
            return
        }
        guard let item = selectedItem else { return }
        guard item.actions.contains(operation) else { return }
        let kind = item.kind == "window" ? "tab" : item.kind
        switch operation {
        case "new-window":
            presentingDialog = true
            PickerDialogs.prompt(on: panel, title: "New tab", message: "Enter a tab name or directory. Named tabs start in the selected target’s directory.", value: "", placeholder: "Tab name or /path/to/directory", submit: "Create") { [weak self] value in
                guard let self else { return }
                self.endDialog()
                if let value { self.sendAction(operation, target: item, extra: ["value": value]) }
            }
        case "rename":
            presentingDialog = true
            PickerDialogs.prompt(on: panel, title: "Rename \(kind)", message: item.title, value: item.name, placeholder: "Name", submit: "Rename") { [weak self] value in
                guard let self else { return }
                self.endDialog()
                if let value { self.sendAction(operation, target: item, extra: ["value": value]) }
            }
        case "close":
            presentingDialog = true
            let message = kind == "session" ? "All tabs, panes and running programs in this session will be closed." : kind == "tab" ? "This tab and its running programs will be closed." : "This pane and its running program will be closed."
            PickerDialogs.confirm(on: panel, title: "Close \(kind) “\(item.title)” ?", message: message, submit: "Close \(kind)") { [weak self] confirmed in
                guard let self else { return }
                self.endDialog()
                if confirmed { self.sendAction(operation, target: item, extra: ["confirmed": true]) }
            }
        case "send":
            presentingDialog = true
            let destination = item.combined || item.kind == "pane" ? "this pane" : "all terminal panes in this \(kind)"
            PickerDialogs.prompt(on: panel, title: "Send to \(item.title)", message: "Send literal command text followed by Enter to \(destination), or a single key such as C-c, Escape or F12.", value: "", placeholder: "Command text or key", submit: "Send") { [weak self] value in
                guard let self else { return }
                self.endDialog()
                if let value { self.sendAction(operation, target: item, extra: ["value": value]) }
            }
        case "swap":
            guard item.kind == "window" || item.kind == "pane" else { return }
            swapSource = item
            content.search.stringValue = ""
            content.clear.isHidden = true
            changeScope(content.scopes[item.kind == "window" ? 2 : 3])
        default:
            sendAction(operation, target: item)
        }
    }

    func cancelSwap() {
        swapSource = nil
        content.search.stringValue = ""
        content.clear.isHidden = true
        changeScope(content.scopes[targetRoute?.scope ?? 0])
    }

    func endDialog() {
        presentingDialog = false
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content.search)
        if queryDeferred { query() }
        else { updatePreviewSelection() }
    }

    func setActionBusy(_ busy: Bool) {
        loading = busy
        content.search.isEnabled = !busy
        content.clear.isEnabled = !busy
        content.table.isEnabled = !busy
        content.actions.isEnabled = !busy
        content.searchField.isEnabled = !busy
        content.previewButton.isEnabled = !busy
        content.directoryHome.isEnabled = !busy
        content.directoryUp.isEnabled = !busy && directoryBase != nil
        content.directoryDeep.isEnabled = !busy
        for button in content.scopes { button.isEnabled = !busy }
        if !busy && panel != nil && panel.isVisible && !presentingDialog {
            if dashboardVisible { panel.makeFirstResponder(ensureDashboard()) }
            else { panel.makeFirstResponder(content.search) }
        }
    }

    func sendAction(_ operation: String, target: PickerItem? = nil, extra: [String: Any] = [:]) {
        guard actionRequest == nil, activation == nil, !presentingDialog, !loading else { return }
        stopPreview()
        var fields = extra
        fields["operation"] = operation
        if let target { fields["target_id"] = target.id }
        setActionBusy(true)
        content.status.stringValue = "Working…"
        content.status.textColor = Palette.secondary
        actionRequest = backend.send("action", fields: fields)
    }

    func refresh() {
        guard activation == nil, actionRequest == nil, dashboardRequest == nil, !presentingDialog, !loading else { return }
        stopPreview()
        if scope == "directory", backend.isRunning { loadDirectories(["reload": true]); return }
        loading = true
        startedAt = ProcessInfo.processInfo.systemUptime
        content.status.stringValue = "Refreshing…"
        if dashboardVisible { dashboard?.setLoading(true); dashboard?.setStatus("Refreshing your workspace…") }
        do {
            let running = backend.isRunning
            try backend.start()
            pending = backend.send(running ? "refresh" : "open", fields: running ? [:] : ["context": context])
        } catch { showError(error.localizedDescription) }
    }

    @objc func acceptClickedRow() {
        let row = content.table.clickedRow
        guard items.indices.contains(row), !items[row].contextOnly,
              row == content.table.selectedRow else { return }
        accept()
    }

    @objc func accept() {
        let row = content.table.selectedRow
        guard activation == nil, actionRequest == nil, !presentingDialog, !loading, row >= 0, row < items.count else { return }
        guard !items[row].contextOnly else { return }
        guard (content.search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        // Never activate the previous query's selection while a result is pending.
        guard pending == displayedRequest else { return }
        if let source = swapSource {
            let destination = items[row]
            guard destination.id != source.id, destination.kind == source.kind else {
                showError("Choose a different \(source.kind == "window" ? "tab" : "pane") in the same session.")
                return
            }
            sendAction("swap", target: source, extra: ["destination_id": destination.id])
            return
        }
        if let operation = targetRoute?.operation {
            performAction(operation)
            return
        }
        content.status.stringValue = items[row].kind == "create" ? "Creating session…" : items[row].kind == "directory" ? "Opening project…" : "Switching to \(items[row].title)…"
        stopPreview()
        activation = backend.send("activate", fields: ["target_id": items[row].id])
    }

    @objc func togglePreview() {
        guard !presentingDialog, actionRequest == nil, activation == nil else { return }
        let visible = !content.previewVisible
        stopPreview()
        content.setPreviewVisible(visible)
        if visible { updatePreviewSelection() }
        panel.makeFirstResponder(content.search)
    }

    func stopPreview() {
        previewWork?.cancel()
        previewWork = nil
        previewBackend.stop()
        previewOpening = nil
        previewRequest = nil
        previewReady = false
        previewFailed = false
        previewTargetID = nil
        previewGate.invalidate(cancelInFlight: true)
    }

    func updatePreviewSelection() {
        guard !dashboardVisible, content.previewVisible, panel.isVisible, !presentingDialog else { return }
        guard let selected = selectedItem else {
            previewTargetID = nil
            previewGate.select(nil, at: ProcessInfo.processInfo.systemUptime)
            previewWork?.cancel()
            content.showPreview(title: "Preview", detail: "", text: "Choose a terminal or project to inspect.")
            return
        }
        if selected.kind == "directory" || !selected.actions.contains("preview") {
            previewGate.select(nil, at: ProcessInfo.processInfo.systemUptime)
            previewWork?.cancel()
            content.showPreview(title: selected.title, detail: selected.kindLabel,
                text: [selected.path, selected.detail, selected.subtitle,
                       selected.kind == "directory" ? "Return opens this project’s session.\n⌘→ browses its folders." : selected.kind == "create" ? "Return creates this session using the current search." : "No terminal preview is available for this item."].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            return
        }
        let changed = previewTargetID != selected.id
        previewTargetID = selected.id
        previewGate.select(selected.id, at: ProcessInfo.processInfo.systemUptime)
        guard !previewFailed else { return }
        if changed { content.showPreview(title: selected.title, detail: selected.path, text: "", loading: true) }
        if !previewReady && previewOpening == nil {
            content.showPreview(title: selected.title, detail: selected.path, text: "", loading: true)
            do {
                try previewBackend.start()
                previewOpening = previewBackend.send("open", fields: ["context": context])
            } catch { previewFailure(error.localizedDescription) }
        }
        schedulePreview()
    }

    func schedulePreview() {
        previewWork?.cancel()
        guard previewReady, content.previewVisible, panel.isVisible,
              !loading, actionRequest == nil, activation == nil, !presentingDialog,
              let deadline = previewGate.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.content.previewVisible, self.panel.isVisible,
                  !self.loading, self.actionRequest == nil, self.activation == nil, !self.presentingDialog,
                  let selected = self.selectedItem,
                  let request = self.previewGate.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.content.showPreview(title: selected.title, detail: selected.path, text: "", loading: true)
            let id = self.previewBackend.send("preview", fields: ["target_id": request.targetID, "lines": 80])
            self.previewRequest = (id, request)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    func receivePreview(_ message: [String: Any]) {
        let id = (message["id"] as? NSNumber)?.intValue ?? -1
        let type = message["type"] as? String ?? ""
        if id == previewOpening {
            previewOpening = nil
            guard type == "results" else { previewFailure(message["message"] as? String ?? "Unable to load preview."); return }
            previewReady = true
            schedulePreview()
            return
        }
        guard let pending = previewRequest, pending.id == id else { return }
        previewRequest = nil
        let current = previewGate.finish(pending.request)
        if current, content.previewVisible, panel.isVisible, let selected = selectedItem, selected.id == pending.request.targetID {
            let text = type == "preview" ? (message["text"] as? String ?? "") : (message["message"] as? String ?? "Preview unavailable. Refresh to retry.")
            content.showPreview(title: selected.title, detail: selected.path, text: text.isEmpty ? "No terminal output yet." : text)
        }
        schedulePreview()
    }

    func previewFailure(_ message: String) {
        stopPreview()
        previewFailed = true
        if content.previewVisible, panel.isVisible {
            content.showPreview(title: "Preview unavailable", detail: "Toggle preview or refresh to retry", text: message)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updatePreviewSelection() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private func updateTable() {
        // Preserve AppKit's visible row hierarchy when the result count changes.
        // reloadData tears it down even when most of the rows are unchanged.
        if content.table.numberOfRows != items.count { content.table.noteNumberOfRowsChanged() }
        for index in items.indices {
            (content.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PickerCell)?.configure(items[index], tree: tree[index], separatesGroup: index > 0 && tree[index].depth == 0)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !loading && actionRequest == nil && activation == nil && items.indices.contains(row) && !items[row].contextOnly
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell: PickerCell
        if let existing = cells[row] { cell = existing }
        else {
            cell = PickerCell(frame: .zero)
            cell.identifier = NSUserInterfaceItemIdentifier("place-\(row)")
            cells[row] = cell
        }
        cell.configure(items[row], tree: tree[row], separatesGroup: row > 0 && tree[row].depth == 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }

    func dismiss(returnToDashboard: Bool = true) {
        if activation != nil || actionRequest != nil || dashboardRequest != nil || presentingDialog { return }
        if swapSource != nil { cancelSwap(); return }
        if returnToDashboard && dashboardOrigin { self.returnToDashboard(); return }
        deferredDashboardAction = nil
        stopPreview()
        panel.orderOut(nil)
        // Escape/Cmd+W must return keyboard focus just like accepting a result.
        // Hiding an accessory app's panel alone can leave Rex without focus.
        let target: NSRunningApplication?
        if let app = originApplication, !app.isTerminated,
           app.bundleIdentifier?.hasPrefix("com.superlogical.rex") == true {
            target = app
        } else {
            // Standalone launch has no originating Rex window. The POC is
            // local-only and the helper requires an unambiguous Rex client.
            let rexApps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("com.superlogical.rex") == true && $0.activationPolicy == .regular }
            target = rexApps.count == 1 ? rexApps[0] : nil
        }
        if let target {
            // Use cooperative activation if Launch Services made us active.
            if #available(macOS 14.0, *), NSApp.isActive {
                NSApp.yieldActivation(to: target)
            }
            target.activate(options: [])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app dismisses without stealing focus back from it.
        if !benchmarking && openBenchmarkOutput == nil && activation == nil && actionRequest == nil && dashboardRequest == nil && !presentingDialog {
            deferredDashboardAction = nil
            stopPreview(); panel.orderOut(nil)
        }
    }

    func showError(_ message: String) {
        loading = false
        activation = nil
        actionRequest = nil
        dashboardRequest = nil
        deferredDashboardAction = nil
        setActionBusy(false)
        dashboard?.setLoading(false)
        if dashboardVisible { dashboard?.setStatus(message, isError: true) }
        content.status.stringValue = message
        content.status.toolTip = message
        content.status.textColor = Palette.accent
        if items.isEmpty {
            content.empty.isHidden = false
            content.emptyTitle.stringValue = "Couldn’t connect"
            content.emptyDetail.stringValue = message
        }
        if benchmarkOutput != nil || openBenchmarkOutput != nil {
            FileHandle.standardError.write(Data("Benchmark failed: \(message)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { stopPreview(); backend.stop() }
}

let app = NSApplication.shared
let delegate = PickerApplication()
app.delegate = delegate
app.run()
