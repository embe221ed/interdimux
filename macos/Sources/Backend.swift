import AppKit
import Darwin

/// Cancellation is shared with the writer queue; app lifecycle state stays on
/// the main queue. Closing is queued after writes, so a recycled descriptor can
/// never receive an old connection's bytes.
private final class PickerInput {
    let handle: FileHandle
    // An unresponsive old child must never block writes to its replacement.
    let writes = DispatchQueue(label: "dev.interdimux.picker.input")
    private let lock = NSLock()
    private var active = true

    init(_ handle: FileHandle) { self.handle = handle }
    func cancel() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

struct PickerItem: Equatable {
    let id: String
    let kind: String
    let title: String
    let name: String
    let subtitle: String
    let path: String
    let host: String?
    let hostID: String?
    let sessionID: String?
    let windowID: String?
    let blockID: String?
    let stale: Bool
    var current: Bool
    let parentID: String?
    let contextOnly: Bool
    let combined: Bool
    let paneID: String?
    let detail: String
    let agentState: String?
    let attention: Bool
    // Only the selected row queries this tiny list; allocating a hash table
    // for every search result costs more than its occasional linear lookup.
    let actions: [String]

    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let kind = value["kind"] as? String else { return nil }
        self.id = id
        self.kind = kind
        title = value["title"] as? String ?? "Untitled"
        name = value["name"] as? String ?? title
        subtitle = value["subtitle"] as? String ?? ""
        path = value["path"] as? String ?? ""
        host = value["host"] as? String
        hostID = value["host_id"] as? String
        sessionID = value["session_id"] as? String
        windowID = value["window_id"] as? String
        blockID = value["block_id"] as? String
        stale = value["stale"] as? Bool ?? false
        current = value["current"] as? Bool ?? false
        parentID = value["parent_id"] as? String
        contextOnly = value["context_only"] as? Bool ?? false
        combined = value["combined"] as? Bool ?? false
        paneID = value["pane_id"] as? String
        detail = value["detail"] as? String ?? ""
        agentState = value["agent_state"] as? String
        attention = value["attention"] as? Bool ?? false
        actions = value["actions"] as? [String] ?? []
    }

    var symbol: String {
        switch kind {
        case "session": return "square.stack.3d.up"
        case "window": return "macwindow"
        case "directory": return "folder"
        case "create": return "plus.circle"
        default: return "terminal"
        }
    }
    var kindLabel: String {
        switch kind {
        case "session": return "Session"
        case "window": return "Tab"
        case "pane": return "Pane"
        case "directory": return current ? "Open" : "Project"
        case "create": return "Create"
        default: return kind.capitalized
        }
    }

    // Keep editable pane names visible alongside the terminal's conversation title.
    var rowTitle: String { kind == "pane" && !name.isEmpty ? name : title }

    var hostLabel: String? {
        guard let host else { return nil }
        let label = subtitle.isEmpty ? host : subtitle
        return stale ? label + " (cached)" : label
    }
}

/// One local process for the lifetime of the app. Only tiny query messages cross
/// the pipe while typing; Rex collection and matching never run on the main queue.
final class PickerBackend {
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: PickerInput?
    private var serial = 0
    private(set) var connection = 0
    private let executable: URL
    var isRunning: Bool { process?.isRunning == true }

    init(executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/imux")) {
        self.executable = executable
    }

    private func fail(_ message: String, connection expected: Int) {
        // Always report asynchronously: callers assign the returned request ID
        // before handling a failure, including when the helper is already gone.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection == expected else { return }
            self.stop()
            self.onFailure?(message)
        }
    }

    func start() throws {
        if process?.isRunning == true { return }
        stop()
        let connection = self.connection
        let child = Process()
        child.executableURL = executable
        child.arguments = ["macos-serve"]
        if let index = CommandLine.arguments.firstIndex(of: "--fixture"), index + 1 < CommandLine.arguments.count {
            child.arguments! += ["--fixture", CommandLine.arguments[index + 1]]
        }
        var environment = ProcessInfo.processInfo.environment
        for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT", "REX_SERVER"] { environment.removeValue(forKey: key) }
        child.environment = environment
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        // Darwin supports this per-descriptor flag for pipes. A closed reader
        // then makes write throw EPIPE instead of terminating the entire app.
        guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.terminationHandler = { [weak self] _ in
            self?.fail("The search helper stopped. Press ⌘R to reconnect.", connection: connection)
        }
        try child.run()
        process = child
        input = PickerInput(stdinPipe.fileHandleForWriting)
        let output = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? output.close() }
            var buffer = Data()
            var searchedUntil = 0
            // On Darwin read(upToCount:) can wait until the requested length
            // or EOF. A resident helper never closes stdout between replies.
            // availableData waits for the next bytes, then returns immediately.
            while true {
                let part = output.availableData
                if part.isEmpty { break }
                buffer.append(part)
                // Pipes may fragment a metadata-rich response into many
                // reads. Search each byte once rather than rescanning the
                // entire incomplete JSON line on every read (quadratic work).
                while let newline = buffer.dropFirst(searchedUntil).firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    guard line.count <= 8 * 1024 * 1024,
                          let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        self?.fail("The search helper sent an invalid response. Press ⌘R to reconnect.", connection: connection)
                        return
                    }
                    buffer.removeSubrange(...newline)
                    searchedUntil = 0
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.connection == connection else { return }
                        self.onMessage?(message)
                    }
                }
                searchedUntil = buffer.count
                if buffer.count > 8 * 1024 * 1024 {
                    self?.fail("The search helper sent an oversized response. Press ⌘R to reconnect.", connection: connection)
                    return
                }
            }
            self?.fail("The search helper stopped responding. Press ⌘R to reconnect.", connection: connection)
        }
        // Drain stderr independently so diagnostics can never fill a child pipe.
        let errors = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let part = errors.availableData
                if part.isEmpty { break }
                FileHandle.standardError.write(part)
            }
            try? errors.close()
        }
    }

    @discardableResult
    func send(_ type: String, fields: [String: Any] = [:]) -> Int {
        serial += 1
        let id = serial
        let connection = self.connection
        func reject(_ reason: String) {
            // Match helper validation responses, including request routing and
            // asynchronous ID assignment, while leaving a healthy pipe open.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection == connection else { return }
                self.onMessage?(["id": id, "type": "error", "message": reason])
            }
        }
        if let query = fields["query"] as? String, query.utf8.count > 4096 {
            reject("Query exceeds 4096 UTF-8 bytes. Shorten the search text.")
            return id
        }
        if let value = fields["value"] as? String, value.utf8.count > 32 * 1024 {
            reject("Action text exceeds 32 KiB. Shorten the text and try again.")
            return id
        }
        var message = fields
        message["type"] = type
        message["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: message), let input else {
            fail("Unable to reach the search helper. Press ⌘R to reconnect.", connection: connection)
            return id
        }
        data.append(10)
        // JSON escaping can expand a valid action value past the helper's
        // frame limit. The limit includes the envelope and final newline.
        guard data.count <= 64 * 1024 else {
            reject("Request exceeds 64 KiB after encoding. Shorten the text and try again.")
            return id
        }
        input.writes.async { [weak self] in
            guard input.isActive else { return }
            do { try input.handle.write(contentsOf: data) }
            catch {
                input.cancel()
                self?.fail("Unable to reach the search helper. Press ⌘R to reconnect.", connection: connection)
            }
        }
        return id
    }

    func stop() {
        connection += 1
        let child = process
        process = nil
        if let input {
            input.cancel()
            input.writes.async { try? input.handle.close() }
        }
        input = nil
        if child?.isRunning == true { child?.terminate() }
    }
}
