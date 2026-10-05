import CryptoKit
import Foundation

/// Which files in an export folder Rhemion wrote. Bound to the folder's identity (real path + device +
/// inode), and a file counts as Rhemion's only while its CURRENT content still hashes to what Rhemion
/// wrote — an edited or replaced file is the user's and is never overwritten or deleted.
public struct ExportRegistry: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var device: UInt64
        public var inode: UInt64
        public var files: [String: String]   // name -> sha256 hex of the bytes Rhemion wrote
    }
    public static let fileName = "export-manifest.json"
    public var folders: [Folder] = []
    public init() {}

    public static func load(from url: URL) -> ExportRegistry {
        guard let data = try? Data(contentsOf: url) else { return ExportRegistry() }
        return (try? JSONDecoder().decode(ExportRegistry.self, from: data)) ?? ExportRegistry()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func identity(of dir: URL) -> (path: String, device: UInt64, inode: UInt64)? {
        let path = dir.resolvingSymlinksInPath().path
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        // st_dev is a signed Int32: bit-cast, never narrow/convert with a trap on a negative value.
        return (path, UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func folderIndex(_ dir: URL) -> Int? {
        guard let id = Self.identity(of: dir) else { return nil }
        return folders.firstIndex { $0.path == id.path && $0.device == id.device && $0.inode == id.inode }
    }

    public func owns(_ name: String, in dir: URL, data: Data) -> Bool {
        guard let i = folderIndex(dir), let h = folders[i].files[name] else { return false }
        return h == Self.hash(data)
    }

    public mutating func record(_ name: String, in dir: URL, data: Data) {
        guard let id = Self.identity(of: dir) else { return }
        if let i = folderIndex(dir) { folders[i].files[name] = Self.hash(data) }
        else { folders.append(Folder(path: id.path, device: id.device, inode: id.inode, files: [name: Self.hash(data)])) }
    }

    /// Whether this folder (by identity) has a record at all — even one with no files.
    public func knowsFolder(_ dir: URL) -> Bool { folderIndex(dir) != nil }

    public mutating func forget(_ name: String, in dir: URL) {
        if let i = folderIndex(dir) { folders[i].files[name] = nil }
    }

    /// No folder names any file — the registry proves nothing any more.
    public var isEmpty: Bool { folders.allSatisfy { $0.files.isEmpty } }

    public func ownedFiles(in dir: URL) -> [String] {
        guard let i = folderIndex(dir) else { return [] }
        return folders[i].files.keys.sorted().filter { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return false }
            return folders[i].files[name] == Self.hash(data)
        }
    }

    public func unconfirmedFiles(in dir: URL) -> [String] {
        let owned = Set(ownedFiles(in: dir))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { Self.isMonthNote($0) && !owned.contains($0) }.sorted()
    }

    static func isMonthNote(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}\.md$"#, options: .regularExpression) != nil
    }
}
