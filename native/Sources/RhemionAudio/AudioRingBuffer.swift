import Synchronization

/// Single-producer / single-consumer lock-free ring of already-converted Int16 PCM samples.
/// Producer = the serial conversion queue that downmixes/resamples (Milestone 2B); consumer =
/// the reader that drains for WAV/ASR. NOTE: `write(_:)` takes an Array and allocates, so it
/// must NEVER be called from the real-time render callback (which does only AudioUnitRender +
/// a copy into a pre-allocated buffer). Overflow is all-or-nothing: a write that would not fit
/// is rejected wholesale and marks the buffer's integrity compromised, so the pipeline can fall
/// back to the full WAV.
public final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Int16>
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let integrity = Atomic<Bool>(true)

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = UnsafeMutableBufferPointer<Int16>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    public var integrityCompromised: Bool { !integrity.load(ordering: .acquiring) }

    /// Best-effort snapshot: reads the two indices independently (not one atomic snapshot),
    /// so under concurrent activity it returns a conservative count, never a wrong-high one.
    public var availableToRead: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return Int(w &- r)
    }

    @discardableResult
    public func write(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return true }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - Int(w &- r)
        guard samples.count <= free else {
            integrity.store(false, ordering: .releasing)
            return false
        }
        for (i, s) in samples.enumerated() {
            storage[Int((w &+ UInt64(i)) % UInt64(capacity))] = s
        }
        writeIndex.store(w &+ UInt64(samples.count), ordering: .releasing)
        return true
    }

    public func read(maxCount: Int) -> [Int16] {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(maxCount, Int(w &- r))
        guard n > 0 else { return [] }
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = storage[Int((r &+ UInt64(i)) % UInt64(capacity))]
        }
        readIndex.store(r &+ UInt64(n), ordering: .releasing)
        return out
    }

    public func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        integrity.store(true, ordering: .releasing)
    }
}
