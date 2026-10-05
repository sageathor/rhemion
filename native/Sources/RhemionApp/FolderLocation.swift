// One folder motif for the whole app: a folder is shown by its NAME (text colour)
// and WHERE it lives, written the way Finder names places ("iCloud Drive", "Home", "Desktop", a volume's
// name) in the secondary colour; the full path is only a hover tooltip. `FolderLocation` is the pure,
// tested naming rule; `FolderView` is the read-only two-line display (farewell window, export deletion);
// Settings' `PathField` uses the same rule on one line. One icon: SF `folder` (a file gets SF `doc`).

import AppKit
import SwiftUI

/// The humanized name + location of a path. Pure: `home` is injected so tests don't depend on the Mac.
struct FolderLocation: Equatable {
    /// The last path component (a special root gets its Finder name, e.g. "iCloud Drive").
    let name: String
    /// Where it lives, segments joined with " › " ("iCloud Drive › Notes › assets"); a path outside
    /// the known places is its raw parent path, `~`-abbreviated. Empty when there's nothing above it
    /// worth naming.
    let location: String

    static let separator = " › "
    private static let homeFolders: Set<String> = ["Desktop", "Documents", "Downloads"]

    init(name: String, location: String) { self.name = name; self.location = location }

    init(path: String, home: URL = AppPaths.trustedHome) {
        // Expand "~" first (like expandingTildeInPath, but against the injected home so tests stay pure).
        var expanded = path
        if expanded == "~" { expanded = home.path }
        else if expanded.hasPrefix("~/") { expanded = home.path + expanded.dropFirst(1) }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let comps = Array(url.pathComponents.drop { $0 == "/" })
        let homeComps = Array(home.standardizedFileURL.pathComponents.drop { $0 == "/" })
        let icloudComps = Array(AppPaths.iCloudContainersRoot(home: home).standardizedFileURL.pathComponents.drop { $0 == "/" })

        func under(_ prefix: [String]) -> [String]? {
            comps.count >= prefix.count && Array(comps.prefix(prefix.count)) == prefix ? Array(comps.dropFirst(prefix.count)) : nil
        }

        // The place segments for the WHOLE path (including the folder itself), or nil for "raw".
        var segments: [String]?
        if let rest = under(icloudComps), !rest.isEmpty {
            // iCloud Drive (com~apple~CloudDocs) and any other app's iCloud container read as iCloud Drive.
            segments = ["iCloud Drive"] + rest.dropFirst()
        } else if let rest = under(homeComps) {
            if let first = rest.first, Self.homeFolders.contains(first) { segments = rest }
            else { segments = ["Home"] + rest }
        } else if let rest = under(["Volumes"]), !rest.isEmpty {
            segments = rest
        }

        if let segments, !segments.isEmpty {
            name = segments.last!
            location = segments.dropLast().joined(separator: Self.separator)
        } else {
            name = comps.last ?? "/"
            let parent = url.deletingLastPathComponent().path
            location = comps.isEmpty ? "" : Self.abbreviate(parent, home: home)
        }
    }

    /// A whole path on one line, folder-style ("Show all N items"): "Home › .local › state › app.log".
    static func humanized(_ path: String, home: URL = AppPaths.trustedHome) -> String {
        let loc = FolderLocation(path: path, home: home)
        return loc.location.isEmpty ? loc.name : loc.location + separator + loc.name
    }

    private static func abbreviate(_ path: String, home: URL) -> String {
        let h = home.standardizedFileURL.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}

/// Byte sizes everywhere in the app (Storage, sheets, farewell): never "Zero KB" — an empty category
/// reads "0 KB" (the smallest unit shown is KB, and non-numeric wording is off).
enum ByteSize {
    static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, bytes))
    }
}

/// The app's one folder icon (SF `folder`, tertiary, 13 pt); a FILE gets SF `doc` from the same family.
struct FolderIcon: View {
    var file = false
    let dark: Bool
    var body: some View {
        Image(systemName: file ? "doc" : "folder").font(.system(size: 13)).foregroundStyle(RhemionStyle.tertiary(dark))
    }
}

/// A folder shown read-only: icon + name on the first line with a visible "Show in Finder" text link on the
/// right, the humanized location under it (secondary, wraps); the full path on hover.
struct FolderView: View {
    let url: URL
    let dark: Bool

    var body: some View {
        let loc = FolderLocation(path: url.path)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FolderIcon(dark: dark)
                Text(loc.name).font(RhemionStyle.font(12, .semibold)).foregroundStyle(RhemionStyle.text(dark))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                TextLink(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if !loc.location.isEmpty {
                Text(loc.location).font(RhemionStyle.font(11.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
        .help(url.path)
    }
}
