// RecallStore — reads the last usable dictation transcript from the history log, for the
// recall hotkey: the runtime journals every dictation to
// monthly JSONL logs under the state dir; this scans them newest-first (months descending, and within
// a file bottom-up) and returns the first transcript with real text — `enhanced` when it is a
// non-empty string, otherwise `clean` (enhancement-off writes JSON null, which is not a String here).
//
// It reads the files directly — no runtime round-trip. Reads from AppPaths.stateDir/log, never the earlier
// versions' ~/.local/state/rhemion.

import Foundation

enum RecallStore {
    static var logDirectory: URL { AppPaths.stateDir.appendingPathComponent("log", isDirectory: true) }

    /// The newest transcript to re-insert, or nil if there is nothing to recall.
    static func lastTranscript() -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path)) ?? [])
            .filter { $0.range(of: #"^dictate-\d{4}-\d{2}\.jsonl$"#, options: .regularExpression) != nil }
            .sorted(by: >)   // "dictate-2026-09" > "dictate-2026-08": newest month first
        for name in names {
            guard let text = try? String(contentsOf: logDirectory.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                else { continue }
                // enhanced wins only when it is a real non-blank string; else clean. (JSON null → not a
                // String here, so it correctly falls through to clean.)
                if let value = nonBlank(object["enhanced"]) ?? nonBlank(object["clean"]) { return value }
            }
        }
        return nil
    }

    private static func nonBlank(_ value: Any?) -> String? {
        guard let string = value as? String,
              string.contains(where: { !$0.isWhitespace }) else { return nil }
        return string
    }
}
