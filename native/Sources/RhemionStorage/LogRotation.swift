import Darwin
import Foundation

/// Automatic hygiene for Rhemion's OWN diagnostic logs — `app.log` and `runtime.log` in the state folder
/// and their rotated copies (`app.log.1`, `app.log.2`, …). Never the dictation logs (`log/dictate-*.jsonl`
/// are the Journal). Run on launch and while writing (`AppLog`), and before each runtime spawn.
///
/// The policy (`enforce`):
/// - a live log over `maxFileBytes`, or whose content started more than `maxAge` ago, rotates: copies shift
///   up (`.1` → `.2`), the live file becomes `.1` (renamed — or, for a log another process holds open with
///   O_APPEND, copied and truncated in place), keeping at most `keep` copies;
/// - a copy whose NEWEST line is more than `maxAge` old (its modification date) is dropped — so a log
///   rotated for age keeps its recent lines for up to `maxAge`, and nothing is kept past it;
/// - while everything together is over `maxTotalBytes`, the oldest copy is dropped.
/// "Content started" (live logs) = the file's creation date (a truncated live file starts again now).
public enum LogRotation {
    public static let baseNames = ["app.log", "runtime.log"]

    public struct Policy: Sendable, Equatable {
        public var maxFileBytes: Int64
        public var keep: Int
        public var maxAge: TimeInterval
        public var maxTotalBytes: Int64
        public init(maxFileBytes: Int64 = 5_000_000, keep: Int = 2, maxAge: TimeInterval = 7 * 24 * 3600,
                    maxTotalBytes: Int64 = 15_000_000) {
            self.maxFileBytes = maxFileBytes; self.keep = keep; self.maxAge = maxAge; self.maxTotalBytes = maxTotalBytes
        }
    }

    /// "app.log.2" → ("app.log", 2); nil for anything that isn't a rotated copy of a diagnostic log.
    public static func rotatedCopy(_ name: String) -> (base: String, index: Int)? {
        for base in baseNames where name.hasPrefix(base + ".") {
            let tail = name.dropFirst(base.count + 1)
            if !tail.isEmpty, tail.allSatisfy(\.isASCII), tail.allSatisfy(\.isNumber), let n = Int(tail), n > 0 {
                return (base, n)
            }
        }
        return nil
    }

    /// Every diagnostic log file in `dir`: the live logs that exist, then the rotated copies. Sorted.
    public static func files(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { baseNames.contains($0) || rotatedCopy($0) != nil }.sorted()
    }

    private static func attributes(_ url: URL) -> (size: Int64, created: Date?, modified: Date?)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return ((a[.size] as? NSNumber)?.int64Value ?? 0, a[.creationDate] as? Date, a[.modificationDate] as? Date)
    }

    /// Rotate one live log now. `copyTruncate`: another process writes it through an O_APPEND descriptor
    /// (the runtime's stdout/stderr) — copy its bytes to `.1` and truncate it in place, so that writer keeps
    /// going into a fresh live file instead of into the copy.
    public static func rotate(_ live: URL, policy: Policy = Policy(), copyTruncate: Bool = false, now: Date = Date()) throws {
        let fm = FileManager.default
        let dir = live.deletingLastPathComponent(), base = live.lastPathComponent
        guard let a = attributes(live) else { return }
        func copy(_ n: Int) -> URL { dir.appendingPathComponent("\(base).\(n)") }
        // Drop copies past `keep` (and the one about to be pushed past it), then shift the rest up.
        for name in files(in: dir) {
            if let r = rotatedCopy(name), r.base == base, r.index >= policy.keep { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
        guard policy.keep > 0 else {
            if copyTruncate { truncate(live, now: now) } else { try fm.removeItem(at: live) }
            return
        }
        for n in stride(from: policy.keep - 1, through: 1, by: -1) where fm.fileExists(atPath: copy(n).path) {
            try fm.moveItem(at: copy(n), to: copy(n + 1))
        }
        if copyTruncate {
            try fm.copyItem(at: live, to: copy(1))
            // The copy carries the live file's dates: its newest line is as old as the live file's last write.
            var dates: [FileAttributeKey: Any] = [:]
            if let created = a.created { dates[.creationDate] = created }
            if let modified = a.modified { dates[.modificationDate] = modified }
            try? fm.setAttributes(dates, ofItemAtPath: copy(1).path)
            truncate(live, now: now)
        } else {
            try fm.moveItem(at: live, to: copy(1))
        }
    }

    private static func truncate(_ url: URL, now: Date) {
        _ = Darwin.truncate(url.path, 0)
        try? FileManager.default.setAttributes([.creationDate: now], ofItemAtPath: url.path)
    }

    /// Apply the whole policy to the diagnostic logs in `dir` (see the type's comment). `copyTruncate`: the
    /// live logs another process holds open (rotated by copy + truncate instead of rename). Never throws:
    /// a log that can't be rotated is left as it is.
    public static func enforce(in dir: URL, policy: Policy = Policy(), copyTruncate: Set<String> = [], now: Date = Date()) {
        let fm = FileManager.default
        func old(_ created: Date?) -> Bool { created.map { now.timeIntervalSince($0) > policy.maxAge } ?? false }
        for base in baseNames {
            let live = dir.appendingPathComponent(base)
            guard let a = attributes(live), a.size > 0, a.size > policy.maxFileBytes || old(a.created) else { continue }
            try? rotate(live, policy: policy, copyTruncate: copyTruncate.contains(base), now: now)
        }
        // Copies whose newest line is too old.
        var copies: [(url: URL, size: Int64, modified: Date?, index: Int)] = []
        for name in files(in: dir) {
            guard let r = rotatedCopy(name) else { continue }
            let url = dir.appendingPathComponent(name)
            guard let a = attributes(url) else { continue }
            if old(a.modified) || r.index > policy.keep { try? fm.removeItem(at: url); continue }
            copies.append((url, a.size, a.modified, r.index))
        }
        // The total cap: drop the oldest copies first (highest index, then the earliest last write).
        var total = baseNames.compactMap { attributes(dir.appendingPathComponent($0))?.size }.reduce(0, +)
            + copies.map(\.size).reduce(0, +)
        copies.sort { ($0.index, $1.modified ?? .distantPast) > ($1.index, $0.modified ?? .distantPast) }
        for c in copies where total > policy.maxTotalBytes {
            if (try? fm.removeItem(at: c.url)) != nil { total -= c.size }
        }
    }
}
