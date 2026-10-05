import Foundation
import RhemionAudio

/// Reads WAV files containing 16-bit mono PCM audio at 16 kHz.
public enum WAVReader {
    /// Reads a WAV file and returns the samples as signed 16-bit integers.
    /// - Parameter url: Path to the WAV file
    /// - Returns: Array of Int16 samples
    /// - Throws: If the file cannot be read or is not a valid WAV file
    public static func readInt16Mono16k(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)

        guard bytes.count >= 12 else {
            throw NSError(domain: "WAVReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "File too small"])
        }

        // Verify RIFF/WAVE headers
        guard bytes[0] == UInt8(ascii: "R"), bytes[1] == UInt8(ascii: "I"), bytes[2] == UInt8(ascii: "F"), bytes[3] == UInt8(ascii: "F") else {
            throw NSError(domain: "WAVReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not a RIFF file"])
        }

        guard bytes[8] == UInt8(ascii: "W"), bytes[9] == UInt8(ascii: "A"), bytes[10] == UInt8(ascii: "V"), bytes[11] == UInt8(ascii: "E") else {
            throw NSError(domain: "WAVReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not a WAVE file"])
        }

        // Scan for data chunk
        var pos = 12
        var dataStart: Int? = nil
        var dataSize: UInt32? = nil

        while pos + 8 <= bytes.count {
            let id0 = bytes[pos]
            let id1 = bytes[pos + 1]
            let id2 = bytes[pos + 2]
            let id3 = bytes[pos + 3]

            if id0 == UInt8(ascii: "d"), id1 == UInt8(ascii: "a"), id2 == UInt8(ascii: "t"), id3 == UInt8(ascii: "a") {
                dataStart = pos + 8
                dataSize = UInt32(bytes[pos + 4]) |
                          (UInt32(bytes[pos + 5]) << 8) |
                          (UInt32(bytes[pos + 6]) << 16) |
                          (UInt32(bytes[pos + 7]) << 24)
                break
            }

            let chunkSize = UInt32(bytes[pos + 4]) |
                           (UInt32(bytes[pos + 5]) << 8) |
                           (UInt32(bytes[pos + 6]) << 16) |
                           (UInt32(bytes[pos + 7]) << 24)
            pos += 8 + Int(chunkSize)
        }

        guard let dataStart = dataStart, let dataSize = dataSize else {
            throw NSError(domain: "WAVReader", code: 4, userInfo: [NSLocalizedDescriptionKey: "No data chunk found"])
        }

        let endPos = dataStart + Int(dataSize)
        guard endPos <= bytes.count else {
            throw NSError(domain: "WAVReader", code: 5, userInfo: [NSLocalizedDescriptionKey: "Data chunk extends beyond file"])
        }

        // Read samples
        let sampleCount = Int(dataSize) / 2
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let byteIdx = dataStart + (i * 2)
            let low = UInt16(bytes[byteIdx])
            let high = UInt16(bytes[byteIdx + 1])
            let val = (high << 8) | low
            samples.append(Int16(bitPattern: val))
        }

        return samples
    }
}
