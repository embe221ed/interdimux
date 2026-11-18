import AppKit
import Carbon

/// The resident picker and its helper commands use Rex's host/session objects
/// and Show command. Address the originating application by PID and birth time.
enum RemoteSessionAutomation {
    typealias Descriptor = NSAppleEventDescriptor
    typealias Send = (AEEventClass, AEEventID, Descriptor) throws -> Descriptor?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    // Four-character terms from Rex.sdef, independent of the user's language.
    static let hostClass: DescType = 0x52784873       // RxHs
    static let sessionClass: DescType = 0x5278536e    // RxSn
    static let connected: AEKeyword = 0x5278436f     // RxCo
    static let remote: AEKeyword = 0x5278526d        // RxRm
    static let hostName: AEKeyword = 0x5278484e      // RxHN
    static let suite: AEEventClass = 0x52657853      // RexS
    static let showCommand: AEEventID = 0x53686f77   // Show
    static let missing = "The session is no longer available in this Rex app. Refresh the picker."
    private static let changed = "The Rex host changed. Refresh the picker before switching."
    struct NeedsRemoteCheck: Error {}

    // Rex's version-one saved hosts map each scripting ID to the server
    // identity last observed on its connection. Treat the format as optional.
    private struct HostRegistry: Decodable {
        struct Record: Decodable {
            let id: String
            let name: String
            let lastHostID: String?
        }
        let formatVersion: Int
        let records: [Record]
    }

    private static func savedHosts() -> Data? {
        let domain = "com.superlogical.rex" as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return nil }
        return CFPreferencesCopyValue("RexSync.servers" as CFString, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data
    }

    private struct HostIdentities {
        let byName: [String: [HostRegistry.Record]]
        let byID: [UUID: [HostRegistry.Record]]

        init(_ data: Data?) throws {
            guard let data, data.count <= 1024 * 1024,
                  let registry = try? JSONDecoder().decode(HostRegistry.self, from: data),
                  registry.formatVersion == 1 else { throw NeedsRemoteCheck() }
            byName = Dictionary(grouping: registry.records) { $0.name.folding(options: .caseInsensitive, locale: nil) }
            var ids: [UUID: [HostRegistry.Record]] = [:]
            for record in registry.records {
                if let id = UUID(uuidString: record.id) { ids[id, default: []].append(record) }
            }
            byID = ids
        }

        func physicalID(_ host: String, _ scriptingID: String) throws -> UUID {
            guard let id = UUID(uuidString: scriptingID) else { throw NeedsRemoteCheck() }
            let names = byName[host.folding(options: .caseInsensitive, locale: nil)] ?? []
            let ids = byID[id] ?? []
            // A host provided by another configuration source can lack a saved
            // record. An existing conflicting record is evidence of a changed route.
            guard !names.isEmpty || !ids.isEmpty else { throw NeedsRemoteCheck() }
            guard names.count == 1, ids.count == 1, let record = ids.first, record.name == host
            else { throw Failure(changed) }
            guard let id = record.lastHostID, let physical = UUID(uuidString: id) else { throw NeedsRemoteCheck() }
            return physical
        }
    }

    static func verifyHost(_ host: String, scriptingID: String, physicalID: String, registry: Data?) throws {
        guard let expected = UUID(uuidString: physicalID) else { throw NeedsRemoteCheck() }
        let found = try HostIdentities(registry).physicalID(host, scriptingID)
        guard found == expected else { throw Failure(changed) }
    }

    private static func reference(_ kind: DescType, _ form: DescType, _ selection: Descriptor,
                                  in container: Descriptor = .null()) throws -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(Descriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selection, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let spec = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw Failure("Could not construct a Rex scripting reference.")
        }
        return spec
    }

    private static func properties(_ object: Descriptor, send: Send) throws -> Descriptor? {
        let all = try reference(DescType(cProperty), DescType(formPropertyID),
                                Descriptor(typeCode: DescType(pProperties)), in: object)
        return try send(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), all)
    }

    private static func records(_ kind: DescType, send: Send) throws -> [Descriptor] {
        var ordinal = OSType(kAEAll)
        guard let every = Descriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &ordinal,
                                     length: MemoryLayout.size(ofValue: ordinal)) else { throw Failure(missing) }
        let spec = try reference(kind, DescType(formAbsolutePosition), every)
        guard let list = try properties(spec, send: send), list.descriptorType == DescType(typeAEList)
        else { throw Failure(missing) }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
    }

    static func catalog(permitted: Bool, registry: @autoclosure () -> Data?, send: Send) throws -> [[String: Any]] {
        guard permitted else { return [] }
        let saved = try HostIdentities(registry())
        let live = try records(hostClass, send: send)
        let names = Dictionary(grouping: live) {
            $0.forKeyword(AEKeyword(pName))?.stringValue?.folding(options: .caseInsensitive, locale: nil)
        }
        let ids = Dictionary(grouping: live) { $0.forKeyword(AEKeyword(pID))?.stringValue?.lowercased() }
        var hosts: [String: (name: String, physical: UUID)] = [:]
        for group in names.values where group.count == 1 {
            let record = group[0]
            guard record.forKeyword(connected)?.booleanValue == true,
                  let name = record.forKeyword(AEKeyword(pName))?.stringValue, !name.isEmpty,
                  let id = record.forKeyword(AEKeyword(pID))?.stringValue, ids[id.lowercased()]?.count == 1,
                  let physical = try? saved.physicalID(name, id) else { continue }
            hosts[id] = (name, physical)
        }
        guard !hosts.isEmpty else { return [] }
        var sessions: [String: [[String: String]]] = [:]
        var seen = Set<String>()
        var ambiguous = Set<String>()
        for row in try records(sessionClass, send: send) {
            guard row.forKeyword(remote)?.booleanValue == true,
                  let id = row.forKeyword(AEKeyword(pID))?.stringValue,
                  let slash = id.firstIndex(of: "/") else { continue }
            let key = String(id[..<slash])
            let session = String(id[id.index(after: slash)...])
            guard let host = hosts[key], row.forKeyword(hostName)?.stringValue == host.name,
                  session.hasPrefix("session:"), UUID(uuidString: String(session.dropFirst(8))) != nil,
                  let label = row.forKeyword(AEKeyword(pName))?.stringValue else { continue }
            if seen.insert(id).inserted {
                sessions[key, default: []].append(["session_id": session, "label": label])
            } else { ambiguous.insert(key) }
        }
        return hosts.compactMap { key, host in
            guard !ambiguous.contains(key) else { return nil }
            return ["label": host.name, "host_id": host.physical.uuidString.lowercased(),
                    "sessions": sessions[key] ?? []]
        }
    }

    static func show(host: String, sessionID: String, verifyIdentity: ((String) throws -> Void)? = nil,
                     send: Send) throws {
        let matching = try records(hostClass, send: send).filter {
            $0.forKeyword(AEKeyword(pName))?.stringValue?.caseInsensitiveCompare(host) == .orderedSame
        }
        guard matching.count == 1, matching[0].forKeyword(AEKeyword(pName))?.stringValue == host,
              matching[0].forKeyword(connected)?.booleanValue == true,
              let hostID = matching[0].forKeyword(AEKeyword(pID))?.stringValue, !hostID.isEmpty else {
            throw Failure("Connect this Rex app to the selected host, then refresh the picker.")
        }
        let id = hostID + "/" + sessionID
        let session = try reference(sessionClass, DescType(formUniqueID), Descriptor(string: id))
        guard let details = try properties(session, send: send), details.forKeyword(AEKeyword(pID))?.stringValue == id,
              details.forKeyword(remote)?.booleanValue == true,
              details.forKeyword(hostName)?.stringValue == host else { throw Failure(missing) }
        try verifyIdentity?(hostID)
        _ = try send(suite, showCommand, session)
    }

    static func eventFailure(_ code: Int, detail: String?) -> Failure {
        switch code {
        case Int(errAEEventNotPermitted):
            return Failure("Allow Automation access to Rex in System Settings → Privacy & Security → Automation.")
        case Int(errAENoSuchObject): return Failure(missing)
        case Int(errAEEventNotHandled):
            return Failure("Update Rex for Mac to a version with AppleScript session support.")
        case Int(procNotFound), Int(connectionInvalid):
            return Failure("The original Rex app closed. Reopen the picker from Rex.")
        case Int(errAETimeout):
            return Failure("Rex timed out showing the session. Refresh the picker and try again.")
        default: return Failure(detail ?? "Rex automation failed (\(code)).")
        }
    }

    private static let closed = "The original Rex app closed. Reopen the picker from Rex."
    private static func matchesBirth(_ pid: pid_t, _ birth: String) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid) else { return false }
        return birth == "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    // Called off the main thread by the resident picker. The Rust helper grants
    // one reveal for this origin process, physical host and exact session.
    static func reveal(_ request: [String: Any]) -> [String: Any] {
        guard let pid = request["pid"] as? pid_t, pid > 0,
              let birth = request["birth"] as? String, let host = request["host"] as? String,
              let session = request["session_id"] as? String, let physicalID = request["host_id"] as? String
        else { return ["error": "Invalid remote activation request."] }
        return perform(pid: pid, host: host, session: session, physicalID: physicalID, birth: birth)
    }

    private static func sender(to target: Descriptor, pid: pid_t, birth: String, deadline: TimeInterval) -> Send {
        { suite, command, object in
            guard matchesBirth(pid, birth) else { throw Failure(closed) }
            let event = Descriptor(eventClass: suite, eventID: command, targetDescriptor: target,
                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
            let reply: Descriptor
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw eventFailure(Int(errAETimeout), detail: nil) }
            do { reply = try event.sendEvent(options: .waitForReply, timeout: min(8, remaining)) }
            catch let error as NSError { throw eventFailure(error.code, detail: error.localizedDescription) }
            if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
                throw eventFailure(Int(code), detail: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
            }
            return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        }
    }

    private static func perform(pid: pid_t, host: String, session: String, physicalID: String?,
                                birth: String) -> [String: Any] {
        do {
            guard pid > 0, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.superlogical.rex",
                  matchesBirth(pid, birth) else { throw Failure(closed) }
            let target = Descriptor(processIdentifier: pid)
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            let verify = physicalID.map { expected in
                { (scriptingID: String) in
                    try verifyHost(host, scriptingID: scriptingID, physicalID: expected, registry: savedHosts())
                }
            }
            try show(host: host, sessionID: session, verifyIdentity: verify,
                     send: sender(to: target, pid: pid, birth: birth, deadline: deadline))
            return ["shown": true]
        } catch is NeedsRemoteCheck { return ["needs_remote_check": true] }
        catch { return ["error": error.localizedDescription] }
    }

    static func run(_ arguments: [String]) {
        let result: [String: Any]
        if (4...5).contains(arguments.count), let pid = pid_t(arguments[0]) {
            result = perform(pid: pid, host: arguments[2], session: arguments[3],
                             physicalID: arguments.count == 5 ? arguments[4] : nil, birth: arguments[1])
        } else { result = ["error": closed] }
        write(result)
    }

    // The resident picker and the command-line fallback inspect the same
    // verified Rex process. A denied Automation permission yields no candidates.
    static func readCatalog(_ request: [String: Any]) -> [[String: Any]] {
        guard let pid = request["pid"] as? pid_t, pid > 0, let birth = request["birth"] as? String,
              matchesBirth(pid, birth),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.superlogical.rex"
        else { return [] }
        let target = Descriptor(processIdentifier: pid)
        let permitted = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                              AEEventID(kAEGetData), false) == noErr
        let send = sender(to: target, pid: pid, birth: birth, deadline: ProcessInfo.processInfo.systemUptime + 2)
        return (try? catalog(permitted: permitted, registry: savedHosts(), send: send)) ?? []
    }

    static func boundedCatalog(_ hosts: [[String: Any]], token: UInt64) -> [[String: Any]] {
        // Budget the complete JSON-lines frame, including the largest request
        // ID and trailing newline. Keep incomplete inventories out of the picker.
        let frame: [String: Any] = ["type": "native_catalog", "id": Int.max, "token": token, "catalog": hosts]
        guard let bytes = try? JSONSerialization.data(withJSONObject: frame), bytes.count < 64 * 1024 else { return [] }
        return hosts
    }

    static func readCatalogInBackground(_ request: [String: Any], completion: @escaping ([[String: Any]]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hosts = boundedCatalog(readCatalog(request), token: request["token"] as? UInt64 ?? 0)
            DispatchQueue.main.async { completion(hosts) }
        }
    }

    static func runCatalog(_ arguments: [String]) {
        guard arguments.count == 2, let pid = pid_t(arguments[0]) else { write(["hosts": []]); return }
        write(["hosts": readCatalog(["pid": pid, "birth": arguments[1]])])
    }

    private static func write(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result) { FileHandle.standardOutput.write(data) }
    }
}
