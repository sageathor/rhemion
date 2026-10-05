/// Target PCM format for recognition and the fallback WAV: 16 kHz, mono, signed 16-bit.
public enum AudioFormat {
    public static let sampleRate: UInt32 = 16000
    public static let channels: UInt16 = 1
    public static let bitsPerSample: UInt16 = 16
}
