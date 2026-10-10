// AppController's developer-only insertion bench wiring (deploy/insertion-bench; off unless enabled): the pin
// scenarios and the indicator demo (moved out of applicationDidFinishLaunching unchanged).

import AppKit
import Foundation

extension AppController {
    func startBench(indicator: NotchIndicator) {
        bench = InsertionBench.startIfEnabled()
        bench?.pinAction = { [weak self] route, text, reply in
            guard let self else { return }
            if route == "pin" { self.pin.toggle(); reply(self.pin.isPinned ? "pinned" : "unpinned"); return }
            if route == "pin-return-away", let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                TargetSnapshot.bringToFront(finder)   // the user works in another app meanwhile
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                log("bench: front now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            }
            let pinnedPid = self.pin.target?.pid
            self.deliverToPinned(text: text, original: nil, session: "bench-pin-\(UUID().uuidString)", ack: { _, _ in }) { status in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    // Bench only: give the browser running the page the front back for the next case.
                    if route == "pin-return-away", let pid = pinnedPid, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                        MainActor.assumeIsolated { TargetSnapshot.bringToFront(app) }
                    }
                    reply("\(status) front=\(front)")
                }
            }
        }
        bench?.demo = { [weak indicator] outcome, waitMS in
            guard let indicator else { return }
            indicator.recording(journalOnly: outcome == "journaled")
            let t0 = Date()
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                let t = Date().timeIntervalSince(t0)
                MainActor.assumeIsolated { indicator.onLevel(0.25 + 0.55 * abs(sin(t * 6.1) * sin(t * 2.3 + 1))) }
                if t >= 1.3 { timer.invalidate() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
                indicator.processing()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(waitMS)) {
                    switch outcome {
                    case "kept": indicator.kept(); case "failed": indicator.failed(); case "journaled": indicator.journaled()
                    default: indicator.done()
                    }
                }
            }
        }
    }
}
