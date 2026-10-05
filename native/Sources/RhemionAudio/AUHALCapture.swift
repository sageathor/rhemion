import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public final class AUHALCapture: CaptureEngine, LiveCaptureRetargeting, @unchecked Sendable {
    private static let handoffSlotCount: UInt64 = 96

    private var deviceID: AudioDeviceID
    private let stateLock = NSLock()
    private let drainQueue = DispatchQueue(label: "RhemionAudio.AUHALCapture.drain")

    private var audioUnit: AudioUnit?
    private var renderStorage: UnsafeMutablePointer<Float>?
    private var renderBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var handoffStorage: UnsafeMutablePointer<Float>?
    private var slotSampleCounts: UnsafeMutablePointer<UInt32>?
    private var maxFrames: UInt32 = 0
    private var deviceChannels: UInt32 = 0
    private var deviceSampleRate: Double = 0
    private var sink: FrameSink?

    private let active = Atomic<Bool>(false)
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let drainScheduled = Atomic<Bool>(false)
    private let droppedFrames = Atomic<UInt64>(0)
    private let callbacksInFlight = Atomic<UInt32>(0)

    public init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    deinit {
        teardown()
    }

    public func prepare() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard audioUnit == nil else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw makeError(kAudio_ParamError, operation: "find AUHAL component")
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), operation: "create AUHAL instance")
        guard let unit = newUnit else {
            throw makeError(kAudio_ParamError, operation: "create AUHAL instance")
        }

        do {
            var enabled: UInt32 = 1
            try withUnsafePointer(to: &enabled) {
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Input,
                        1,
                        $0,
                        UInt32(MemoryLayout<UInt32>.size)
                    ),
                    operation: "enable AUHAL input"
                )
            }

            var disabled: UInt32 = 0
            try withUnsafePointer(to: &disabled) {
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Output,
                        0,
                        $0,
                        UInt32(MemoryLayout<UInt32>.size)
                    ),
                    operation: "disable AUHAL output"
                )
            }

            var selectedDevice = deviceID
            try withUnsafePointer(to: &selectedDevice) {
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        $0,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    ),
                    operation: "select input device"
                )
            }

            var deviceFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1,
                    &deviceFormat,
                    &formatSize
                ),
                operation: "read device input format"
            )
            guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
                throw makeError(kAudio_ParamError, operation: "validate device input format")
            }

            let channels = deviceFormat.mChannelsPerFrame
            var clientFormat = AudioStreamBasicDescription(
                mSampleRate: deviceFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try withUnsafePointer(to: &clientFormat) {
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Output,
                        1,
                        $0,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ),
                    operation: "set AUHAL client format"
                )
            }

            var frameCapacity: UInt32 = 0
            var frameCapacitySize = UInt32(MemoryLayout<UInt32>.size)
            try check(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &frameCapacity,
                    &frameCapacitySize
                ),
                operation: "read maximum frames per slice"
            )
            guard frameCapacity > 0 else {
                throw makeError(kAudio_ParamError, operation: "validate maximum frames per slice")
            }

            let samplesPerSlot = Int(frameCapacity) * Int(channels)
            let newRenderStorage = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerSlot)
            let newHandoffStorage = UnsafeMutablePointer<Float>.allocate(
                capacity: samplesPerSlot * Int(Self.handoffSlotCount)
            )
            let newSlotSampleCounts = UnsafeMutablePointer<UInt32>.allocate(
                capacity: Int(Self.handoffSlotCount)
            )
            let newBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            newBufferList.initialize(to: AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(samplesPerSlot * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(newRenderStorage)
                )
            ))

            renderStorage = newRenderStorage
            handoffStorage = newHandoffStorage
            slotSampleCounts = newSlotSampleCounts
            renderBufferList = newBufferList
            maxFrames = frameCapacity
            deviceChannels = channels
            deviceSampleRate = deviceFormat.mSampleRate
            audioUnit = unit

            var callback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try withUnsafePointer(to: &callback) {
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_SetInputCallback,
                        kAudioUnitScope_Global,
                        0,
                        $0,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                    ),
                    operation: "install AUHAL input callback"
                )
            }

            try check(AudioUnitInitialize(unit), operation: "initialize AUHAL")
        } catch {
            releaseBuffers()
            audioUnit = nil
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    public func start(sink: FrameSink) throws {
        try prepare()

        stateLock.lock()
        defer { stateLock.unlock() }
        guard let unit = audioUnit else {
            throw makeError(kAudio_ParamError, operation: "start unprepared AUHAL")
        }

        active.store(false, ordering: .releasing)
        drainQueue.sync {
            self.sink = sink
            writeIndex.store(0, ordering: .releasing)
            readIndex.store(0, ordering: .releasing)
            drainScheduled.store(false, ordering: .releasing)
        }
        active.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            active.store(false, ordering: .releasing)
            drainQueue.sync { self.sink = nil }
            throw makeError(status, operation: "start AUHAL")
        }
    }

    public func stop() {
        stateLock.lock()
        active.store(false, ordering: .releasing)
        let unit = audioUnit
        if let unit {
            AudioOutputUnitStop(unit)
        }
        drainQueue.sync {
            drainPublishedFrames()
            sink = nil
        }
        stateLock.unlock()
    }

    /// Retargets a running AUHAL while preserving the current FrameSink. This is intentionally
    /// not used by dictation: it is groundwork for call recording, whose owner must decide how
    /// to represent the unavoidable gap and whether/how to stitch partial audio across it.
    ///
    /// The state lock serializes start/stop/teardown/retarget. `active` first closes the render
    /// gate, then the in-flight counter lets us prove no callback still references old buffers
    /// before they are drained and replaced.
    public func retarget(to newDeviceID: AudioDeviceID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard newDeviceID != deviceID else { return }
        guard active.load(ordering: .acquiring), let unit = audioUnit else {
            throw makeError(kAudioUnitErr_Uninitialized, operation: "retarget inactive AUHAL")
        }

        active.store(false, ordering: .releasing)
        try check(AudioOutputUnitStop(unit), operation: "stop AUHAL for device retarget")
        waitForRenderCallbacks()
        drainQueue.sync { drainPublishedFrames() }
        try check(AudioUnitUninitialize(unit), operation: "uninitialize AUHAL for device retarget")

        var selectedDevice = newDeviceID
        try withUnsafePointer(to: &selectedDevice) {
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    $0, UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                operation: "select retarget input device"
            )
        }

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &deviceFormat, &formatSize
            ),
            operation: "read retarget device input format"
        )
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            throw makeError(kAudio_ParamError, operation: "validate retarget device input format")
        }

        let channels = deviceFormat.mChannelsPerFrame
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try withUnsafePointer(to: &clientFormat) {
            try check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                    $0, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: "set retarget AUHAL client format"
            )
        }

        var frameCapacity: UInt32 = 0
        var frameCapacitySize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &frameCapacity, &frameCapacitySize
            ),
            operation: "read retarget maximum frames per slice"
        )
        guard frameCapacity > 0 else {
            throw makeError(kAudio_ParamError, operation: "validate retarget maximum frames per slice")
        }

        releaseBuffers()
        allocateBuffers(frameCapacity: frameCapacity, channels: channels)
        deviceSampleRate = deviceFormat.mSampleRate
        deviceID = newDeviceID

        try check(AudioUnitInitialize(unit), operation: "initialize retargeted AUHAL")
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            throw makeError(startStatus, operation: "start retargeted AUHAL")
        }
        active.store(true, ordering: .releasing)
    }

    public func teardown() {
        stateLock.lock()
        active.store(false, ordering: .releasing)
        guard let unit = audioUnit else {
            stateLock.unlock()
            return
        }

        AudioOutputUnitStop(unit)
        drainQueue.sync {
            drainPublishedFrames()
            sink = nil
        }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        releaseBuffers()
        stateLock.unlock()
    }

    private static let inputCallback: AURenderCallback = {
        refCon, actionFlags, timeStamp, _, frameCount, _ in
        let capture = Unmanaged<AUHALCapture>.fromOpaque(refCon).takeUnretainedValue()
        return capture.render(
            actionFlags: actionFlags,
            timeStamp: timeStamp,
            frameCount: frameCount
        )
    }

    private func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        callbacksInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer { callbacksInFlight.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
        guard active.load(ordering: .acquiring) else { return noErr }
        guard
            frameCount <= maxFrames,
            let unit = audioUnit,
            let bufferList = renderBufferList,
            let source = renderStorage,
            let handoffStorage,
            let slotSampleCounts
        else {
            droppedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            return kAudio_ParamError
        }

        let sampleCount = Int(frameCount) * Int(deviceChannels)
        bufferList.pointee.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, actionFlags, timeStamp, 1, frameCount, bufferList)
        guard status == noErr else { return status }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write &- read < Self.handoffSlotCount else {
            droppedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            return noErr
        }

        let samplesPerSlot = Int(maxFrames) * Int(deviceChannels)
        let slot = Int(write % Self.handoffSlotCount)
        handoffStorage.advanced(by: slot * samplesPerSlot).update(from: source, count: sampleCount)
        slotSampleCounts[slot] = UInt32(sampleCount)
        writeIndex.store(write &+ 1, ordering: .releasing)

        if drainScheduled.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged {
            drainQueue.async { [self] in
                drainHandoff()
            }
        }
        return noErr
    }

    private func drainHandoff() {
        while true {
            drainPublishedFrames()
            drainScheduled.store(false, ordering: .releasing)

            guard readIndex.load(ordering: .relaxed) != writeIndex.load(ordering: .acquiring) else {
                return
            }
            guard drainScheduled.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
            ).exchanged else {
                return
            }
        }
    }

    private func drainPublishedFrames() {
        guard let handoffStorage, let slotSampleCounts else { return }
        let samplesPerSlot = Int(maxFrames) * Int(deviceChannels)

        while true {
            let read = readIndex.load(ordering: .relaxed)
            let write = writeIndex.load(ordering: .acquiring)
            guard read != write else { return }

            let slot = Int(read % Self.handoffSlotCount)
            let sampleCount = Int(slotSampleCounts[slot])
            let slotStart = handoffStorage.advanced(by: slot * samplesPerSlot)
            let frames = Array(UnsafeBufferPointer(start: slotStart, count: sampleCount))
            sink?.ingest(frames, channels: Int(deviceChannels), sampleRate: deviceSampleRate)
            readIndex.store(read &+ 1, ordering: .releasing)
        }
    }

    private func releaseBuffers() {
        renderBufferList?.deinitialize(count: 1)
        renderBufferList?.deallocate()
        renderBufferList = nil
        renderStorage?.deallocate()
        renderStorage = nil
        handoffStorage?.deallocate()
        handoffStorage = nil
        slotSampleCounts?.deallocate()
        slotSampleCounts = nil
        maxFrames = 0
        deviceChannels = 0
        deviceSampleRate = 0
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        drainScheduled.store(false, ordering: .releasing)
    }

    private func allocateBuffers(frameCapacity: UInt32, channels: UInt32) {
        let samplesPerSlot = Int(frameCapacity) * Int(channels)
        renderStorage = .allocate(capacity: samplesPerSlot)
        handoffStorage = .allocate(capacity: samplesPerSlot * Int(Self.handoffSlotCount))
        slotSampleCounts = .allocate(capacity: Int(Self.handoffSlotCount))
        renderBufferList = .allocate(capacity: 1)
        renderBufferList?.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(samplesPerSlot * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(renderStorage)
            )
        ))
        maxFrames = frameCapacity
        deviceChannels = channels
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        drainScheduled.store(false, ordering: .releasing)
    }

    private func waitForRenderCallbacks() {
        while callbacksInFlight.load(ordering: .acquiring) != 0 {
            Thread.sleep(forTimeInterval: 0.0005)
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw makeError(status, operation: operation) }
    }

    private func makeError(_ status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) (OSStatus \(status))."]
        )
    }
}
