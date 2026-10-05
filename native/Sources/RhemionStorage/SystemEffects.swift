import Foundation

/// Every side effect of Clear Data / export deletion / Uninstall goes through this, so a dry run can replace
/// ALL of them.
public protocol SystemEffects: AnyObject, Sendable {
    func remove(_ item: StorageItem) throws
    func unregisterLoginItem() async throws
    func resetPrivacy() async throws
    func moveAppToTrash(_ app: URL) async throws
    func removeDefaults(domain: String)
    func relaunch(app: URL, afterPID: pid_t) throws
}

/// File removal only (tests + base for the app's real effects).
open class RealFileEffects: SystemEffects, @unchecked Sendable {
    public init() {}
    open func remove(_ item: StorageItem) throws { try SafeRemover.remove(item.relative, under: item.root) }
    open func unregisterLoginItem() async throws {}
    open func resetPrivacy() async throws {}
    open func moveAppToTrash(_ app: URL) async throws {}
    open func removeDefaults(domain: String) {}
    open func relaunch(app: URL, afterPID: pid_t) throws {}
}

public final class DryRunEffects: SystemEffects, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    public var log: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    public init() {}
    private func note(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
    public func remove(_ item: StorageItem) throws { note("would remove \(item.url.path)") }
    public func unregisterLoginItem() async throws { note("would unregister login item") }
    public func resetPrivacy() async throws { note("would reset TCC Accessibility + Microphone") }
    public func moveAppToTrash(_ app: URL) async throws { note("would move \(app.path) to Trash") }
    public func removeDefaults(domain: String) { note("would remove defaults domain \(domain)") }
    public func relaunch(app: URL, afterPID: pid_t) throws { note("would relaunch \(app.path) after \(afterPID)") }
}
