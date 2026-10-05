import Foundation

/// Thread-safe, hot-reloading wrapper around a compiled `RecognitionDictionary` on disk.
///
/// The delivery path resolves the dictionary via `current()` from a detached Task on every
/// utterance, so editing the dictionary file (the compiled JSON)
/// takes effect immediately without restarting the runtime. Reloading is gated on the file's
/// modification date: `current()` only re-reads and re-parses when the mtime has changed since
/// the last successful load, so the hot path stays a cheap `stat` in the common case.
public final class DictionaryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    /// `nil` means "no successful load has recorded a modification date yet" (either the
    /// store has never attempted a load, or the last attempt found no file). Either way the
    /// next `current()` call will attempt a (re)load.
    private var lastModified: Date?
    private var cached: RecognitionDictionary = .empty

    public init(url: URL) {
        self.url = url
    }

    /// Returns the current dictionary, reloading from disk first if the file's modification
    /// date differs from the last successful load (or on the very first call). A missing file
    /// resolves to `.empty`. A load failure (malformed JSON, unreadable file, etc.) never
    /// throws to the caller — it keeps the last good cached value.
    public func current() -> RecognitionDictionary {
        lock.lock()
        defer { lock.unlock() }

        let diskModified = Self.modificationDate(at: url)

        guard diskModified != lastModified else {
            return cached
        }

        guard diskModified != nil else {
            // File is missing (or became unreadable for stat purposes): reset to empty and
            // record "no file" so a later-created file is picked up on a subsequent call.
            cached = .empty
            lastModified = nil
            return cached
        }

        guard let loaded = try? RecognitionDictionary.load(contentsOf: url) else {
            // Malformed/unreadable content: keep the last good cache, and do NOT advance
            // lastModified, so a subsequent fix to the file (even at the same mtime it
            // currently has) is retried rather than being treated as already-seen.
            return cached
        }

        cached = loaded
        lastModified = diskModified
        return cached
    }

    /// Reads the file's modification date, or `nil` if the file does not exist / the
    /// attribute is unavailable.
    private static func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
