// The operation pop-up (DESIGN.md "Operation pop-up"): the standard for a destructive
// confirmation with progress. A compact borderless panel, a child of its window, centred over it; the
// window keeps its own screen and height while the pop-up walks confirm → progress → result. Clear Data
// (`ClearDataPopupView`) and Uninstall (`FarewellPopupView`) both use these pieces: `OperationPopupHost`
// (the panel's life over its window), `OperationPopupCard` (the card), `OperationReceiptRow` + the shared
// `OperationRowStatus` marks (the "Receipt" rows).

import AppKit
import SwiftUI

/// A receipt row's mark: a neutral dot on the confirmation; while working done / running / waiting; in the
/// result done, or `notDone` for a row that didn't finish (its failures are listed below).
enum OperationRowStatus: Equatable { case dot, done, running, waiting, notDone }

/// The operation pop-up's panel: borderless — no title bar, no logo — with a clear ground so the SwiftUI
/// content draws our 12 pt rounded card and the window server its shadow. It takes the key focus (Return /
/// Esc reach it); Esc asks `onCancel`.
final class OperationPanel: NSPanel {
    var onCancel: () -> Void = {}

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .alertPanel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// One pop-up's life over its window: shown as a child window centred over it (re-centred as its height
/// follows the content), closed with the window handed back the key focus. The window's controller calls
/// `refocus()` from `windowDidBecomeKey`, so a click on the window gives the focus straight back.
@MainActor
final class OperationPopupHost {
    private var panel: OperationPanel?
    private var resize: NSObjectProtocol?
    private weak var parent: NSWindow?

    var isShowing: Bool { panel != nil }

    func show<Content: View>(_ content: Content, over window: NSWindow, onCancel: @escaping () -> Void) {
        guard panel == nil else { return }
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        let panel = OperationPanel(contentViewController: hosting)
        panel.onCancel = onCancel
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        parent = window
        resize = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.center() }
        }
        if let view = panel.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let fit = view.fittingSize
            if fit.width > 0, fit.height > 0 { panel.setContentSize(fit) }
        }
        center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Centred over the window (the pop-up's height follows its content step by step).
    private func center() {
        guard let panel, let parent else { return }
        let size = panel.frame.size, host = parent.frame
        panel.setFrameOrigin(NSPoint(x: (host.midX - size.width / 2).rounded(), y: (host.midY - size.height / 2).rounded()))
        panel.invalidateShadow()
    }

    func close() {
        guard let panel else { return }
        if let resize { NotificationCenter.default.removeObserver(resize) }
        resize = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        if parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) }
    }

    /// Brings the pop-up forward when it is up; false when there is none.
    @discardableResult func refocus() -> Bool {
        guard let panel, panel.isVisible else { return false }
        panel.makeKeyAndOrderFront(nil)
        return true
    }
}

/// The pop-up's card: width 400, height = content, the pop-up padding and gap, `win` ground, radius 12,
/// a 0.5 pt edge.
struct OperationPopupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: WindowLayout.popupGap) { content() }
            .padding(WindowLayout.popupPadding)
            .frame(width: WindowLayout.popupWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: WindowLayout.popupRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WindowLayout.popupRadius)
                    .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 0.5)
            }
            .foregroundStyle(RhemionStyle.text(dark))
    }
}

/// The pop-up's title: it names the step (the question, "…ing…", the result).
struct OperationPopupTitle: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text).font(WindowLayout.stepTitleFont).foregroundStyle(RhemionStyle.text(scheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One receipt line's content.
struct OperationReceiptLine: Identifiable, Equatable {
    let id: String
    let name: String
    var detail: String? = nil
    var size: String = ""
    /// "Can't be recovered" on the confirmation.
    var permanent = false
    var status: OperationRowStatus = .dot
}

/// The receipt: one row per line, a 1 pt `line` between rows.
struct OperationReceipt: View {
    let lines: [OperationReceiptLine]
    let showPermanent: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                OperationReceiptRow(line: line, showPermanent: showPermanent, dark: dark)
                    .overlay(alignment: .bottom) {
                        if index < lines.count - 1 { Rectangle().fill(RhemionStyle.line(dark)).frame(height: 1) }
                    }
            }
        }
    }
}

/// One receipt line: mark · name · " · detail" (secondary) [· "Can't be recovered" (danger)] · size (right,
/// tabular). A waiting row reads `tertiary`.
struct OperationReceiptRow: View {
    let line: OperationReceiptLine
    let showPermanent: Bool
    let dark: Bool

    var body: some View {
        let waiting = line.status == .waiting || line.status == .notDone
        var text = Text(line.name).font(RhemionStyle.font(13))
            .foregroundColor(waiting ? RhemionStyle.tertiary(dark) : RhemionStyle.text(dark))
        if let detail = line.detail {
            text = text + Text(" · \(detail)").font(RhemionStyle.font(12)).foregroundColor(RhemionStyle.secondary(dark))
        }
        if showPermanent && line.permanent {
            text = text + Text("  Can't be recovered").font(RhemionStyle.font(10.5, .semibold)).foregroundColor(RhemionStyle.danger)
        }
        return HStack(alignment: .center, spacing: 10) {
            OperationStatusMark(status: line.status, dark: dark)
            text.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !line.size.isEmpty {
                Text(line.size).font(RhemionStyle.font(12)).monospacedDigit().foregroundStyle(RhemionStyle.secondary(dark))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.spoken(line.status))
    }

    private static func spoken(_ s: OperationRowStatus) -> String {
        switch s {
        case .dot: return ""
        case .done: return "done"
        case .running: return "in progress"
        case .waiting: return "waiting"
        case .notDone: return "not done"
        }
    }
}

/// The receipt's leading mark: a 6 pt neutral dot (confirm), or a 16 pt status circle — done = gold with a
/// white tick, running = a gold spinner (still with Reduce Motion), waiting / not done = an empty ring.
struct OperationStatusMark: View {
    let status: OperationRowStatus
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        switch status {
        case .dot:
            Circle().fill(RhemionStyle.secondary(dark)).frame(width: 6, height: 6)
        case .done:
            Circle().fill(RhemionStyle.gold).frame(width: 16, height: 16)
                .overlay { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
        case .running:
            Circle().trim(from: 0, to: 0.75).stroke(RhemionStyle.gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 14.5, height: 14.5).frame(width: 16, height: 16)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                .onAppear { if !reduceMotion { spin = true } }
        case .waiting, .notDone:
            Circle().strokeBorder(RhemionStyle.tertiary(dark), lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }
}

// MARK: - Paced progress

/// How long each step of the pop-up's progress stays on screen: deletion is fast and a dry run is
/// instant, so without pacing the rows blink by. Each step shows "in progress" for at least `running`,
/// then "done" for `done`, before the next starts — the UI catches up, the work is never slowed. The full
/// minimums (0.45 s + 0.25 s) hold up to `budget` in total; beyond it (many rows) both shrink in proportion
/// so the added time stays bounded. Reduce Motion keeps the durations (only the spinner stops turning).
struct ProgressPacing: Equatable {
    static let minRunning = 0.45, minDone = 0.25
    /// The most pacing can add in all (5 uninstall steps at the full minimums = 3.5 s).
    static let budget = 3.5
    let running: Double, done: Double

    init(steps: Int) {
        let full = Double(max(steps, 1)) * (Self.minRunning + Self.minDone)
        let scale = min(1, Self.budget / full)
        running = Self.minRunning * scale
        done = Self.minDone * scale
    }
}

/// The pacer's clock: injected so the timing is testable without waiting.
protocol PacingClock: Sendable {
    /// Seconds, monotonic.
    var now: Double { get }
    func sleep(_ seconds: Double) async
}

struct SystemPacingClock: PacingClock {
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}

/// What the progress shows: step `index` in progress, or (`done`) just finished with the next not started.
/// `index == count` = every step done. `failed`: the steps the work reported as failed or never run
/// (`ProgressPacer.finish(notDone:)`) — once walked past they read "not done", never ticked.
struct PacedStep: Equatable {
    var index: Int
    var done: Bool
    var failed: Set<Int> = []

    /// A row's mark from the shown step.
    func status(_ i: Int) -> OperationRowStatus {
        let walked = i < index || (i == index && done)
        if walked && failed.contains(i) { return .notDone }
        return i < index ? .done : i > index ? .waiting : done ? .done : .running
    }
}

/// Walks the pop-up's steps no faster than `ProgressPacing` allows while the work reports where it is
/// (`advance(to:)` = the work has started step `i`, every step before it is finished). `finish(notDone:)` =
/// the work is over, with the outcome already known: the remaining steps are walked at their minimums and it
/// returns once the last one is shown; the `notDone` steps (failed, or never ran) end on "not done", never
/// on a tick. `stop()` abandons the walk (busy / stuck: nothing ran).
@MainActor
final class ProgressPacer {
    let count: Int
    let pacing: ProgressPacing
    private let clock: any PacingClock
    private let show: (PacedStep) -> Void
    private var reached = 0, finished = false, stopped = false
    private var failed: Set<Int> = []
    private var shownAt = 0.0
    private var wake: CheckedContinuation<Void, Never>?
    private var loop: Task<Void, Never>?

    init(count: Int, clock: any PacingClock, show: @escaping (PacedStep) -> Void) {
        self.count = count
        pacing = ProgressPacing(steps: count)
        self.clock = clock
        self.show = show
    }

    func start() {
        guard loop == nil else { return }
        shownAt = clock.now
        show(PacedStep(index: 0, done: false))
        loop = Task { [weak self] in await self?.drive() }
    }

    /// `failed`: steps the work already knows did not go (all before `step`); they are walked to "not done".
    func advance(to step: Int, failed newlyFailed: Set<Int> = []) {
        guard !finished, step > reached else { return }
        failed.formUnion(newlyFailed)
        reached = min(step, count)
        resume()
    }

    func finish(notDone: Set<Int> = []) async {
        failed.formUnion(notDone)
        finished = true
        reached = count
        resume()
        await loop?.value
    }

    func stop() {
        stopped = true
        resume()
        loop?.cancel()
    }

    private func drive() async {
        var shown = 0
        while !stopped && shown < count {
            guard shown < reached else {
                await withCheckedContinuation { wake = $0 }
                continue
            }
            let left = pacing.running - (clock.now - shownAt)
            if left > 0 { await clock.sleep(left) }
            if stopped { return }
            show(PacedStep(index: shown, done: true, failed: failed))
            await clock.sleep(pacing.done)
            if stopped { return }
            shown += 1
            shownAt = clock.now
            show(PacedStep(index: shown, done: false, failed: failed))
        }
    }

    private func resume() {
        wake?.resume()
        wake = nil
    }
}

// MARK: - Removed items

/// "Show all N items": a quiet text link under the report's rows that expands a scrollable list (max 200 pt)
/// of every path the operation removed (or would have, in a dry run), each humanized like a folder
/// ("Home › .local › state › rhemion-v3 › app.log"), the full path on hover.
struct RemovedItemsDisclosure: View {
    let paths: [String]
    let dark: Bool
    @State private var open = false

    var body: some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TextLink(title: open ? "Hide items" : Self.showTitle(paths.count)) { open.toggle() }
                if open {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                                Text(FolderLocation.humanized(path))
                                    .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .help(path)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    static func showTitle(_ n: Int) -> String { n == 1 ? "Show 1 item" : "Show all \(n) items" }
}

/// A result's title; in a dry run with "Dry run — nothing was removed" in `tertiary` right under it.
struct OperationResultTitle: View {
    let text: String
    let dryRun: Bool
    @Environment(\.colorScheme) private var scheme
    static let dryRunText = "Dry run — nothing was removed"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            OperationPopupTitle(text: text)
            if dryRun {
                Text(Self.dryRunText).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.tertiary(scheme == .dark))
            }
        }
    }
}
