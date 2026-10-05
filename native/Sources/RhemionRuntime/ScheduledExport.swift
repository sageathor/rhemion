import Foundation
import Darwin

/// Persists the last scheduled-export time so the interval survives runtime restarts and a run
/// missed while the runtime was off fires once on the next startup tick.
public enum ScheduledExport {
    private static func marker(_ stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("export-last-run")
    }

    public static func lastRun(stateDirectory: URL) -> Date? {
        guard let text = try? String(contentsOf: marker(stateDirectory), encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func markRun(stateDirectory: URL, at date: Date) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let target = marker(stateDirectory)
        let temporary = stateDirectory.appendingPathComponent(".export-last-run-\(UUID().uuidString).tmp")
        try Data(String(date.timeIntervalSince1970).utf8).write(to: temporary)
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary); throw error
        }
    }
}
