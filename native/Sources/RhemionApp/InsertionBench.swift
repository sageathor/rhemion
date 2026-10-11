// Developer-only insertion bench (deploy/insertion-bench). Off unless `<stateDir>/bench/enabled` exists at
// launch; nothing in the product reaches it. The bench driver writes `bench/request.json`, posts the Darwin
// notification below, and waits for `bench/result-<id>.json`. The insertion runs through the real code
// (ClipboardPaste, AXInsert, or a separate Delivery for the production routing) into whatever is focused.

import AppKit
import notify
import Foundation

@MainActor
final class InsertionBench {
    static let notification = "com.sageathor.rhemion.bench.insert"

    private struct Request: Decodable {
        let id: String
        let text: String
        let route: String          // "paste" | "ax" | "auto"
        let settleMS: Int?         // paste only; nil = production default
        let frontApp: String       // the browser running the page: nothing is inserted anywhere else
        let phase: String?         // "press": take a target snapshot only; otherwise insert (and match it)
    }

    private struct Result: Encodable {
        let id: String
        let route: String
        let status: String
        let ms: Double
        var target: String? = nil  // the target match at insert time, when a press snapshot was taken
    }

    private let dir: URL
    private var token: Int32 = 0
    private let delivery = Delivery()
    /// Plays the notch indicator through a take ending in an outcome ("inserted" | "kept" | "failed"),
    /// waiting `waitMS` after the release; wired in main.swift. No dictation, no insertion.
    var demo: ((_ outcome: String, _ waitMS: Int) -> Void)?
    /// Pin flows (wired in main.swift): "pin" toggles the pin on the window in front; "pin-return" delivers
    /// `text` to the pinned window and comes back, replying with the status and the app in front afterwards.
    var pinAction: ((_ route: String, _ text: String, _ reply: @escaping @Sendable (String) -> Void) -> Void)?
    private var pressed: TargetSnapshot?
    private var pressedForRefocus: TargetSnapshot?

    /// Starts listening when the bench is enabled; nil otherwise.
    static func startIfEnabled() -> InsertionBench? {
        let dir = AppPaths.stateDir.appendingPathComponent("bench")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("enabled").path) else { return nil }
        let bench = InsertionBench(dir: dir)
        bench.listen()
        log("bench: enabled (\(dir.path))")
        return bench
    }

    /// Press-time snapshots of the "guarded" route, by session: its deliveries pass the production target rule
    /// (`allows(matchNow())`) at delivery and again right before ⌘V, as a dictation does.
    private let guards = Locked<[String: TargetSnapshot]>([:])

    private init(dir: URL) {
        self.dir = dir
        let guards = self.guards
        let check: @Sendable (String) -> Bool = { session in
            guard let snap = guards.value[session] else { return true }
            return snap.allows(snap.matchNow().match)
        }
        delivery.targetCheck = check
        delivery.targetRecheck = check
    }

    private func listen() {
        notify_register_dispatch(Self.notification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle() }
        }
    }

    private func handle() {
        let url = dir.appendingPathComponent("request.json")
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            log("bench: unreadable request")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front.map { Int($0.processIdentifier) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        if request.route == "pin" || request.route.hasPrefix("pin-return") {
            let rid = request.id, route = request.route
            let t0 = DispatchTime.now().uptimeNanoseconds
            pinAction?(route, request.text) { [dir] status in
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if let data = try? JSONEncoder().encode(Result(id: rid, route: route, status: status, ms: ms)) {
                    try? data.write(to: dir.appendingPathComponent("result-\(rid).json"), options: .atomic)
                }
            }
            return
        }
        if request.route.hasPrefix("indicator-") {   // before the front-app guard: nothing is inserted
            demo?(String(request.route.dropFirst("indicator-".count)), request.settleMS ?? 2500)
            let out = Result(id: request.id, route: request.route, status: "demo", ms: 0)
            if let data = try? JSONEncoder().encode(out) { try? data.write(to: dir.appendingPathComponent("result-\(request.id).json"), options: .atomic) }
            return
        }
        var target: String?
        var pressSnap: TargetSnapshot?
        if request.phase == "press" {
            pressed = pid.map(TargetSnapshot.capture)
            pressedForRefocus = pressed
        } else if let snap = pressed {
            pressed = nil
            pressSnap = snap
            let (match, detail) = snap.matchNow()
            target = "\(match.rawValue) \(detail)"
        }
        let reply: @Sendable (String) -> Void = { [dir, target] status in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let result = Result(id: request.id, route: request.route, status: status, ms: ms, target: target)
            if let out = try? JSONEncoder().encode(result) {
                try? out.write(to: dir.appendingPathComponent("result-\(request.id).json"), options: .atomic)
            }
        }
        // Someone switched apps mid-run: never type bench text into their window.
        guard front?.localizedName == request.frontApp else { reply("skipped-not-front"); return }
        if request.phase == "press" { reply("pressed"); return }
        if request.route.hasPrefix("refocus"), let snap = pressedForRefocus {
            // Insert again's mechanism: optionally lose the app (Finder in front), then bring the field back.
            pressedForRefocus = nil
            let away = request.route == "refocus-app"
            if away, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                TargetSnapshot.bringToFront(finder)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            }
            let r0 = DispatchTime.now().uptimeNanoseconds
            let (match, detail) = snap.restoreFocus()
            let restoreMS = (DispatchTime.now().uptimeNanoseconds - r0) / 1_000_000
            guard match == .sameElement || match == .sameField else { reply("refocus-failed \(match.rawValue) \(detail)"); return }
            ClipboardPaste.paste(request.text, targetPid: snap.pid) { status in reply("\(status) refocus=\(match.rawValue)_\(restoreMS)ms") }
            return
        }
        switch request.route {
        case "paste":
            let verifier = PasteVerifier.before()
            let length = request.text.utf16.count
            ClipboardPaste.paste(request.text, targetPid: pid, settleMS: request.settleMS ?? 0) { status in
                let token = ClipboardPaste.lastPostedToken.value
                DispatchQueue.global().async {
                    let outcome = verifier?.after(inserted: length) ?? .unreadable
                    if case .landed = outcome, let token { ClipboardPaste.restoreNow(token: token) }   // as Delivery does
                    reply("\(status) verify=\(outcome.label.replacingOccurrences(of: " ", with: "_"))")
                }
            }
        case "ax":
            reply("\(AXInsert.insert(request.text, targetPid: pid))")
        case "guarded":   // a dictation's path: the press snapshot is checked at delivery and before ⌘V
            let session = "bench-\(request.id)"
            if let pressSnap { guards.value = { var m = guards.value; m[session] = pressSnap; return m }() }
            let guards = self.guards
            delivery.onDeliver(
                text: request.text, original: nil, session: session, targetPid: pid,
                inputMethod: "direct", sendAck: { _, _ in },
                onResult: { status in
                    guards.value = { var m = guards.value; m[session] = nil; return m }()
                    reply(status)
                }
            )
        case "burst":   // two dictations handed to delivery back to back: both land, in order, once
            let statuses = Locked<[String]>([])
            for (i, text) in [request.text, "[2] " + request.text].enumerated() {
                delivery.onDeliver(
                    text: text, original: nil, session: "bench-\(request.id)-\(i)", targetPid: pid,
                    inputMethod: "direct", sendAck: { _, _ in },
                    onResult: { status in
                        statuses.value = statuses.value + [status]
                        if statuses.value.count == 2 { reply(statuses.value.joined(separator: "+")) }
                    }
                )
            }
        default:
            delivery.onDeliver(
                text: request.text, original: nil, session: "bench-\(request.id)", targetPid: pid,
                inputMethod: "direct", sendAck: { _, _ in }, onResult: { status in reply(status) }
            )
        }
    }
}
