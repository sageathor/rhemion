// ProcessWaiter — small process-tree helpers used by RuntimeSupervisor.stopAndWait() to make
// "stop" mean something concrete: list a process's direct children (e.g. the runtime's whisper-cli),
// and wait until a set of pids has actually exited instead of firing a signal and hoping.

import Darwin
import Foundation

public enum ProcessWaiter {
    /// Direct children of `pid` (via /usr/bin/pgrep -P), e.g. the runtime's whisper-cli.
    public static func children(of pid: pid_t) -> [pid_t] {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-P", String(pid)]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    /// True once every pid is gone (kill(pid, 0) fails with ESRCH) within `timeout`.
    public static func waitForExit(_ pids: [pid_t], timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy(hasExited) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return pids.allSatisfy(hasExited)
    }

    /// A pid has exited once `kill(pid, 0)` fails with ESRCH (errno read immediately after the call).
    /// A pid that is our own direct child and has exited but not yet been reaped is technically a
    /// zombie — `kill(pid, 0)` still succeeds for it — but we deliberately do NOT reap here (e.g. via
    /// `waitpid`): the runtime pid is a Foundation `Process` with its own `terminationHandler`, and
    /// racing a `waitpid` against Foundation's own reap of that same child can steal the exit status
    /// out from under it and starve its termination notification. Reaping stays the owner's job
    /// (Foundation `Process`); this only observes.
    private static func hasExited(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }
}
