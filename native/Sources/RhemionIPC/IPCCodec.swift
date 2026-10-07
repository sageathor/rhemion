import Foundation

public enum IPCCodec {
    public static func encode(_ event: Event) throws -> String {
        let obj: String
        switch event {
        case .started(let s): obj = #"{"event":"started","session":\#(jsonString(s))}"#
        case .stopped(let s): obj = #"{"event":"stopped","session":\#(jsonString(s))}"#
        case .transcript(let engine, let ms, let text):
            obj = #"{"event":"transcript","engine":\#(jsonString(engine)),"ms":\#(jsonNumber(ms)),"text":\#(jsonString(text))}"#
        case .deliver(let session, let text, let original, let targetPid):
            // Build the optional tail (`original`, `target_pid`) so each key is present only when
            // it has a value -- mirrors the wire-back-compatible "omit nil keys" rule the client
            // and the codec tests rely on.
            var tail = ""
            if let original { tail += #","original":\#(jsonString(original))"# }
            if let targetPid { tail += #","target_pid":\#(targetPid)"# }
            obj = #"{"event":"deliver","session":\#(jsonString(session)),"text":\#(jsonString(text))\#(tail)}"#
        case .error(let m):   obj = #"{"event":"error","message":\#(jsonString(m))}"#
        case .canceled(let s): obj = #"{"event":"canceled","session":\#(jsonString(s))}"#
        case .historyDeleted(let ids, let removedIDs, let error):
            let tail = error.map { #","error":\#(jsonString($0))"# } ?? ""
            obj = #"{"event":"history-deleted","ids":\#(jsonStrings(ids)),"removed_ids":\#(jsonStrings(removedIDs))\#(tail)}"#
        case .exportCompleted(let months, let error, let skipped):
            var tail = error.map { #","error":\#(jsonString($0))"# } ?? ""
            if !skipped.isEmpty { tail += #","skipped":\#(jsonStrings(skipped))"# }
            obj = #"{"event":"export-completed","months":\#(jsonStrings(months))\#(tail)}"#
        case .pong:           obj = #"{"event":"pong"}"#
        case .level(let rms): obj = #"{"event":"level","rms":\#(jsonNumber(rms))}"#
        case .modelDownload(let id, let state, let fraction, let error):
            var tail = ""
            if let fraction { tail += #","fraction":\#(jsonNumber(fraction))"# }
            if let error { tail += #","error":\#(jsonString(error))"# }
            obj = #"{"event":"model-download","id":\#(jsonString(id)),"state":\#(jsonString(state))\#(tail)}"#
        case .devices(let models, let mics):
            let m = jsonArray(models.map { ["id": $0.id, "label": $0.label, "engine": $0.engine, "found": $0.found, "warm": $0.warm, "damaged": $0.damaged] })
            let d = jsonArray(mics.map { ["uid": $0.uid, "name": $0.name, "built_in": $0.builtIn] })
            obj = #"{"event":"devices","models":\#(m),"mics":\#(d)}"#
        }
        return obj + "\n"
    }

    /// Client (app) direction: encode a `Command` to the wire form the runtime's `decodeCommands`
    /// parses. `ts` and `target_pid` are omitted when nil (the runtime treats absence as nil), so the
    /// output stays wire-compatible with the minimal `{"cmd":"start"}`.
    public static func encode(_ command: Command) throws -> String {
        let obj: String
        switch command {
        case .start(let pressedAt, let targetPid):
            var tail = ""
            if let pressedAt { tail += #","ts":\#(jsonNumber(pressedAt))"# }
            if let targetPid { tail += #","target_pid":\#(targetPid)"# }
            obj = #"{"cmd":"start"\#(tail)}"#
        case .stop: obj = #"{"cmd":"stop"}"#
        case .cancel: obj = #"{"cmd":"cancel"}"#
        case .historyDelete(let ids):
            obj = #"{"cmd":"history-delete","ids":\#(jsonStrings(ids))}"#
        case .exportNow: obj = #"{"cmd":"export-now"}"#
        case .ping: obj = #"{"cmd":"ping"}"#
        case .downloadModel(let id):
            obj = #"{"cmd":"download-model","id":\#(jsonString(id))}"#
        case .cancelModelDownload: obj = #"{"cmd":"cancel-model-download"}"#
        case .listDevices: obj = #"{"cmd":"list-devices"}"#
        case .deliverResult(let session, let status):
            obj = #"{"cmd":"deliver-result","session":\#(jsonString(session)),"status":\#(jsonString(status))}"#
        }
        return obj + "\n"
    }

    public static func decodeCommands(from buffer: inout Data) -> [Command] {
        var commands: [Command] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                let cmd = obj["cmd"] as? String
            else { continue }
            switch cmd {
            case "start":
                commands.append(.start(pressedAt: numericTimestamp(obj["ts"]),
                                       targetPid: integerValue(obj["target_pid"])))
            case "stop":  commands.append(.stop)
            case "cancel": commands.append(.cancel)
            case "history-delete":
                if let ids = obj["ids"] as? [String] { commands.append(.historyDelete(ids: ids)) }
            case "export-now": commands.append(.exportNow)
            case "ping":  commands.append(.ping)
            case "download-model":
                if let id = obj["id"] as? String { commands.append(.downloadModel(id: id)) }
            case "cancel-model-download": commands.append(.cancelModelDownload)
            case "list-devices": commands.append(.listDevices)
            case "deliver-result":
                // Ignore a malformed result rather than fabricate one: an absent/empty session or
                // status carries no truth about a delivery, so drop it (the runtime's timeout still
                // finalizes the history row).
                if let session = obj["session"] as? String, !session.isEmpty,
                   let status = obj["status"] as? String, !status.isEmpty {
                    commands.append(.deliverResult(session: session, status: status))
                }
            default:      continue
            }
        }
        return commands
    }

    /// Client (app) direction: decode newline-delimited `Event` lines the runtime emits (the inverse
    /// of `encode(Event)`). Malformed or unknown lines are skipped. `deliver`'s `original` and
    /// `target_pid` are optional (absent -> nil), matching the encoder's omit-nil-keys rule.
    public static func decodeEvents(from buffer: inout Data) -> [Event] {
        var events: [Event] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                let event = obj["event"] as? String
            else { continue }
            switch event {
            case "started":
                if let s = obj["session"] as? String { events.append(.started(session: s)) }
            case "stopped":
                if let s = obj["session"] as? String { events.append(.stopped(session: s)) }
            case "transcript":
                if let engine = obj["engine"] as? String, let text = obj["text"] as? String {
                    events.append(.transcript(engine: engine, ms: doubleValue(obj["ms"]) ?? 0, text: text))
                }
            case "deliver":
                if let s = obj["session"] as? String, let text = obj["text"] as? String {
                    events.append(.deliver(session: s, text: text,
                                           original: obj["original"] as? String,
                                           targetPid: integerValue(obj["target_pid"])))
                }
            case "canceled":
                if let s = obj["session"] as? String { events.append(.canceled(session: s)) }
            case "error":
                if let m = obj["message"] as? String { events.append(.error(message: m)) }
            case "history-deleted":
                if let ids = obj["ids"] as? [String], let removed = obj["removed_ids"] as? [String],
                   obj["error"] == nil || obj["error"] is String {
                    events.append(.historyDeleted(ids: ids, removedIDs: removed, error: obj["error"] as? String))
                }
            case "export-completed":
                if let months = obj["months"] as? [String], obj["error"] == nil || obj["error"] is String,
                   obj["skipped"] == nil || obj["skipped"] is [String] {
                    events.append(.exportCompleted(months: months, error: obj["error"] as? String,
                                                   skipped: obj["skipped"] as? [String] ?? []))
                }
            case "pong":
                events.append(.pong)
            case "level":
                if let rms = doubleValue(obj["rms"]) { events.append(.level(rms: rms)) }
            case "model-download":
                if let id = obj["id"] as? String, let state = obj["state"] as? String {
                    events.append(.modelDownload(id: id, state: state,
                                                 fraction: doubleValue(obj["fraction"]),
                                                 error: obj["error"] as? String))
                }
            case "devices":
                let models = (obj["models"] as? [[String: Any]] ?? []).compactMap { m -> ModelOption? in
                    guard let id = m["id"] as? String, let label = m["label"] as? String,
                          let engine = m["engine"] as? String, let found = m["found"] as? Bool else { return nil }
                    return ModelOption(id: id, label: label, engine: engine, found: found, warm: m["warm"] as? Bool ?? true,
                                       damaged: m["damaged"] as? Bool ?? false)
                }
                let mics = (obj["mics"] as? [[String: Any]] ?? []).compactMap { d -> MicOption? in
                    guard let uid = d["uid"] as? String, let name = d["name"] as? String,
                          let builtIn = d["built_in"] as? Bool else { return nil }
                    return MicOption(uid: uid, name: name, builtIn: builtIn)
                }
                events.append(.devices(models: models, mics: mics))
            default:
                continue
            }
        }
        return events
    }

    /// A JSON number as Double (rejecting CFBoolean, which bridges to NSNumber), or nil.
    private static func doubleValue(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }

    /// A JSON number `ts` as a Double, or nil for any non-numeric value. JSONSerialization
    /// bridges JSON booleans to NSNumber too, and `as? Double` would turn true/false into
    /// 1.0/0.0 — so reject CFBoolean explicitly (the spec requires non-numeric ts -> nil).
    private static func numericTimestamp(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }

    /// A JSON integer (a pid) as Int, or nil for any non-integer value. Rejects CFBoolean (which
    /// bridges to NSNumber) for the same reason as `numericTimestamp`, and rejects non-integral
    /// numbers so a stray float can never be truncated into a bogus pid.
    private static func integerValue(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        guard n.doubleValue == n.doubleValue.rounded() else { return nil }
        return n.intValue
    }

    /// Renders a Double as a bare JSON number. Non-finite values (NaN/infinity) cannot appear
    /// in JSON, so they fall back to 0 rather than emit invalid output.
    private static func jsonNumber(_ d: Double) -> String {
        d.isFinite ? String(d) : "0"
    }

    private static func jsonStrings(_ values: [String]) -> String {
        "[" + values.map(jsonString).joined(separator: ",") + "]"
    }

    /// Serialize an array of flat JSON objects (the `devices` payload). Bools bridge to JSON
    /// true/false and strings are escaped by JSONSerialization; a failure yields an empty array.
    private static func jsonArray(_ objects: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        // ["x"] -> ["x"]; take the slice between the outer brackets
        if let data, var str = String(data: data, encoding: .utf8) {
            str.removeFirst(); str.removeLast()   // drop the [ and ]
            return str
        }
        return "\"\""
    }
}
