import Foundation
import AVFoundation
import CoreAudio
import Accelerate

/// Thread-safe ring buffer for passing audio between tap and source node
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
        // Zero-fill if not enough data
        if toRead < count {
            for i in toRead..<count {
                data[i] = 0
            }
        }
        return toRead
    }
}

/// Main audio processing pipeline:
/// Mic --(tap)--> [NoiseGate + RNNoise] --> RingBuffer --> SourceNode --> EQ --> Compressor --> Output
public final class AudioProcessor: ObservableObject {
    private var engine: AVAudioEngine!
    private var eq: AVAudioUnitEQ!
    private var compressor: AVAudioUnitEffect!
    private var sourceNode: AVAudioSourceNode!
    private var delayNode: AVAudioUnitDelay!
    private var ringBuffer: AudioRingBuffer!
    private let noiseGate = NoiseGate()
    private let rnnoise = RNNoiseProcessor()

    @Published public var isRunning = false
    @Published public var isMonitorMode = false
    @Published public var inputLevel: Float = 0.0
    @Published public var outputLevel: Float = 0.0

    // Settings
    @Published public var noiseGateEnabled: Bool = true {
        didSet { noiseGate.isEnabled = noiseGateEnabled }
    }
    @Published public var noiseGateThreshold: Float = -40.0 {
        didSet { noiseGate.thresholdDB = noiseGateThreshold }
    }
    @Published public var eqEnabled: Bool = true
    @Published public var compressorEnabled: Bool = true
    @Published public var rnnoiseEnabled: Bool = true

    // EQ bands
    @Published public var eqLowGain: Float = 0.0
    @Published public var eqMidGain: Float = 0.0
    @Published public var eqHighGain: Float = 0.0

    // Compressor
    @Published public var compressorThreshold: Float = -20.0
    @Published public var compressorRatio: Float = 4.0

    // Monitor delay
    @Published public var monitorDelaySeconds: Float = 1.0

    // RNNoise buffer management
    private var rnnoiseBuffer: [Float] = []
    private let rnnoiseFrameSize: Int

    public init() {
        rnnoiseFrameSize = rnnoise.frameSize
    }

    private func setupEQBands() {
        let bands = eq.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 200
        bands[0].gain = eqLowGain
        bands[0].bypass = false
        bands[1].filterType = .parametric
        bands[1].frequency = 1000
        bands[1].bandwidth = 1.0
        bands[1].gain = eqMidGain
        bands[1].bypass = false
        bands[2].filterType = .highShelf
        bands[2].frequency = 4000
        bands[2].gain = eqHighGain
        bands[2].bypass = false
        eq.bypass = !eqEnabled
    }

    private func setupCompressorParams() {
        let au = compressor.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, compressorThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, 20.0 - compressorRatio), 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.1, 0)
        compressor.bypass = !compressorEnabled
    }

    public func updateEQ() {
        guard let eq = eq else { return }
        eq.bands[0].gain = eqLowGain
        eq.bands[1].gain = eqMidGain
        eq.bands[2].gain = eqHighGain
        eq.bypass = !eqEnabled
    }

    public func updateCompressor() {
        guard let compressor = compressor else { return }
        let au = compressor.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, compressorThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, 20.0 - compressorRatio), 0)
        compressor.bypass = !compressorEnabled
    }

    /// Start audio processing.
    public func start(inputDeviceID: AudioDeviceID? = nil, monitor: Bool = false) throws {
        if isRunning { stop() }

        engine = AVAudioEngine()

        if !monitor {
            guard let blackHoleID = VirtualDeviceInstaller.findVirtualDevice() else {
                throw DenoiseError.virtualDeviceNotFound
            }
            try setOutputDevice(blackHoleID)
        }

        let inputNode = engine.inputNode

        if let deviceID = inputDeviceID {
            try setInputDevice(deviceID)
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = hwFormat.sampleRate
        let processingFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!

        // Ring buffer: 2 seconds worth of audio
        ringBuffer = AudioRingBuffer(capacity: Int(sampleRate) * 2)
        rnnoiseBuffer.removeAll()

        // Create processing nodes
        eq = AVAudioUnitEQ(numberOfBands: 3)

        let compressorDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        compressor = AVAudioUnitEffect(audioComponentDescription: compressorDesc)

        // Source node reads from ring buffer
        let rb = ringBuffer!
        sourceNode = AVAudioSourceNode(format: processingFormat) { _, _, frameCount, bufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            for buf in ablPointer {
                let ptr = buf.mData!.assumingMemoryBound(to: Float.self)
                rb.read(ptr, count: Int(frameCount))
            }
            return noErr
        }

        // Sink mixer: connects inputNode to the graph so the tap fires,
        // but volume=0 so raw audio doesn't leak to output
        let sinkMixer = AVAudioMixerNode()
        engine.attach(sinkMixer)
        engine.connect(inputNode, to: sinkMixer, format: hwFormat)
        engine.connect(sinkMixer, to: engine.mainMixerNode, format: hwFormat)
        sinkMixer.outputVolume = 0

        // Attach processing nodes
        engine.attach(sourceNode)
        engine.attach(eq)
        engine.attach(compressor)

        // Chain: sourceNode → EQ → compressor → (delay?) → mainMixer → output
        engine.connect(sourceNode, to: eq, format: processingFormat)
        engine.connect(eq, to: compressor, format: processingFormat)

        if monitor {
            delayNode = AVAudioUnitDelay()
            delayNode.delayTime = TimeInterval(monitorDelaySeconds)
            delayNode.feedback = 0
            delayNode.wetDryMix = 100
            engine.attach(delayNode)
            engine.connect(compressor, to: delayNode, format: processingFormat)
            engine.connect(delayNode, to: engine.mainMixerNode, format: processingFormat)
        } else {
            delayNode = nil
            engine.connect(compressor, to: engine.mainMixerNode, format: processingFormat)
        }

        // Install tap on inputNode: capture → process → ring buffer
        let noiseGate = self.noiseGate
        let rnnoise = self.rnnoise
        let frameSize = self.rnnoiseFrameSize
        // Tap format must match HW format; we downmix to mono in the callback
        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: hwFormat.channelCount
        )!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            let sr = Float(buffer.format.sampleRate)

            // Downmix to mono into a temp buffer
            var mono = [Float](repeating: 0, count: frameCount)
            if channels == 1 {
                memcpy(&mono, channelData[0], frameCount * MemoryLayout<Float>.size)
            } else {
                // Average all channels
                for ch in 0..<channels {
                    for i in 0..<frameCount {
                        mono[i] += channelData[ch][i]
                    }
                }
                let scale = 1.0 / Float(channels)
                for i in 0..<frameCount {
                    mono[i] *= scale
                }
            }

            // Input level
            var rms: Float = 0
            vDSP_measqv(mono, 1, &rms, vDSP_Length(frameCount))
            rms = sqrtf(rms)
            DispatchQueue.main.async { self.inputLevel = rms }

            // Noise gate (in-place)
            if self.noiseGateEnabled {
                mono.withUnsafeMutableBufferPointer { ptr in
                    noiseGate.process(ptr.baseAddress!, frameCount: frameCount, sampleRate: sr)
                }
            }

            // RNNoise (in-place)
            if self.rnnoiseEnabled {
                self.applyRNNoise(&mono, rnnoise: rnnoise, frameSize: frameSize)
            }

            // Output level
            var outRms: Float = 0
            vDSP_measqv(mono, 1, &outRms, vDSP_Length(frameCount))
            outRms = sqrtf(outRms)
            DispatchQueue.main.async { self.outputLevel = outRms }

            // Write processed mono to ring buffer
            mono.withUnsafeBufferPointer { ptr in
                rb.write(ptr.baseAddress!, count: frameCount)
            }
        }

        try engine.start()

        // Apply EQ/compressor params after engine is running
        setupEQBands()
        setupCompressorParams()

        isRunning = true
        isMonitorMode = monitor
    }

    private func applyRNNoise(_ mono: inout [Float], rnnoise: RNNoiseProcessor, frameSize: Int) {
        // RNNoise expects [-32768, 32767] scaled samples
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
        guard let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let s = sourceNode { engine.detach(s) }
        if let e = eq { engine.detach(e) }
        if let c = compressor { engine.detach(c) }
        if let d = delayNode { engine.detach(d) }
        sourceNode = nil
        eq = nil
        compressor = nil
        delayNode = nil
        ringBuffer = nil
        self.engine = nil
        rnnoiseBuffer.removeAll()
        isRunning = false
        isMonitorMode = false
        inputLevel = 0
        outputLevel = 0
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        let audioUnit = engine.inputNode.audioUnit!
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw DenoiseError.audioEngineError("Failed to set input device: \(status)")
        }
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        let audioUnit = engine.outputNode.audioUnit!
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw DenoiseError.audioEngineError("Failed to set output device: \(status)")
        }
    }

    public func getSettings() -> [String: Any] {
        return [
            "isRunning": isRunning,
            "isMonitorMode": isMonitorMode,
            "noiseGate": [
                "enabled": noiseGateEnabled,
                "threshold": noiseGateThreshold,
            ],
            "eq": [
                "enabled": eqEnabled,
                "lowGain": eqLowGain,
                "midGain": eqMidGain,
                "highGain": eqHighGain,
            ],
            "compressor": [
                "enabled": compressorEnabled,
                "threshold": compressorThreshold,
                "ratio": compressorRatio,
            ],
            "rnnoise": [
                "enabled": rnnoiseEnabled,
            ],
            "monitorDelay": monitorDelaySeconds,
        ]
    }
}
