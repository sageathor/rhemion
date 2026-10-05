// Shared pieces of the storage confirmations (Settings › Advanced › Storage › Clear Data…, the export
// deletion sheet in Settings › Journal › Export, and the Uninstall farewell window): the busy note, the
// stuck state, the result list, the kept-files copy and the "Deletes / Stays" two-column pattern.

import AppKit
import RhemionStorage
import SwiftUI

/// The one-line note a confirm step shows when another storage operation is running.
struct BusyNote: View {
    let dark: Bool
    var body: some View {
        Text(AppController.busyMessage)
            .font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
    }
}

/// The shared "barrier never returned" terminal state — Clear Data, export deletion and Uninstall all
/// end here the same way: the runtime survived SIGKILL, blocks stay up, the only way out is quitting.
struct StuckContent: View {
    let message: String
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.stepGap) {
            Text("Rhemion Is Stuck")
                .font(WindowLayout.stepTitleFont).foregroundStyle(RhemionStyle.text(dark))
            Text(message).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.text(dark))
                .fixedSize(horizontal: false, vertical: true)
            // Neutral, not danger-red — quitting here isn't the destructive part (the
            // barrier already didn't come down cleanly); it's just the only available action.
            WindowButtonRow { RaisedButton(title: "Quit Rhemion") { NSApp.terminate(nil) } }
        }
    }
}

/// A scrollable list of result lines (failures, kept files) — secondary ink, selectable.
struct FailureList: View {
    let lines: [String]
    let dark: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
                        .textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 160)
    }
}

/// The one wording for exported notes Rhemion can't confirm as its own (kept by every deletion), with
/// proper singular/plural.
enum KeptFiles {
    static func lead(_ count: Int) -> String {
        count == 1 ? "Rhemion couldn't confirm it wrote this file, so it was kept:"
                   : "Rhemion couldn't confirm it wrote these \(count) files, so they were kept:"
    }
}

/// The "Deletes / Stays" confirmation pattern (DESIGN.md): two rail-coloured columns side by side,
/// each with a small-caps header; what goes is marked with a neutral (secondary) dot, what stays with a
/// gold dot. The first question of every destructive confirmation — "will I lose anything?" — at a glance.
struct ChangeColumns: View {
    var goesTitle = "Deletes"
    let goes: [String]
    var staysTitle = "Stays"
    let stays: [String]
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(goesTitle, goes, dot: RhemionStyle.secondary(dark))
            column(staysTitle, stays.isEmpty ? ["Nothing else"] : stays, dot: RhemionStyle.gold, dim: stays.isEmpty)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ title: String, _ lines: [String], dot: Color, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel(title: title, dark: dark)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(dim ? .clear : dot).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(line).font(RhemionStyle.font(12))
                            .foregroundStyle(dim ? RhemionStyle.tertiary(dark) : RhemionStyle.text(dark))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RhemionStyle.rail(dark), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

/// An in-window group label (DESIGN.md): small caps — uppercase, 10.5 bold, tracked, tertiary. Distinct
/// from a Settings section header (bold sentence case, text colour).
struct GroupLabel: View {
    let title: String
    let dark: Bool
    var body: some View {
        Text(title.uppercased()).font(RhemionStyle.font(10.5, .bold)).tracking(0.6)
            .foregroundStyle(RhemionStyle.tertiary(dark))
            .accessibilityAddTraits(.isHeader)
    }
}
