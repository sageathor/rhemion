import CoreAudio
import Foundation

public enum CoreAudioDeviceEnumerator {
    public static func inputDevices() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { deviceID in
            let channelCount = inputChannelCount(deviceID)
            guard channelCount > 0 else {
                return nil
            }

            let transportType = integerProperty(deviceID, selector: kAudioDevicePropertyTransportType) ?? 0

            return AudioDeviceInfo(
                id: deviceID,
                uid: stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "",
                modelUID: stringProperty(deviceID, selector: kAudioDevicePropertyModelUID),
                name: stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "",
                manufacturer: stringProperty(deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString),
                transportType: transportType,
                inputChannelCount: channelCount,
                isAlive: (integerProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0,
                isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    public static func systemDefaultInputID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize >= MemoryLayout<AudioDeviceID>.size else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = devices.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return OSStatus(kAudioHardwareUnspecifiedError)
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard dataStatus == noErr else {
            return []
        }

        let returnedCount = min(devices.count, Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        return Array(devices.prefix(returnedCount))
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= MemoryLayout<AudioBufferList>.size else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            storage
        )
        guard dataStatus == noErr else {
            return 0
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        storage.initialize(to: nil)
        defer {
            storage.deinitialize(count: 1)
            storage.deallocate()
        }

        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage)

        // AudioObjectGetPropertyData returns a CFString the caller owns (Create Rule);
        // takeRetainedValue consumes that +1 so it is not leaked.
        guard status == noErr, let value = storage.pointee?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    private static func integerProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value : nil
    }
}
