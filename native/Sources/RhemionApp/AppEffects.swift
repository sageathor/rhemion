// AppEffects — the real SystemEffects used by Clear Data / Uninstall outside a
// dry run: unregisters the login item, resets TCC (Accessibility + Microphone), moves the .app to the
// Trash, clears the saved-defaults domain, and relaunches after the old process exits. File removal
// itself is inherited from RealFileEffects (SafeRemover); this class only adds the non-file effects.
//
// Every one of these is destructive or user-visible, so DryRunEffects (RHEMION_UNINSTALL_DRYRUN=1,
// see AppPaths.makeEffects) exists to log what WOULD happen instead — exercised by the uninstall UI's
// preview and by tests, never by shipping this class in place of it.

import AppKit
import Foundation
import RhemionStorage
import ServiceManagement

final class AppEffects: RealFileEffects, @unchecked Sendable {
    struct EffectError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Unlike `LoginItem.reconcile` (the day-to-day toggle, which is tolerant of `.requiresApproval`
    /// and swallows errors so a saved preference survives), uninstall must actually try to remove the
    /// registration in every case except "already gone" — including `.requiresApproval` — and must
    /// propagate a failure so the caller can surface it.
    override func unregisterLoginItem() async throws {
        let service = SMAppService.mainApp
        guard service.status != .notRegistered && service.status != .notFound else { return }
        try await service.unregister()      // any other status, including .requiresApproval
    }

    override func resetPrivacy() async throws {
        for service in ["Accessibility", "Microphone"] {
            let status = try await Self.runToExit("/usr/bin/tccutil", ["reset", service, "com.sageathor.rhemion.app"])
            guard status == 0 else { throw EffectError(message: "tccutil reset \(service) failed (\(status))") }
        }
        // The bundled helper records audio, and macOS lists it under Microphone as its own entry
        // ("rhemion-runtime"). Best effort: tccutil exits non-zero when it has no entry, which is fine.
        _ = try? await Self.runToExit("/usr/bin/tccutil", ["reset", "Microphone", "com.sageathor.rhemion.runtime"])
    }

    /// Runs a tool and suspends until it exits — `waitUntilExit()` would block a cooperative-pool
    /// thread for the tool's whole lifetime. The handler is set before `run()` so a fast exit can't be missed.
    private static func runToExit(_ tool: String, _ args: [String]) async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            p.terminationHandler = { finished in cont.resume(returning: finished.terminationStatus) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    override func moveAppToTrash(_ app: URL) async throws {
        _ = try await NSWorkspace.shared.recycle([app])
        guard !FileManager.default.fileExists(atPath: app.path) else {
            throw EffectError(message: "Rhemion.app is still at \(app.path)")
        }
    }

    override func removeDefaults(domain: String) {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }

    /// Waits (up to 10s, in a detached `/bin/sh`, NOT on our own thread — we don't outlive our own
    /// exit) for `afterPID` to exit, then relaunches `app`. If the old process is still alive after the
    /// cap, gives up without launching a second instance on top of a hung one. The new instance gets
    /// RHEMION_RELAUNCH_AFTER=<old pid>, so its single-instance check never yields to the one it replaces.
    override func relaunch(app: URL, afterPID: pid_t) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "pid=\"$1\"; app=\"$2\"; i=0; while kill -0 \"$pid\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; [ $i -lt 100 ] || exit 1; exec /usr/bin/open -n --env \"RHEMION_RELAUNCH_AFTER=$pid\" \"$app\"",
            "rhemion-relaunch", String(afterPID), app.path]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()      // not waited: it outlives us and starts the new instance after we exit
    }
}
