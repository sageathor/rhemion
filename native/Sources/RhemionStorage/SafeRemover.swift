import Darwin
import Foundation

/// Deletes paths under a TRUSTED ROOT without ever following a symlink. The root itself is opened from
/// "/" one component at a time with O_NOFOLLOW (a symlink anywhere on the way = refusal), then every
/// step below it is openat/unlinkat relative to a held descriptor, so nothing can be swapped between the
/// check and the delete. The root itself is never removed. A symlink met INSIDE a removed tree is
/// unlinked as a link (its target is untouched).
public enum SafeRemover {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let path: String
        public let reason: String
        public var description: String { "\(path): \(reason)" }
    }

    /// Open `root` as a directory descriptor, refusing any symlinked component or path traversal (. or ..).
    /// Does not use Foundation's standardizedFileURL (which normalizes /private/var back to /var, a symlink).
    /// Caller closes it.
    public static func openTrustedRoot(_ root: URL) throws -> Int32 {
        let path = root.path
        guard path.hasPrefix("/") else { throw Failure(path: path, reason: "not an absolute path") }

        // Split path, drop empty components, reject . and ..
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for comp in comps {
            guard comp != "." && comp != ".." else {
                throw Failure(path: path, reason: "path contains . or ..")
            }
        }

        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(path: "/", reason: errnoText()) }
        for comp in comps {
            let next = openat(fd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let err = errno
            close(fd)
            guard next >= 0 else {
                throw Failure(path: path, reason: err == ELOOP || err == ENOTDIR
                              ? "path contains a symbolic link or a non-folder (\(comp))"
                              : String(cString: strerror(err)))
            }
            fd = next
        }
        return fd
    }

    /// Remove `relative` (plain name components, no "/" "." "..") under `root`. Missing = success.
    public static func remove(_ relative: [String], under root: URL) throws {
        let display = ([root.path] + relative).joined(separator: "/")
        guard !relative.isEmpty,
              relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else { throw Failure(path: display, reason: "invalid relative path") }
        var fd = try openTrustedRoot(root)
        defer { close(fd) }
        for comp in relative.dropLast() {
            let next = openat(fd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return }
                throw Failure(path: display, reason: errno == ELOOP || errno == ENOTDIR
                              ? "path contains a symbolic link or a non-folder (\(comp))" : errnoText())
            }
            close(fd); fd = next
        }
        try removeEntry(relative.last!, in: fd, display: display)
    }

    private static func removeEntry(_ name: String, in dirfd: Int32, display: String) throws {
        var info = stat()
        if fstatat(dirfd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Failure(path: display, reason: errnoText())
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let child = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure(path: display, reason: errnoText()) }
            defer { close(child) }
            for entry in try names(in: child) { try removeEntry(entry, in: child, display: display + "/" + entry) }
            if unlinkat(dirfd, name, AT_REMOVEDIR) != 0, errno != ENOENT { throw Failure(path: display, reason: errnoText()) }
        } else if unlinkat(dirfd, name, 0) != 0, errno != ENOENT {
            throw Failure(path: display, reason: errnoText())
        }
    }

    /// Entry names of a directory descriptor (collected first — mutating mid-readdir can skip entries).
    static func names(in dirfd: Int32) throws -> [String] {
        guard let handle = fdopendir(dup(dirfd)) else { throw Failure(path: "(dir)", reason: errnoText()) }
        defer { closedir(handle) }
        var out: [String] = []
        while let entry = readdir(handle) {
            var record = entry.pointee
            let name = withUnsafeBytes(of: &record.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    static func errnoText() -> String { String(cString: strerror(errno)) }
}
