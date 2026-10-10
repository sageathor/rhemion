import Foundation

/// Audio insurance (3.1). Every take is written to disk while it is spoken (`WAVSinkFactory`), and recognition reads
/// that file. When the runtime dies mid-take (`.<stem>.wav.in-progress`, header sizes never patched) or between the
/// end of a take and its journal row (a finished `<stem>.wav` no row points at), the recording is still on disk.
/// At the next start these files are collected here, BEFORE the startup reconcile would garbage-collect them as
/// orphans, and handed to `RuntimeService.recoverInterruptedTakes`, which recognises and journals them.
///
/// Only files created before this runtime started are taken (a live take of this process is never touched), only
/// from the last `maxAge`, and nothing at all on the first start with this code (`markerName` absent): older orphans
/// may be takes that were canceled on purpose before canceled audio was deleted at once.
public enum SpoolRecovery {
    public static let markerName = "spool-recovery-v1"
    public static let maxAge: TimeInterval = 3 * 24 * 3600

    /// The interrupted takes to recover, oldest first. In-progress files are repaired and renamed to their final name.
    public static func collect(historyDirectory: URL, stateDirectory: URL, knownIDs: Set<String>,
                               startedAt: Date, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let marker = stateDirectory.appendingPathComponent(markerName)
        guard fm.fileExists(atPath: marker.path) else {
            try? fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            fm.createFile(atPath: marker.path, contents: Data())
            return []
        }
        var found: [(URL, Date)] = []
        let months = ((try? fm.contentsOfDirectory(atPath: historyDirectory.path)) ?? []).filter(HistoryStore.isMonth)
        for month in months {
            let audio = historyDirectory.appendingPathComponent("\(month)/Audio", isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: audio.path)) ?? [] {
                var url = audio.appendingPathComponent(name)
                guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created < startedAt, now.timeIntervalSince(created) < maxAge else { continue }
                if name.hasPrefix("."), name.hasSuffix(".wav.in-progress") {
                    let final = audio.appendingPathComponent(String(name.dropFirst().dropLast(".in-progress".count)))
                    guard !fm.fileExists(atPath: final.path), repairHeader(url) else { continue }
                    do { try fm.moveItem(at: url, to: final) } catch { continue }
                    url = final
                } else if !name.hasSuffix(".wav") || name.hasPrefix(".") {
                    continue
                }
                guard let id = entryID(url), !knownIDs.contains(id.uppercased()) else { continue }
                found.append((url, created))
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The entry id a take file carries (`<timestamp>--<ID>.wav`).
    public static func entryID(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.range(of: "--", options: .backwards) else { return nil }
        let id = String(stem[separator.upperBound...])
        return id.isEmpty ? nil : id
    }

    /// Patch the RIFF and data sizes of a WAV whose writer never finalized it (they stay 0 until then), from the
    /// file's length. False when the file is too short to hold even the header.
    static func repairHeader(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size >= 44, let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        let dataBytes = UInt32(clamping: (size - 44) & ~1)   // whole 16-bit samples only
        do {
            try handle.seek(toOffset: 4); try handle.write(contentsOf: le32(36 &+ dataBytes))
            try handle.seek(toOffset: 40); try handle.write(contentsOf: le32(dataBytes))
            return true
        } catch { return false }
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
}
