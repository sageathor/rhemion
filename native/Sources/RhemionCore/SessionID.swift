import Foundation

public struct SessionID: Equatable, Sendable, CustomStringConvertible {
    public var raw: String
    public init(raw: String) { self.raw = raw }
    public static func make() -> SessionID { SessionID(raw: UUID().uuidString) }
    public var description: String { raw }
}
