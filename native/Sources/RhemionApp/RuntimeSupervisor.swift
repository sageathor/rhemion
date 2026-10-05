// RuntimeSupervisor — owns the app's OWN rhemion-runtime instance, isolated from any other
// install. It spawns the runtime bundled at Contents/Helpers with the app's state/data env, drains
// its pipes, restarts it with backoff if it dies, kills a runtime orphaned by a previous app crash,
// and terminates it when the app quits.

import Foundation
import Darwin
import RhemionStorage

@MainActor
final class RuntimeSupervisor {
    private let helperURL: URL
    private let childEnv: [String: String]

    private var process: Process?
    private var stopping = false
    private var spawnedAt = Date.distantPast
    private var backoff: TimeInterval = 0.5
    private let minBackoff: TimeInterval = 0.5
    private let maxBackoff: TimeInterval = 10
    private let stableRunSeconds: TimeInterval = 10   // a run longer than this resets the backoff
    private var pendingRestart: DispatchWorkItem?

    init() {
        helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rhemion-runtime")
        let stateDir = AppPaths.stateDir.path
        let tmpDir = Self.resolveTemporaryDirectory()
        childEnv = [
            "RHEMION_RUNTIME_DIR": stateDir,          // isolated socket + state (NOT the earlier versions' ~/.local/state/rhemion)
            "RHEMION_DATA_DIR": AppPaths.dataDir.path, // recordings + history in the app's Application Support folder
            "RHEMION_TMP_DIR": tmpDir,                 // Rhemion's own temp folder for whisper intermediates (not the shared $TMPDIR)
        ]
    }

    /// Rhemion's own subfolder under the resolved system temp dir. Uses `AppPaths.resolvedTemporaryDirectory()`
    /// (shared with `AppPaths.storageLayout`) so the folder the runtime writes to via RHEMION_TMP_DIR is
    /// exactly the folder the Temporary storage category later deletes.
    private static func resolveTemporaryDirectory() -> String {
        AppPaths.resolvedTemporaryDirectory().appendingPathComponent("com.sageathor.rhemion.app").path
    }

    /// Socket the spawned runtime listens on — the client connects here.
    var socketPath: String { AppPaths.stateDir.appendingPathComponent("runtime.sock").path }

    func start() {
        stopping = false          // a start after a stop must work again
        killOrphans()
        spawn()
    }

    func stop() {                 // app termination: fire-and-forget is fine here
        stopping = true
        pendingRestart?.cancel(); pendingRestart = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// Stop the runtime and WAIT until it and its children (whisper-cli) have really exited: SIGTERM,
    /// 5 s, then SIGKILL, 2 s. Returns false if something survived — destructive operations must then
    /// abort, and the caller must NOT start a second runtime.
    func stopAndWait() async -> Bool {
        stopping = true
        pendingRestart?.cancel(); pendingRestart = nil
        guard let process, process.isRunning else { self.process = nil; return true }
        let pid = process.processIdentifier
        let pids = [pid] + ProcessWaiter.children(of: pid)
        process.terminate(); pids.dropFirst().forEach { kill($0, SIGTERM) }
        if await ProcessWaiter.waitForExit(pids, timeout: 5) { self.process = nil; return true }
        pids.forEach { kill($0, SIGKILL) }
        let ok = await ProcessWaiter.waitForExit(pids, timeout: 2)
        if ok { self.process = nil }
        log("supervisor: stopAndWait -> \(ok ? "stopped" : "STUCK")")
        return ok
    }

    /// Restart the runtime so a fresh process re-discovers, registers and prewarms models on disk — used
    /// after a model download, since registration happens only at startup. Terminating WITHOUT setting
    /// `stopping` lets the normal exit path (`handleExit` → `scheduleRestart`) respawn it; if nothing is
    /// running, spawn directly.
    func restart() {
        guard !stopping else { return }
        if let process, process.isRunning { process.terminate() } else { spawn() }
    }

    // MARK: - internals

    private func spawn() {
        guard !stopping else { return }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            log("supervisor: runtime helper missing/not executable at \(helperURL.path)")
            return
        }
        let process = Process()
        process.executableURL = helperURL
        var env = ProcessInfo.processInfo.environment
        for (key, value) in childEnv { env[key] = value }
        process.environment = env

        // Send the runtime's stdout+stderr to an isolated runtime.log. A real file sink also avoids any pipe-full stall without a drain loop.
        if let logHandle = runtimeLogHandle() {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleExit(finished) }
        }

        do {
            try process.run()
            self.process = process
            spawnedAt = Date()
            log("supervisor: runtime started (pid \(process.processIdentifier)), dir=\(childEnv["RHEMION_RUNTIME_DIR"] ?? "?")")
        } catch {
            log("supervisor: failed to start runtime: \(error)")
            scheduleRestart()
        }
    }

    private func handleExit(_ finished: Process) {
        // Only the CURRENT runtime's exit counts. A stale exit (a process stopAndWait already reaped and
        // cleared, after which resume() spawned a new one) must neither clear the new process — that
        // would orphan it — nor schedule a restart, which would spawn a second runtime.
        guard finished === process else { return }
        process = nil
        if stopping { return }
        // A run that stayed up past the stable threshold is a healthy session that later exited, not a
        // crash loop — reset the backoff so a one-off exit restarts promptly.
        if Date().timeIntervalSince(spawnedAt) >= stableRunSeconds { backoff = minBackoff }
        log("supervisor: runtime exited (status \(finished.terminationStatus)); restart in \(backoff)s")
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping, self.process == nil else { return }
            self.spawn()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// An append handle to the isolated runtime.log (owner-only), used as the child's stdout+stderr.
    /// Opened O_APPEND, so log hygiene can rotate it by copy + truncate while the runtime runs (every
    /// write lands at the current end, never past a truncation). Hygiene runs first.
    private func runtimeLogHandle() -> FileHandle? {
        let url = AppPaths.stateDir.appendingPathComponent("runtime.log")
        try? FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        AppLog.enforceHygiene()
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Kill a runtime left running by a previous app instance that crashed without terminating it.
    /// Only our bundled runtime runs from `Contents/Helpers/rhemion-runtime`, so matching that path is
    /// specific and cannot hit any other runtime install.
    private func killOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "Contents/Helpers/rhemion-runtime"]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
