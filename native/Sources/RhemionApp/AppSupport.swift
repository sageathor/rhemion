// Shared helpers of the app target: the privacy-safe event label, the delivery-status test, a lock box for
// cross-thread values, and the app log (moved out of main.swift unchanged).

import AppKit
import Foundation
import RhemionIPC
import RhemionStorage

/// A compact, PRIVACY-SAFE label for an event — never the transcript/deliver TEXT (only byte counts),
/// matching the no-content-in-logs rule.
func eventLabel(_ event: Event) -> String {
    switch event {
    case .started(let s): return "started(\(s))"
    case .stopped(let s): return "stopped(\(s))"
    case .transcript(let engine, let ms, let text): return "transcript[\(engine) \(Int(ms))ms \(text.utf8.count)b]"
    case .deliver(let s, let text, _, let pid): return "deliver(\(s) \(text.utf8.count)b pid=\(pid.map(String.init) ?? "-"))"
    case .error(let m): return "error(\(m))"
    case .canceled(let s): return "canceled(\(s))"
    case .journaled(let s): return "journaled(\(s))"
    case .exportCompleted(let months, _, let skipped): return "export-completed(\(months.count) skipped=\(skipped.count))"
    case .historyDeleted(_, let removed, _): return "history-deleted(\(removed.count))"
    case .rerecognized(_, let ok, _): return "rerecognized(ok=\(ok))"
    case .pong: return "pong"
    case .level(let rms): return "level(\(String(format: "%.2f", rms)))"
    case .devices(let models, let mics): return "devices(models=\(models.count) mics=\(mics.count))"
    case .modelDownload(let id, let state, let fraction, _):
        return "model-download(\(id) \(state)\(fraction.map { " \(Int($0 * 100))%" } ?? ""))"
    }
}

/// Delivery statuses that mean the text landed (paste-ambiguous is
/// treated as landed so the indicator doesn't flash an error when the text almost certainly arrived).
func isDeliverySuccess(_ status: String) -> Bool {
    switch status {
    case "inserted-verified", "submitted-unverified", "typed-submitted", "paste-submitted", "paste-ambiguous":
        return true
    default:
        return false
    }
}

/// A tiny lock-guarded value: the delivery closure runs on the socket-read queue and must read the
/// current input method, while the main actor updates it when settings change.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}


/// Where `log()` may write. A real Uninstall that removes app data turns file logging off right before
/// deleting the state folder, so no later line (from any thread) recreates app.log after it is gone.
/// Log hygiene (`LogRotation`, 7 days / 15 MB): enforced at launch, whenever app.log passes its size cap
/// while writing, and at most once a minute from the write path (which also covers runtime.log, written
/// by the runtime through an O_APPEND descriptor — rotated by copy + truncate).
enum AppLog {
    static let fileDisabled = Locked(false)
    /// Mirrors `DataOperations.inProgress`, readable from the hygiene timer's utility queue: while a
    /// storage operation holds the barrier, log hygiene doesn't run — it never races Clear Data's Logs.
    static let hygienePaused = Locked(false)
    static let policy = LogRotation.Policy()
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastEnforced = Date.distantPast

    /// The whole policy on the state folder's diagnostic logs, now. Nothing once file logging is off (a
    /// real Uninstall is removing the state folder) or while a storage operation holds the barrier.
    static func enforceHygiene() {
        guard !fileDisabled.value, !hygienePaused.value else { return }
        lock.lock(); defer { lock.unlock() }
        enforceLocked(now: Date())
    }

    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    /// Every 60 s, off the main thread: runtime.log grows without the app writing a line (the runtime
    /// writes it directly), so its cap can't wait for the next app.log line.
    static func startHygieneTimer() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        t.setEventHandler { enforceHygiene() }
        t.resume()
        timer = t
    }

    private static func enforceLocked(now: Date) {
        guard !hygienePaused.value else { return }   // a storage operation holds the barrier
        lastEnforced = now
        LogRotation.enforce(in: AppPaths.stateDir, policy: policy, copyTruncate: ["runtime.log"], now: now)
    }

    /// Appends one line to app.log (created owner-only), rotating when it's due (`hygiene`). `create: false`
    /// writes only into an app.log that already exists — never creates the state folder or the file: the
    /// open itself has no O_CREAT, so there is no check-then-act window. A failed open is said on
    /// stderr (a missing app.log under `create: false` is the expected case and stays quiet).
    static func append(_ line: String, hygiene: Bool = true, create: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let path = AppPaths.logURL.path
        if create {
            try? FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let fd = create ? open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600) : open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if create || err != ENOENT {
                FileHandle.standardError.write(Data("app.log: couldn't open (\(String(cString: strerror(err))))\n".utf8))
            }
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(Data(line.utf8))
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.close()
        let now = Date()
        if hygiene, size > UInt64(policy.maxFileBytes) || now.timeIntervalSince(lastEnforced) > 60 { enforceLocked(now: now) }
    }
}

func log(_ message: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = stamp + "  " + message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
    guard !AppLog.fileDisabled.value else { return }   // stderr only
    AppLog.append(line)
}
