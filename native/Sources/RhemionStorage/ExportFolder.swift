import Foundation

/// THE rule for what counts as a usable export folder — shared by the runtime (where it exports) and
/// the app's StorageLayout (what Storage counts and Clear Data/Uninstall may delete from), so both agree.
public enum ExportFolder {
    public struct Invalid: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The resolved export folder, or throws when `path` is empty/relative, a symlink, `/`, home, or
    /// overlaps the app's own state/history (or an earlier version's state/config).
    public static func validate(_ path: String, state: URL, history: URL,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, expanded.hasPrefix("/") else {
            throw Invalid(message: "Export folder must be an absolute, non-empty path.")
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        let home = home.resolvingSymlinksInPath()
        let protected = [state, history, home.appendingPathComponent(".local/state/rhemion"),
                         home.appendingPathComponent(".config/rhemion")].map { $0.resolvingSymlinksInPath().path }
        guard resolved.path != "/", resolved != home,
              !protected.contains(where: { $0 == resolved.path || $0.hasPrefix(resolved.path + "/") || resolved.path.hasPrefix($0 + "/") }),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw Invalid(message: "Export folder overlaps application data or is an unsafe destination.")
        }
        return resolved
    }
}
