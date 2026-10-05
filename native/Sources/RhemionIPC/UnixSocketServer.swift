import Foundation
import Darwin

public enum SocketError: Error {
    case socketFailed(Int32), bindFailed(Int32), listenFailed(Int32)
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    public func send(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _ = line.withCString { ptr in write(fd, ptr, strlen(ptr)) }
    }
    public func close() { Darwin.close(fd) }
    var rawFD: Int32 { fd }
}

public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "rhemion.ipc.accept")

    public init(path: String) { self.path = path }

    private func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        running = value
    }

    private func getListenFD() -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenFD
    }

    private func setListenFD(_ value: Int32) {
        stateLock.lock(); defer { stateLock.unlock() }
        listenFD = value
    }

    public func start(onLine: @escaping @Sendable (String, UnixSocketConnection) -> Void) throws {
        unlink(path)
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { throw SocketError.socketFailed(errno) }
        setListenFD(newFD)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, maxLen)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(newFD, $0, len) }
        }
        guard bound == 0 else { throw SocketError.bindFailed(errno) }
        // Owner-only socket (0600): only the same user can connect, independent of the parent dir's
        // mode. Defense-in-depth with the 0700 state dir and the per-peer uid check below.
        chmod(path, 0o600)
        guard listen(newFD, 8) == 0 else { throw SocketError.listenFailed(errno) }

        setRunning(true)
        acceptQueue.async { [weak self] in self?.acceptLoop(onLine: onLine) }
    }

    private func acceptLoop(onLine: @escaping @Sendable (String, UnixSocketConnection) -> Void) {
        while isRunning() {
            let clientFD = accept(getListenFD(), nil, nil)
            guard clientFD >= 0 else { if isRunning() { continue } else { break } }
            // Only accept peers running as the same user. getpeereid gives the connecting process's
            // effective credentials; anything other than our own euid (or a failed lookup) is refused,
            // so another local account can never drive the runtime even if it reaches the socket.
            var peerEUID: uid_t = 0, peerEGID: gid_t = 0
            if getpeereid(clientFD, &peerEUID, &peerEGID) != 0 || peerEUID != geteuid() {
                Darwin.close(clientFD)
                continue
            }
            let conn = UnixSocketConnection(fd: clientFD)
            let readQueue = DispatchQueue(label: "rhemion.ipc.read.\(clientFD)")
            readQueue.async { [weak self] in self?.readLoop(conn: conn, onLine: onLine) }
        }
    }

    // Cap on a single unterminated line. Commands are tiny JSON; a peer streaming past this without a
    // newline is abusive (a memory-exhaustion attempt), so the connection is dropped rather than the
    // buffer grown without bound.
    private static let maxLineBytes = 1 << 20   // 1 MiB

    private func readLoop(conn: UnixSocketConnection, onLine: @escaping @Sendable (String, UnixSocketConnection) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while isRunning() {
            let n = read(conn.rawFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                if let line = String(data: Data(lineData), encoding: .utf8) {
                    onLine(line, conn)
                }
            }
            // After draining complete lines, any residual is a partial line still awaiting its
            // newline. If that alone exceeds the cap, the peer is flooding without a terminator.
            if buffer.count > Self.maxLineBytes { break }
        }
        conn.close()
    }

    public func stop() {
        setRunning(false)
        let fd = getListenFD()
        if fd >= 0 { Darwin.close(fd); setListenFD(-1) }
        unlink(path)
    }
}
