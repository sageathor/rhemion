import Foundation

public enum RuntimePaths {
    public static func stateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["RHEMION_RUNTIME_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/state/rhemion", isDirectory: true)
    }

    public static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["RHEMION_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let snapshot = stateDirectory().appendingPathComponent("active/settings.json")
        if let data = try? Data(contentsOf: snapshot),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = (object["data_dir"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rhemion", isDirectory: true)
    }

    public static func historyDirectory() -> URL {
        dataDirectory().appendingPathComponent("history", isDirectory: true)
    }

    public static func historyMonthDirectory(for date: Date, calendar: Calendar = .current) -> URL {
        let components = calendar.dateComponents([.year, .month], from: date)
        let month = String(format: "%04d-%02d", components.year!, components.month!)
        return historyDirectory().appendingPathComponent(month, isDirectory: true)
    }

    public static func historyAudioDirectory(for date: Date, calendar: Calendar = .current) -> URL {
        historyMonthDirectory(for: date, calendar: calendar).appendingPathComponent("Audio", isDirectory: true)
    }

    @discardableResult
    public static func ensureStateDirectory() throws -> URL {
        let dir = stateDirectory()
        // Owner-only (0700): the state dir holds the IPC socket, transcript JSONL, audio takes, and
        // settings. Its 0700 mode gates everything inside regardless of individual file modes.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Tighten a directory an older build created as 0755 (createDirectory's attributes apply only
        // on creation): make an already-existing state dir owner-only too.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
