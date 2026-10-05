import Foundation

/// On-disk (allocated) sizes, never following symlinks. Call off the main thread.
public enum StorageSizes {
    public static func size(of item: StorageItem) -> Int64 {
        let url = item.url
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return 0 }
        guard v.isDirectory == true else { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            if let fv = try? f.resourceValues(forKeys: Set(keys)), fv.isSymbolicLink != true, fv.isDirectory != true {
                total += Int64(fv.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
    public static func total(_ items: [StorageItem]) -> Int64 { items.reduce(0) { $0 + size(of: $1) } }
}
