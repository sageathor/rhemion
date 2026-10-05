// Launch-at-login — thin wrapper over SMAppService.mainApp (macOS 13+; the package targets
// macOS 26, so no availability guard is needed). The saved preference (AppSettings.launchAtLogin,
// key `general_launch_at_login`, default on) is the source of truth; `reconcile` brings the macOS
// login-item registration in line with it.
//
// The app is a normal .app (no launch agent), so login-at-start is the app's own SMAppService
// registration.

import Foundation
import ServiceManagement

enum LoginItem {
    /// Bring the login-item registration in line with `enabled`. Tolerant and non-fatal:
    /// registering when already enabled (or unregistering when not) is skipped, a user who turned us
    /// off in System Settings shows as `.requiresApproval` and we don't fight that, and any thrown
    /// error is logged rather than propagated (the saved preference still reflects the user's intent).
    /// Returns whether the registration now matches the request.
    @discardableResult
    @MainActor
    static func reconcile(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                if enabled { return true }
                try service.unregister()
            case .requiresApproval:
                // The user must resolve this in System Settings › General › Login Items; a
                // register()/unregister() loop here would just churn. Report the mismatch.
                RhemionApp.log("login-item: requires user approval in System Settings (wanted enabled=\(enabled))")
                return false
            default:   // .notRegistered, .notFound, and any future case
                if !enabled { return true }
                try service.register()
            }
            RhemionApp.log("login-item: \(enabled ? "registered" : "unregistered")")
            return true
        } catch {
            // Common in a self-signed dev build run from a scratch path; harmless — the preference is
            // saved and the registration retries on the next launch or toggle.
            RhemionApp.log("login-item reconcile failed (enabled=\(enabled)): \(error)")
            return false
        }
    }
}
