// RuntimeClient — persistent unix-socket connection to the app's runtime:
// connect with capped backoff, frame newline-delimited JSON, decode the runtime's Event
// stream (IPCCodec.decodeEvents), and send Commands (IPCCodec.encode). All socket state lives on one
// serial queue; decoded events are handed to `onEvent` (called on that queue — the handler hops to the
// main actor for UI/delivery).

import Foundation
import RhemionIPC

final class RuntimeClient: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.sageathor.rhemion.app.ipc")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var wantConnected = false
    private var backoff: TimeInterval = 0.25
    private let minBackoff: TimeInterval = 0.25
    private let maxBackoff: TimeInterval = 5
    private let maxBuffer = 1 << 20
    private var reconnectScheduled = false
    private var exportRequest: (token: UUID, continuation: CheckedContinuation<ExportResult, Error>)?
    private var deletion: (token: UUID, ids: Set<String>, continuation: CheckedContinuation<[String], Error>)?

    struct RequestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Called on the internal serial queue for each decoded event. The handler must hop to the main
    /// actor for any UI/delivery work.
    var onEvent: (@Sendable (Event) -> Void)?
    /// Called on the internal serial queue on each successful (re)connect.
    var onConnect: (@Sendable () -> Void)?

    init(socketPath: String) { self.socketPath = socketPath }

    func connect() { queue.async { self.wantConnected = true; self.openSocket() } }

    func disconnect() { queue.async { self.wantConnected = false; self.teardown() } }

    func send(_ command: Command) {
        queue.async {
            guard self.fd >= 0, let line = try? IPCCodec.encode(command) else { return }
            _ = line.withCString { ptr in write(self.fd, ptr, strlen(ptr)) }
        }
    }

    /// Months written, plus same-named notes left alone because Rhemion didn't write them (spec 4.5).
    struct ExportResult: Sendable { let months: [String]; let skipped: [String] }

    /// One outstanding export per connection. Never retry a destructive command automatically.
    func exportNow() async throws -> ExportResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.exportRequest == nil else {
                    continuation.resume(throwing: RequestError(message: "An export is already in progress."))
                    return
                }
                guard self.fd >= 0 else {
                    continuation.resume(throwing: RequestError(message: "Runtime is disconnected. Try again once it reconnects."))
                    return
                }
                let token = UUID()
                self.exportRequest = (token, continuation)
                do {
                    let data = Data(try IPCCodec.encode(Command.exportNow).utf8)
                    let sent = data.withUnsafeBytes { bytes -> Bool in
                        var offset = 0
                        while offset < bytes.count {
                            let count = write(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { return false }
                            offset += count
                        }
                        return true
                    }
                    guard sent else { self.teardown(); self.scheduleReconnect(); return }
                } catch {
                    self.finishExport(.failure(error))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 60) {
                    guard self.exportRequest?.token == token else { return }
                    self.finishExport(.failure(RequestError(message:
                        "Export timed out; completion could not be confirmed.")))
                    // Discard late replies before permitting another request.
                    self.teardown()
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func finishExport(_ result: Result<ExportResult, Error>) {
        let pending = exportRequest
        exportRequest = nil
        pending?.continuation.resume(with: result)
    }

    /// One outstanding deletion per connection. Never retry a destructive command automatically.
    func historyDelete(ids: [String]) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.deletion == nil else {
                    continuation.resume(throwing: RequestError(message: "A deletion is already in progress."))
                    return
                }
                guard self.fd >= 0 else {
                    continuation.resume(throwing: RequestError(message: "Runtime is disconnected. Try again once it reconnects."))
                    return
                }
                let token = UUID()
                self.deletion = (token, Set(ids), continuation)
                do {
                    let data = Data(try IPCCodec.encode(Command.historyDelete(ids: ids)).utf8)
                    let sent = data.withUnsafeBytes { bytes -> Bool in
                        var offset = 0
                        while offset < bytes.count {
                            let count = write(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { return false }
                            offset += count
                        }
                        return true
                    }
                    guard sent else { self.teardown(); self.scheduleReconnect(); return }
                } catch {
                    self.finishDeletion(.failure(error))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 15) {
                    guard self.deletion?.token == token else { return }
                    self.finishDeletion(.failure(RequestError(message:
                        "Deletion timed out; its outcome is unknown. Review the refreshed journal before trying again.")))
                    // Discard late replies before permitting another request with the same IDs.
                    self.teardown()
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func finishDeletion(_ result: Result<[String], Error>) {
        let pending = deletion
        deletion = nil
        pending?.continuation.resume(with: result)
    }

    // MARK: - socket (serial queue only)

    private func openSocket() {
        guard wantConnected, fd < 0 else { return }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { scheduleReconnect(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let ok = socketPath.withCString { cstr -> Bool in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                    strncpy(dst, cstr, maxLen); return true
                }
            }
        }
        guard ok else { close(sock); scheduleReconnect(); return }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) }
        }
        guard connected == 0 else { close(sock); scheduleReconnect(); return }

        var noSignal: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Bound writes as well as response waiting, including large multi-selection batches.
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        fd = sock
        buffer.removeAll(keepingCapacity: true)
        backoff = minBackoff

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in self?.onReadable() }
        source.setCancelHandler { close(sock) }
        readSource = source
        source.resume()

        onConnect?()
    }

    private func onReadable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { teardown(); scheduleReconnect(); return }   // EOF or error: runtime went away
        buffer.append(contentsOf: chunk[0..<n])
        for event in IPCCodec.decodeEvents(from: &buffer) {
            if case .historyDeleted(let ids, let removed, let error) = event,
               let pending = deletion, pending.ids == Set(ids) {
                if let error { finishDeletion(.failure(RequestError(message: error))) }
                else if !pending.ids.subtracting(removed).isEmpty {
                    finishDeletion(.failure(RequestError(message: "Deletion was incomplete. The journal has been refreshed.")))
                } else { finishDeletion(.success(removed)) }
            }
            if case .exportCompleted(let months, let error, let skipped) = event {
                if let error { finishExport(.failure(RequestError(message: error))) }
                else { finishExport(.success(ExportResult(months: months, skipped: skipped))) }
            }
            onEvent?(event)
        }
        if buffer.count > maxBuffer { buffer.removeAll(keepingCapacity: false) }   // resync (never happens in practice)
    }

    private func teardown() {
        finishExport(.failure(RequestError(message: "Runtime disconnected; export could not be confirmed.")))
        finishDeletion(.failure(RequestError(message:
            "Runtime disconnected; deletion could not be confirmed. Review the refreshed journal.")))
        readSource?.cancel()   // cancel handler closes the fd
        readSource = nil
        fd = -1
    }

    private func scheduleReconnect() {
        guard wantConnected, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.openSocket()
        }
    }
}
