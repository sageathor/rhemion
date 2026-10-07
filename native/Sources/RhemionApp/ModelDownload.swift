// Speech-model provisioning — the app-side state + control for downloading the on-device
// recognition engine (NVIDIA Parakeet via FluidAudio). The model is NOT bundled and is absent on a fresh
// Mac, so first-run dictation would silently produce nothing; here the user downloads it explicitly (like
// granting a permission), sees progress, and the app restarts the runtime so it registers + prewarms the
// freshly-present model. Presence is read from the runtime's own `.listDevices` (`ModelOption.found`).

import SwiftUI
import RhemionIPC

@MainActor
final class ModelDownloadModel: ObservableObject {
    enum Phase: Equatable {
        case checking                 // waiting for the first devices report
        case missing                  // not on disk — offer Download
        case downloading(Double)      // 0…1 progress
        case preparing                // on disk, but the runtime is still loading/compiling it (or restarting)
        case ready                    // present and warm (usable at once)
        case failed(String)           // download error — offer Retry
    }
    @Published var phase: Phase = .checking

    /// Shown when the model is on disk but cannot be loaded; Retry downloads it again, replacing the files.
    static let damagedMessage = "Speech model couldn't be loaded"

    /// The default multilingual model we provision on first run.
    let modelID = "parakeet-v3"
    let approxSizeMB = 460

    /// Wired by AppController to the runtime socket.
    var onDownload: () -> Void = {}
    var onCancel: () -> Void = {}

    var isReady: Bool { phase == .ready }

    /// Fold a `.devices` report into the phase: `found` = present on disk, `warm` = the runtime finished
    /// preparing it. Found but not warm reads as `.preparing` (a first-time compile can take a minute).
    func devicesUpdated(_ models: [ModelOption]) {
        let option = models.first { $0.id == modelID }
        let found = option?.found ?? false
        let present: Phase = !found ? .missing
            : (option?.damaged ?? false) ? .failed(Self.damagedMessage)
            : (option?.warm ?? true) ? .ready : .preparing
        switch phase {
        case .checking, .missing, .preparing, .ready:
            phase = present
        case .failed(let message) where message == Self.damagedMessage:
            phase = present                    // a damage report follows the runtime's view, both ways
        case .downloading, .failed:
            break                              // don't clobber an in-flight download or a download error
        }
    }

    /// Fold a runtime `.modelDownload` event into the phase.
    func downloadEvent(state: String, fraction: Double?, error: String?) {
        switch state {
        case "downloading": phase = .downloading(fraction ?? 0)
        case "done":        phase = .preparing     // AppController restarts the runtime; `.ready` via devicesUpdated
        case "failed":      phase = .failed(error ?? "Download failed")
        case "canceled":    phase = .missing
        default:            break
        }
    }
}

/// The trailing control for a "Speech model" row — a Download/Retry button, a progress bar with Cancel, a
/// "Preparing…" spinner, or nothing when ready (the row's status pill carries "Ready"). Styled to
/// `RhemionStyle`, so it sits equally well in the onboarding card and a Settings row.
struct SpeechModelStatus: View {
    @ObservedObject var model: ModelDownloadModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        switch model.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .missing:
            actionButton("Download (~\(model.approxSizeMB) MB)") { model.onDownload() }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: max(0, min(1, fraction))).frame(width: 130)
                Text("\(Int((max(0, min(1, fraction))) * 100))%")
                    .font(RhemionStyle.font(11, .medium)).monospacedDigit()
                    .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 34, alignment: .trailing)
                Button { model.onCancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RhemionStyle.secondary(dark)).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Cancel download")
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing speech model…").font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
            }
        case .ready:
            EmptyView()
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.danger)
                    .lineLimit(1).truncationMode(.tail)
                actionButton(message == ModelDownloadModel.damagedMessage ? "Download again" : "Retry") { model.onDownload() }
            }
        }
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(RhemionStyle.font(12, .medium)).foregroundStyle(RhemionStyle.text(dark))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(RhemionStyle.hover(dark), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
        }.buttonStyle(.plain).fixedSize()
    }
}

/// The Settings-row value for the speech model: a green "Ready — On-device" label when present, else the
/// download control. Observes the model directly so the Ready/control switch re-renders on phase changes
/// (the Settings pane observes HubModel, not this nested object).
struct SpeechModelSettingValue: View {
    @ObservedObject var model: ModelDownloadModel
    var body: some View {
        if model.isReady {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
                Text("Ready — On-device").font(RhemionStyle.font(12, .semibold))
            }.foregroundStyle(Color(rhemionHex: 0x2E9E5B))
        } else {
            SpeechModelStatus(model: model)
        }
    }
}
