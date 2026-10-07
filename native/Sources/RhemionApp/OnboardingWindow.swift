// Welcome & Setup — the one-time first-run screen. It focuses on the two make-or-break
// permissions (Accessibility for the push-to-talk key + text insertion; Microphone for capture), shows
// their live status with buttons that jump to the right System Settings pane, and a short "how to
// dictate" explainer with the current push-to-talk key. Shown once on first launch (tracked by a
// UserDefaults flag) and re-openable any time from the menu bar ("Welcome…").

import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Owns the single Welcome window and the "already shown" flag. `current` reads the live settings (for the
/// push-to-talk key); the app is an accessory, so showing the window flips the Dock icon on while it's up.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let permissions = PermissionsModel()
    private let current: () -> AppSettings
    private let setPTTKey: (String) -> Void
    private let setLaunchAtLogin: (Bool) -> Void
    private let modelDownload: ModelDownloadModel
    private let logoClock = WelcomeLogoClock()
    private static let shownKey = "rhemion.v3.welcomeShown"

    init(current: @escaping () -> AppSettings, setPTTKey: @escaping (String) -> Void,
         setLaunchAtLogin: @escaping (Bool) -> Void, modelDownload: ModelDownloadModel,
         onMicrophoneGranted: @escaping () -> Void = {}) {
        self.current = current; self.setPTTKey = setPTTKey; self.setLaunchAtLogin = setLaunchAtLogin
        self.modelDownload = modelDownload; super.init()
        permissions.onMicrophoneGranted = onMicrophoneGranted
    }

    /// Whether the first-run Welcome has already been shown once.
    static var hasBeenShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }

    /// Whether the Welcome window is on screen right now (it is kept, not released, after closing).
    var isShowing: Bool { window?.isVisible == true }

    /// Bring an open Welcome forward without replaying its logo intro (a Dock-icon click).
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Show the Welcome window. On launch call `showIfNeeded()`; the menu item calls this directly.
    func show() {
        if window == nil {
            let root = OnboardingView(permissions: permissions,
                                      modelDownload: modelDownload,
                                      logoClock: logoClock,
                                      initialPTTKey: current().pttKeys.first ?? "right_option",
                                      initialLaunchAtLogin: current().launchAtLogin,
                                      setPTTKey: setPTTKey,
                                      setLaunchAtLogin: setLaunchAtLogin,
                                      onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            // Size the window to the content's own fitting size (the view sets a fixed 800pt width), so the
            // Welcome shows in full without a scroll bar.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Rhemion"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        logoClock.restart()   // the logo intro plays each time the window opens
        permissions.startPolling()
        AppController.shared?.setDockIconVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible { centerOnScreen(window) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Place the window in the true middle of the screen the user is on (the one under the pointer — where
    /// they just clicked the menu bar item). The size is settled first: with .preferredContentSize the
    /// SwiftUI content sizes the window only on layout, so centering before that used a stale size. (Plain
    /// NSWindow.center() also sits deliberately above the middle.)
    private func centerOnScreen(_ window: NSWindow) {
        if let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let fit = view.fittingSize
            if fit.width > 0, fit.height > 0 { window.setContentSize(fit) }
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            window.center(); return
        }
        let area = screen.visibleFrame, size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: (area.midY - size.height / 2).rounded()))
    }

    /// Called once on launch: show the Welcome on first run, and again whenever a permission Rhemion needs
    /// is missing (nothing else asks for them; the hotkey and the runtime only wait).
    var needsShowing: Bool { !Self.hasBeenShown || !PermissionsModel.allGranted }
    func showIfNeeded() { if needsShowing { show() } }

    func windowDidBecomeKey(_ notification: Notification) { permissions.refresh() }
    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
        AppController.shared?.setDockIconVisible(false)
    }
}

/// Live permission state, polled on a 1s timer while the Welcome window is open so a grant made in System
/// Settings flips the row without the user re-opening anything.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// Called once when microphone access flips to granted (the app restarts its runtime, which skipped the
    /// microphone until now).
    var onMicrophoneGranted: () -> Void = {}
    private var timer: Timer?

    /// Both permissions Rhemion needs are granted (reading the status never prompts).
    static var allGranted: Bool {
        AXIsProcessTrusted() && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic && !microphone { onMicrophoneGranted() }
        microphone = mic
    }

    /// Accessibility: surface the system prompt AND open the Accessibility pane (the prompt alone is easy
    /// to miss, and once denied it won't reappear — the pane is where the toggle lives).
    func fixAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    /// Microphone: if the app has never asked, show the standard prompt; otherwise (granted/denied) send
    /// the user to the Microphone pane to change it.
    func fixMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        } else {
            openSettings("Privacy_Microphone")
        }
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The Welcome content: a header, a permissions card (Accessibility + Microphone with live status), a
/// "how to dictate" card, and a primary "Get started" button. Styled to the shared design system.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var modelDownload: ModelDownloadModel
    @ObservedObject var logoClock: WelcomeLogoClock
    let setPTTKey: (String) -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let onDone: () -> Void
    /// The dictation key, seeded from the current setting and updated as the user picks Fn / Right Command.
    @State private var pttKey: String
    /// Launch-at-login, seeded from the current setting; the toggle writes it live (persist + reconcile).
    @State private var launchAtLogin: Bool
    @Environment(\.colorScheme) private var scheme

    init(permissions: PermissionsModel, modelDownload: ModelDownloadModel, logoClock: WelcomeLogoClock, initialPTTKey: String,
         initialLaunchAtLogin: Bool, setPTTKey: @escaping (String) -> Void,
         setLaunchAtLogin: @escaping (Bool) -> Void, onDone: @escaping () -> Void) {
        self.permissions = permissions
        self.modelDownload = modelDownload
        self.logoClock = logoClock
        self.setPTTKey = setPTTKey
        self.setLaunchAtLogin = setLaunchAtLogin
        self.onDone = onDone
        _pttKey = State(initialValue: initialPTTKey)
        _launchAtLogin = State(initialValue: initialLaunchAtLogin)
    }

    private var dark: Bool { scheme == .dark }

    /// Everything the Welcome asks for is in place — the logo answers with an extra echo when this turns on.
    private var setupComplete: Bool { permissions.accessibility && permissions.microphone && modelDownload.isReady }

    var body: some View {
        // Layout C a recessed side column carries the animated logo,
        // the title, the pitch and the launch-at-login checkbox; the main column holds the setup, the
        // dictation key and the action. No ScrollView — the window sizes itself to this content (see the
        // controller's .preferredContentSize). The main column sets the window's height and the side column
        // is laid over it at that height — so the side can never push empty space under the action row.
        mainColumn
            .padding(.leading, Self.sideWidth)
            .overlay(alignment: .leading) { sideColumn.frame(width: Self.sideWidth).frame(maxHeight: .infinity) }
            .frame(width: 800)
        .background(RhemionStyle.content(dark))
        .foregroundStyle(RhemionStyle.text(dark))
        .onChange(of: setupComplete) { _, done in if done { logoClock.pulse() } }
    }

    private static let sideWidth: CGFloat = 250

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeLogo(clock: logoClock, size: 128).padding(.leading, -6).padding(.bottom, 6)
            Text("Welcome to Rhemion").font(RhemionStyle.font(22, .heavy))
            // One heading, one paragraph: the slogan opens it in the text colour, the explanation follows in grey.
            (Text("Thought, uninterrupted. ").font(RhemionStyle.font(13, .semibold)).foregroundColor(RhemionStyle.text(dark))
             + Text("Hold a key and speak. Your Mac does the typing.").font(RhemionStyle.font(13)).foregroundColor(RhemionStyle.secondary(dark)))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Text("Reopen this any time: menu bar › Welcome.")
                .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 34, leading: 26, bottom: 22, trailing: 26))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RhemionStyle.rail(dark))
        .overlay(alignment: .trailing) { Rectangle().fill(RhemionStyle.line(dark)).frame(width: 1) }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionsCard
            dictateCard
            // Adaptive primary CTA: Welcome offers the nearest useful action rather than promising a
            // readiness that isn't there yet. No model → Download; downloading →
            // Continue in background; ready but permissions missing → Continue setup; all set → Get started.
            // Launch-at-login sits beside the action (installer idiom: tick, then continue), one line.
            HStack(spacing: 10) {
                launchCheckbox
                Spacer(minLength: 8)
                primaryArea
            }
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 22, trailing: 28))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The state-driven primary action (see the comment at the call site).
    @ViewBuilder private var primaryArea: some View {
        switch modelDownload.phase {
        case .missing:
            skipLink
            primaryButton("Download model · ~\(modelDownload.approxSizeMB) MB") { modelDownload.onDownload() }
        case .failed:
            skipLink
            primaryButton("Retry download · ~\(modelDownload.approxSizeMB) MB") { modelDownload.onDownload() }
        case .downloading, .preparing, .checking:
            primaryButton("Continue in background") { onDone() }
        case .ready:
            if permissions.accessibility && permissions.microphone {
                primaryButton("Get started") { onDone() }
            } else {
                primaryButton("Continue setup") { continueSetup() }
            }
        }
    }

    /// Primary tier (DESIGN.md → F2 "Selection Gold"): the one warm button per screen — the exact selection
    /// color (#F6DD84 / gold 20%) + a thin gold hairline + dark-amber ink (cream on dark). Not a saturated slab.
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(RhemionStyle.font(13, .semibold))
                .foregroundStyle(dark ? Color(rhemionHex: 0xE8D9A8) : Color(rhemionHex: 0x5A4410))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(RhemionStyle.selected(dark), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RhemionStyle.gold.opacity(dark ? 0.42 : 0.35), lineWidth: 1) }
                .shadow(color: .black.opacity(dark ? 0.20 : 0.05), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// Quiet tier (DESIGN.md): plain text link, no fill — lets the user proceed without the model now.
    private var skipLink: some View {
        Button(action: onDone) {
            Text("Skip for now").font(RhemionStyle.font(12, .medium))
                .foregroundStyle(RhemionStyle.secondary(dark))
                .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// "Continue setup" jumps to the first missing permission rather than closing on a half-done setup.
    private func continueSetup() {
        if !permissions.accessibility { permissions.fixAccessibility() }
        else if !permissions.microphone { permissions.fixMicrophone() }
    }

    /// Launch-at-login, surfaced on Welcome (default on, but visible — we ask, we don't silently register).
    /// A checkbox beside the action button, styled like the Journal selection checkbox: gold fill + white check.
    private var launchCheckbox: some View {
        Button { launchAtLogin.toggle(); setLaunchAtLogin(launchAtLogin) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5).fill(launchAtLogin ? RhemionStyle.gold : .clear)
                    RoundedRectangle(cornerRadius: 3.5)
                        .strokeBorder(launchAtLogin ? RhemionStyle.gold : (dark ? Color.white.opacity(0.28) : Color.black.opacity(0.24)), lineWidth: 1)
                    if launchAtLogin {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                Text("Start Rhemion at login").font(RhemionStyle.font(12.5, .semibold)).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ready in the menu bar after a restart.")
        .accessibilityLabel("Start Rhemion at login")
        .accessibilityValue(launchAtLogin ? "On" : "Off")
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Setup")
            permissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Your push-to-talk key, and typing text into other apps.",
                granted: permissions.accessibility,
                action: { permissions.fixAccessibility() })
            Divider().overlay(RhemionStyle.line(dark))
            permissionRow(
                icon: "mic",
                title: "Microphone",
                detail: "Hears your dictation. Audio is transcribed locally.",
                granted: permissions.microphone,
                action: { permissions.fixMicrophone() })
            Divider().overlay(RhemionStyle.line(dark))
            speechModelRow
        }
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private var speechModelRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "brain").font(.system(size: 15, weight: .medium))
                .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Speech model").font(RhemionStyle.font(13, .semibold))
                    modelStatusPill
                }
                Text("The on-device recognition engine, ~\(modelDownload.approxSizeMB) MB, downloaded once. Works offline; audio never leaves your Mac.")
                    .font(RhemionStyle.font(12)).lineSpacing(2)
                    .foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                // The inline control shows progress / preparing / retry — but NOT the first Download button:
                // when the model is simply missing, the adaptive primary CTA is the single Download affordance.
                if case .missing = modelDownload.phase {
                    EmptyView()
                } else if !modelDownload.isReady {
                    SpeechModelStatus(model: modelDownload)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var modelStatusPill: some View {
        let ready = modelDownload.isReady
        return HStack(spacing: 4) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").font(.system(size: 10, weight: .semibold))
            Text(ready ? "Ready — On-device" : "Required for dictation").font(RhemionStyle.font(10, .semibold))
        }
        .foregroundStyle(ready ? Color(rhemionHex: 0x2E9E5B) : RhemionStyle.tertiary(dark))
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
                .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(RhemionStyle.font(13, .semibold))
                    statusPill(granted: granted)
                }
                Text(detail).font(RhemionStyle.font(12)).lineSpacing(2)
                    .foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(action: action) {
                    Text("Open Settings").font(RhemionStyle.font(12, .medium))
                        .foregroundStyle(RhemionStyle.text(dark))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                }
                .buttonStyle(.plain).fixedSize()
            }
        }
        .padding(16)
    }

    private func statusPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(granted ? Color(rhemionHex: 0x2E9E5B) : RhemionStyle.tertiary(dark))
            Text(granted ? "Granted" : "Not granted")
                .font(RhemionStyle.font(10, .semibold))
                .foregroundStyle(granted ? Color(rhemionHex: 0x2E9E5B) : RhemionStyle.tertiary(dark))
        }
    }

    /// The two dictation keys we offer on first run: Fn (what Whisper Flow users expect) and Right Command
    /// (the app default). The rest of the keys live in Settings.
    private let keyChoices: [(id: String, label: String)] = [("fn", "Fn (Globe)"), ("right_cmd", "Right Command")]

    private var dictateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation key").font(RhemionStyle.font(13, .semibold))
                    Text("Hold to dictate, release to insert.")
                        .font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                }
                Spacer(minLength: 8)
                keyChooser.frame(width: 250)
            }
            if !keyChoices.contains(where: { $0.id == pttKey }) {
                Text("Currently using \(Self.pttLabel(pttKey)). Pick one to change it; add more keys in Settings › General.")
                    .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
    }

    private var keyChooser: some View {
        HStack(spacing: 2) {
            ForEach(keyChoices, id: \.id) { choice in
                let on = pttKey == choice.id
                Button { pttKey = choice.id; setPTTKey(choice.id) } label: {
                    Text(choice.label).font(RhemionStyle.font(12, .medium))
                        .foregroundStyle(on ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .activeTile(on, dark: dark, radius: 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(choice.label)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text).font(RhemionStyle.font(10, .semibold)).textCase(.uppercase).tracking(0.8)
            .foregroundStyle(RhemionStyle.tertiary(dark))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
    }

    /// Same human labels as the Settings push-to-talk picker.
    private static func pttLabel(_ key: String) -> String {
        switch key {
        case "right_option":  return "Right Option"
        case "left_option":   return "Left Option"
        case "right_cmd":     return "Right Command"
        case "left_cmd":      return "Left Command"
        case "right_control": return "Right Control"
        case "left_control":  return "Left Control"
        case "right_shift":   return "Right Shift"
        case "left_shift":    return "Left Shift"
        case "fn":            return "Fn (Globe)"
        default:              return key
        }
    }
}
