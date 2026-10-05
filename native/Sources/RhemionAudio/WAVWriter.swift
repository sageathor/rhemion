import Foundation

/// Streaming WAV writer for 16 kHz mono signed-16-bit PCM. Writes a placeholder 44-byte
/// header on open, appends little-endian samples, and patches the RIFF/data sizes on finalize.
public final class WAVWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0

    public init(url: URL) throws {
        // Owner-only (0600): a take is raw microphone audio. Explicit here as defense-in-depth on
        // top of the runtime's 0077 umask, so it holds even if this writer is ever used off the
        // umask-set runtime process.
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVWriter.header())
    }

    public func append(_ samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            bytes.append(UInt8(u & 0xff))
            bytes.append(UInt8((u >> 8) & 0xff))
        }
        try handle.write(contentsOf: Data(bytes))
        dataBytes &+= UInt32(samples.count * 2)
    }

    public func finalize() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(WAVWriter.u32le(36 &+ dataBytes)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(WAVWriter.u32le(dataBytes)))
        try handle.close()
    }

    private static func header() -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: u32le(0))                       // RIFF size, patched on finalize
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(contentsOf: u32le(16))                      // PCM fmt chunk size
        d.append(contentsOf: u16le(1))                       // audio format = PCM
        d.append(contentsOf: u16le(AudioFormat.channels))
        d.append(contentsOf: u32le(AudioFormat.sampleRate))
        let bytesPerSample = UInt32(AudioFormat.bitsPerSample / 8)
        let byteRate = AudioFormat.sampleRate * UInt32(AudioFormat.channels) * bytesPerSample
        d.append(contentsOf: u32le(byteRate))
        let blockAlign = AudioFormat.channels * UInt16(bytesPerSample)
        d.append(contentsOf: u16le(blockAlign))
        d.append(contentsOf: u16le(AudioFormat.bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: u32le(0))                       // data size, patched on finalize
        return d
    }

    private static func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private static func u16le(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
}
