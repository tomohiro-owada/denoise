import Foundation
import AVFoundation
import CoreAudio
import Accelerate

/// Thread-safe ring buffer for passing audio between input and output engines
private final class AudioRingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<count {
            buffer[writeIndex % capacity] = data[i]
            writeIndex += 1
        }
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = writeIndex - readIndex
        let toRead = min(count, available)
        for i in 0..<toRead {
            data[i] = buffer[readIndex % capacity]
            readIndex += 1
        }
        if toRead < count {
            for i in toRead..<count { data[i] = 0 }
        }
        return toRead
    }
}

/// Two-engine audio pipeline:
///   inputEngine:  Mic → tap → [DeClicker → NoiseGate → RNNoise] → RingBuffer
///   outputEngine: RingBuffer → SourceNode → EQ → Compressor → (Delay) → virtual device / speakers
public final class AudioProcessor: ObservableObject {
    private var inputEngine: AVAudioEngine!
    private var outputEngine: AVAudioEngine!
    private var eq: AVAudioUnitEQ!
    private var compressor: AVAudioUnitEffect!
    private var sourceNode: AVAudioSourceNode!
    private var delayNode: AVAudioUnitDelay!
    private var ringBuffer: AudioRingBuffer!
    private let deClicker = DeClicker()
    private let noiseGate = NoiseGate()
    private let rnnoise = RNNoiseProcessor()

    @Published public var isRunning = false
    @Published public var isMonitorMode = false
    @Published public var inputLevel: Float = 0.0
    @Published public var outputLevel: Float = 0.0

    @Published public var deClickerEnabled: Bool = true {
        didSet { deClicker.isEnabled = deClickerEnabled }
    }
    @Published public var deClickerSensitivity: Float = 4.0 {
        didSet { deClicker.sensitivity = deClickerSensitivity }
    }
    @Published public var noiseGateEnabled: Bool = true {
        didSet { noiseGate.isEnabled = noiseGateEnabled }
    }
    @Published public var noiseGateThreshold: Float = -40.0 {
        didSet { noiseGate.thresholdDB = noiseGateThreshold }
    }
    @Published public var eqEnabled: Bool = true
    @Published public var compressorEnabled: Bool = true
    @Published public var rnnoiseEnabled: Bool = true
    @Published public var eqLowGain: Float = 0.0
    @Published public var eqMidGain: Float = 0.0
    @Published public var eqHighGain: Float = 0.0
    @Published public var compressorThreshold: Float = -20.0
    @Published public var compressorRatio: Float = 4.0
    @Published public var monitorDelaySeconds: Float = 1.0

    private var rnnoiseBuffer: [Float] = []
    private let rnnoiseFrameSize: Int

    public init() {
        rnnoiseFrameSize = rnnoise.frameSize
    }

    // MARK: - EQ / Compressor setup

    private func setupEQBands() {
        let bands = eq.bands
        bands[0].filterType = .lowShelf;  bands[0].frequency = 200;  bands[0].gain = eqLowGain;  bands[0].bypass = false
        bands[1].filterType = .parametric; bands[1].frequency = 1000; bands[1].bandwidth = 1.0; bands[1].gain = eqMidGain; bands[1].bypass = false
        bands[2].filterType = .highShelf; bands[2].frequency = 4000; bands[2].gain = eqHighGain; bands[2].bypass = false
        eq.bypass = !eqEnabled
    }

    private func setupCompressorParams() {
        let au = compressor.audioUnit
        let headRoom = max(0.1, abs(compressorThreshold) / max(compressorRatio, 1.0))
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, compressorThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, headRoom, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2.0, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 5.0, 0)
        compressor.bypass = !compressorEnabled
    }

    public func updateEQ() {
        guard let eq = eq else { return }
        eq.bands[0].gain = eqLowGain; eq.bands[1].gain = eqMidGain; eq.bands[2].gain = eqHighGain
        eq.bypass = !eqEnabled
    }

    public func updateCompressor() {
        guard let compressor = compressor else { return }
        let au = compressor.audioUnit
        let headRoom = max(0.1, abs(compressorThreshold) / max(compressorRatio, 1.0))
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, compressorThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, headRoom, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 5.0, 0)
        compressor.bypass = !compressorEnabled
    }

    // MARK: - Start / Stop

    public func start(inputDeviceID: AudioDeviceID? = nil, monitor: Bool = false) throws {
        if isRunning { stop() }

        // --- Input Engine: captures mic, processes, writes to ring buffer ---
        inputEngine = AVAudioEngine()

        let inputNode = inputEngine.inputNode

        if let deviceID = inputDeviceID {
            try setDevice(deviceID, onNode: inputNode, isInput: true)
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = hwFormat.sampleRate

        // Find virtual device (needed for both engines in non-monitor mode)
        var virtualID: AudioDeviceID?
        if !monitor {
            guard let vid = VirtualDeviceInstaller.findVirtualDevice() else {
                throw DenoiseError.virtualDeviceNotFound
            }
            virtualID = vid
        }

        // inputEngine needs a minimal graph for tap to work.
        // Mute output completely so nothing leaks to speakers.
        inputEngine.connect(inputNode, to: inputEngine.mainMixerNode, format: hwFormat)
        inputEngine.mainMixerNode.outputVolume = 0
        // Also mute via AudioUnit to guarantee silence
        if let au = inputEngine.outputNode.audioUnit {
            AudioUnitSetParameter(au, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, 0, 0)
        }

        // Ring buffer
        ringBuffer = AudioRingBuffer(capacity: Int(sampleRate) * 2)
        rnnoiseBuffer.removeAll()

        // --- Output Engine: reads ring buffer, applies EQ/compressor, outputs to virtual device ---
        outputEngine = AVAudioEngine()

        if let vid = virtualID {
            try setDevice(vid, onNode: outputEngine.outputNode, isInput: false)
        }

        let processingFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        eq = AVAudioUnitEQ(numberOfBands: 3)
        let compressorDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        compressor = AVAudioUnitEffect(audioComponentDescription: compressorDesc)

        let rb = ringBuffer!
        sourceNode = AVAudioSourceNode(format: processingFormat) { _, _, frameCount, bufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            for buf in ablPointer {
                let ptr = buf.mData!.assumingMemoryBound(to: Float.self)
                _ = rb.read(ptr, count: Int(frameCount))
            }
            return noErr
        }

        outputEngine.attach(sourceNode)
        outputEngine.attach(eq)
        outputEngine.attach(compressor)

        outputEngine.connect(sourceNode, to: eq, format: processingFormat)
        outputEngine.connect(eq, to: compressor, format: processingFormat)

        if monitor {
            delayNode = AVAudioUnitDelay()
            delayNode.delayTime = TimeInterval(monitorDelaySeconds)
            delayNode.feedback = 0; delayNode.wetDryMix = 100
            outputEngine.attach(delayNode)
            outputEngine.connect(compressor, to: delayNode, format: processingFormat)
            outputEngine.connect(delayNode, to: outputEngine.mainMixerNode, format: processingFormat)
        } else {
            delayNode = nil
            outputEngine.connect(compressor, to: outputEngine.mainMixerNode, format: processingFormat)
        }

        // --- Install tap on inputEngine's inputNode ---
        let deClicker = self.deClicker
        let noiseGate = self.noiseGate
        let rnnoise = self.rnnoise
        let frameSize = self.rnnoiseFrameSize
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: hwFormat.channelCount)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            let sr = Float(buffer.format.sampleRate)

            // Downmix to mono
            var mono = [Float](repeating: 0, count: frameCount)
            if channels == 1 {
                memcpy(&mono, channelData[0], frameCount * MemoryLayout<Float>.size)
            } else {
                for ch in 0..<channels {
                    for i in 0..<frameCount { mono[i] += channelData[ch][i] }
                }
                let scale = 1.0 / Float(channels)
                for i in 0..<frameCount { mono[i] *= scale }
            }

            // Input level
            var rms: Float = 0
            vDSP_measqv(mono, 1, &rms, vDSP_Length(frameCount))
            DispatchQueue.main.async { self.inputLevel = sqrtf(rms) }

            // DeClicker
            if self.deClickerEnabled {
                mono.withUnsafeMutableBufferPointer { ptr in
                    deClicker.process(ptr.baseAddress!, frameCount: frameCount)
                }
            }

            // Noise gate
            if self.noiseGateEnabled {
                mono.withUnsafeMutableBufferPointer { ptr in
                    noiseGate.process(ptr.baseAddress!, frameCount: frameCount, sampleRate: sr)
                }
            }

            // RNNoise
            if self.rnnoiseEnabled {
                self.applyRNNoise(&mono, rnnoise: rnnoise, frameSize: frameSize)
            }

            // Output level
            var outRms: Float = 0
            vDSP_measqv(mono, 1, &outRms, vDSP_Length(frameCount))
            DispatchQueue.main.async { self.outputLevel = sqrtf(outRms) }

            // Write to ring buffer
            mono.withUnsafeBufferPointer { ptr in
                rb.write(ptr.baseAddress!, count: frameCount)
            }
        }

        // Start both engines
        try inputEngine.start()
        try outputEngine.start()

        setupEQBands()
        setupCompressorParams()

        isRunning = true
        isMonitorMode = monitor
    }

    private func applyRNNoise(_ mono: inout [Float], rnnoise: RNNoiseProcessor, frameSize: Int) {
        for i in 0..<mono.count {
            rnnoiseBuffer.append(mono[i] * 32768.0)
        }
        var outputOffset = 0
        while rnnoiseBuffer.count >= frameSize && outputOffset < mono.count {
            var frame = Array(rnnoiseBuffer.prefix(frameSize))
            rnnoiseBuffer.removeFirst(frameSize)
            rnnoise.processFrame(&frame)
            let samplesToWrite = min(frameSize, mono.count - outputOffset)
            for j in 0..<samplesToWrite {
                mono[outputOffset + j] = frame[j] / 32768.0
            }
            outputOffset += samplesToWrite
        }
    }

    public func stop() {
        if let ie = inputEngine {
            ie.inputNode.removeTap(onBus: 0)
            ie.stop()
        }
        if let oe = outputEngine {
            oe.stop()
            if let s = sourceNode { oe.detach(s) }
            if let e = eq { oe.detach(e) }
            if let c = compressor { oe.detach(c) }
            if let d = delayNode { oe.detach(d) }
        }
        inputEngine = nil
        outputEngine = nil
        sourceNode = nil; eq = nil; compressor = nil; delayNode = nil
        ringBuffer = nil
        rnnoiseBuffer.removeAll()
        isRunning = false
        isMonitorMode = false
        inputLevel = 0; outputLevel = 0
    }

    // MARK: - Device helpers

    private func setDevice(_ deviceID: AudioDeviceID, onNode node: AVAudioIONode, isInput: Bool) throws {
        var deviceID = deviceID
        let audioUnit = node.audioUnit!
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw DenoiseError.audioEngineError("Failed to set \(isInput ? "input" : "output") device: \(status)")
        }
    }

    public func getSettings() -> [String: Any] {
        return [
            "isRunning": isRunning,
            "isMonitorMode": isMonitorMode,
            "deClicker": ["enabled": deClickerEnabled, "sensitivity": deClickerSensitivity],
            "noiseGate": ["enabled": noiseGateEnabled, "threshold": noiseGateThreshold],
            "eq": ["enabled": eqEnabled, "lowGain": eqLowGain, "midGain": eqMidGain, "highGain": eqHighGain],
            "compressor": ["enabled": compressorEnabled, "threshold": compressorThreshold, "ratio": compressorRatio],
            "rnnoise": ["enabled": rnnoiseEnabled],
            "monitorDelay": monitorDelaySeconds,
        ]
    }
}
