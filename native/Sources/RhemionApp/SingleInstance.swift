// Single instance — only one Rhemion per bundle id runs at a time. Two would share one state folder,
// socket and runtime (each start kills the other's runtime as an "orphan"), so a second launch — the
// daily app and a dry-run test build alike, they share the bundle id — hands over to the one already
// running and quits before it starts its runtime or touches any state.

import AppKit
import Darwin
import Foundation

enum SingleInstance {
    /// Set by the relaunch helper (`AppEffects.relaunch`: `open -n --env RHEMION_RELAUNCH_AFTER=<old pid>`):
    /// the instance being replaced, never a peer to yield to even if it is still on its way out.
    static let relaunchAfterKey = "RHEMION_RELAUNCH_AFTER"

    struct Instance: Equatable {
        let pid: pid_t
        /// AppKit's launch date; may be nil.
        let launched: Date?
        /// The kernel's process start time (`sysctl KERN_PROC_PID p_starttime`) — the tie-breaker whenever
        /// a launch date is missing.
        var started: Date? = nil
    }

    /// Whether `a` started before `b` — the same answer from either side: launch dates when both have
    /// one and they differ, else kernel start times when both have one and they differ, else the lower pid.
    static func isEarlier(_ a: Instance, _ b: Instance) -> Bool {
        if let la = a.launched, let lb = b.launched, la != lb { return la < lb }
        if let sa = a.started, let sb = b.started, sa != sb { return sa < sb }
        return a.pid < b.pid
    }

    /// The instance this one must yield to: another LIVE instance that started earlier (`isEarlier`), the
    /// earliest such one — never `ignoring` (the instance a relaunch replaces) and never a dead one. nil:
    /// this instance is the one that stays.
    static func yieldTarget(me: Instance, others: [Instance], ignoring: pid_t? = nil,
                            alive: (pid_t) -> Bool = SingleInstance.isAlive) -> Instance? {
        others.filter { $0.pid != me.pid && $0.pid != ignoring && isEarlier($0, me) && alive($0.pid) }
            .min(by: isEarlier)
    }

    /// The process exists (signal 0 reaches it, or exists but isn't ours to signal).
    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// The kernel's start time of a process; nil when it can't be read.
    static func startTime(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private static func instance(_ app: NSRunningApplication) -> Instance {
        Instance(pid: app.processIdentifier, launched: app.launchDate, started: startTime(app.processIdentifier))
    }

    /// The running, not-terminated copies with this bundle id other than this one.
    private static func peers(_ id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { !$0.isTerminated && $0.processIdentifier != getpid() }
    }

    /// Checks for an earlier, live instance with this bundle id; when there is one, brings it forward
    /// (activates it and sends it a reopen, so it opens its hub — `applicationShouldHandleReopen`) and
    /// returns true: the caller then exits. A peer that is gone by a second look (after a short pause) is
    /// no reason to quit. No bundle id (a bare `swift run`): no check.
    static func handOverIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = instance(NSRunningApplication.current)
        let ignoring = ProcessInfo.processInfo.environment[relaunchAfterKey].flatMap { pid_t($0) }
        guard let first = yieldTarget(me: me, others: peers(id).map(instance), ignoring: ignoring) else { return false }
        // Second look: still listed, not terminated and alive — else this instance stays.
        usleep(200_000)
        guard let other = peers(id).first(where: { $0.processIdentifier == first.pid }),
              yieldTarget(me: me, others: [instance(other)], ignoring: ignoring) != nil else {
            note("single instance: pid \(first.pid) went away; this instance (pid \(me.pid)) stays")
            return false
        }
        note("single instance: Rhemion is already running (pid \(other.processIdentifier)); bringing it forward and quitting (pid \(me.pid))")
        other.activate()
        // Opening the RUNNING copy's bundle reactivates it and sends it a reopen (never a second launch).
        if let url = other.bundleURL {
            let done = DispatchSemaphore(value: 0)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { note("single instance: reopen failed: \(error.localizedDescription)") }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
        return true
    }

    /// One log line without log hygiene (no rotation from an instance that is about to quit), and only into
    /// an app.log that already exists — a quitting instance never creates the state folder or the log.
    private static func note(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = stamp + "  " + message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        AppLog.append(line, hygiene: false, create: false)
    }
}
