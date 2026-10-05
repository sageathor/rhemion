import Foundation

/// Moves history from the earlier location (<state>/data/history) into <data>/history WITHOUT losing anything:
/// missing items move as-is; a file that already exists is dropped only if byte-identical, otherwise it
/// moves in as "<name> (migrated).<ext>"; old folders are removed only when empty afterwards.
public enum HistoryMigration {
    public struct Result: Equatable { public var movedFiles = 0; public var renamedConflicts = 0; public var removedOld = false }

    public static func migrate(old: URL, new: URL) throws -> Result {
        let fm = FileManager.default
        var result = Result()
        guard fm.fileExists(atPath: old.path) else { return result }
        if !fm.fileExists(atPath: new.path) {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            result.movedFiles = 1; result.removedOld = true
            return result
        }
        merge(old, into: new, result: &result)
        result.removedOld = removeIfEmpty(old)
        return result
    }

    private static func merge(_ src: URL, into dst: URL, result: inout Result) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dst.path, isDirectory: &isDir), isDir.boolValue else { return }  // can't merge: leave src
        for item in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !fm.fileExists(atPath: target.path) {
                if (try? fm.moveItem(at: item, to: target)) != nil { result.movedFiles += 1 }
            } else if itemIsDir {
                merge(item, into: target, result: &result)
                _ = removeIfEmpty(item)
            } else if fm.contentsEqual(atPath: item.path, andPath: target.path) {
                try? fm.removeItem(at: item)
            } else {
                let ext = item.pathExtension, stem = item.deletingPathExtension().lastPathComponent
                let renamed = dst.appendingPathComponent(ext.isEmpty ? "\(stem) (migrated)" : "\(stem) (migrated).\(ext)")
                if !fm.fileExists(atPath: renamed.path), (try? fm.moveItem(at: item, to: renamed)) != nil {
                    result.movedFiles += 1; result.renamedConflicts += 1
                }
            }
        }
    }

    /// Remove `dir` bottom-up if (after removing empty subfolders) it has no entries. Returns true if gone.
    @discardableResult
    static func removeIfEmpty(_ dir: URL) -> Bool {
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { removeIfEmpty(sub) }
        guard let rest = try? fm.contentsOfDirectory(atPath: dir.path) else { return !fm.fileExists(atPath: dir.path) }
        guard rest.filter({ $0 != ".DS_Store" }).isEmpty else { return false }
        return (try? fm.removeItem(at: dir)) != nil
    }
}
