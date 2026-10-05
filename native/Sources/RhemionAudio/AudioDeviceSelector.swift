import CoreAudio
import Foundation

public struct AudioDeviceInfo: Equatable, Sendable {
    public let id: UInt32
    public let uid: String
    public let modelUID: String?
    public let name: String
    public let manufacturer: String?
    public let transportType: UInt32
    public let inputChannelCount: UInt32
    public let isAlive: Bool
    public let isBuiltIn: Bool

    public init(id: UInt32, uid: String, modelUID: String?, name: String = "", manufacturer: String? = nil,
                transportType: UInt32 = 0, inputChannelCount: UInt32 = 1, isAlive: Bool, isBuiltIn: Bool) {
        self.id = id; self.uid = uid; self.modelUID = modelUID; self.name = name
        self.manufacturer = manufacturer; self.transportType = transportType
        self.inputChannelCount = inputChannelCount; self.isAlive = isAlive; self.isBuiltIn = isBuiltIn
    }

    public var isContinuity: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired ||
            transportType == kAudioDeviceTransportTypeContinuityCaptureWireless ||
            identityContains("continuity") || identityContains("iphone")
    }

    public var isVirtualOrAggregate: Bool {
        if transportType == kAudioDeviceTransportTypeAggregate || transportType == kAudioDeviceTransportTypeVirtual { return true }
        return ["aggregate", "virtual", "blackhole", "soundflower", "loopback"].contains { identityContains($0) }
    }

    public var exclusionReason: String? {
        if inputChannelCount == 0 { return "no input channels" }
        if !isAlive { return "device is not alive" }
        if uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missing device UID" }
        if isContinuity { return "Continuity/iPhone input" }
        if isVirtualOrAggregate { return "virtual/aggregate device" }
        if transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return "Bluetooth input (set a specific UID to use it)"
        }
        return nil
    }

    public var isAutoEligible: Bool { exclusionReason == nil }

    public var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeDisplayPort: return "display-port"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAVB: return "avb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuity-wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity-wireless"
        default: return String(format: "0x%08X", transportType)
        }
    }

    private var identityText: String {
        [uid, modelUID, manufacturer, name].compactMap { $0?.lowercased() }.joined(separator: " ")
    }
    private func identityContains(_ value: String) -> Bool { identityText.contains(value) }
}

public enum InputMode: Equatable, Sendable {
    case auto
    case systemDefault
    case specific(uid: String, modelUID: String?)
    case prioritized([String])
}

public enum AudioDeviceSelector {
    public static func select(mode: InputMode, devices: [AudioDeviceInfo], systemDefaultID: UInt32?) -> AudioDeviceInfo? {
        rank(mode: mode, devices: devices, systemDefaultID: systemDefaultID).first
    }

    public static func rank(mode: InputMode, devices: [AudioDeviceInfo], systemDefaultID: UInt32?) -> [AudioDeviceInfo] {
        let liveInputs = devices.filter { $0.isAlive && $0.inputChannelCount > 0 }
        switch mode {
        case .auto:
            let eligible = liveInputs.filter(\.isAutoEligible)
            let defaultDevice = eligible.first { $0.id == systemDefaultID }
            let builtIn = eligible.filter(\.isBuiltIn)
            let physical = eligible.filter { !$0.isBuiltIn }
            return unique(([defaultDevice].compactMap { $0 }) + builtIn + physical)
        case .systemDefault:
            return fallbackRank(liveInputs, preferred: liveInputs.first { $0.id == systemDefaultID })
        case .specific(let uid, let modelUID):
            let exact = liveInputs.first { $0.uid == uid && (modelUID == nil || $0.modelUID == modelUID) }
            let rebound = modelUID.flatMap { model in liveInputs.first { $0.modelUID == model } }
            return fallbackRank(liveInputs, preferred: exact ?? rebound)
        case .prioritized(let uids):
            let preferred = uids.compactMap { uid in liveInputs.first { $0.uid == uid } }
            return unique(preferred + fallbackRank(liveInputs, preferred: nil))
        }
    }

    public static func firstPrepared<T>(candidates: [AudioDeviceInfo], prepare: (AudioDeviceInfo) throws -> T,
                                         onFailure: (AudioDeviceInfo, Error) -> Void = { _, _ in }) -> (device: AudioDeviceInfo, value: T)? {
        for device in candidates {
            do { return (device, try prepare(device)) }
            catch { onFailure(device, error) }
        }
        return nil
    }

    private static func fallbackRank(_ devices: [AudioDeviceInfo], preferred: AudioDeviceInfo?) -> [AudioDeviceInfo] {
        unique(([preferred].compactMap { $0 }) + devices.filter(\.isBuiltIn) + devices)
    }
    private static func unique(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        var seen = Set<UInt32>()
        return devices.filter { seen.insert($0.id).inserted }
    }
}
