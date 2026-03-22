import Foundation

/// Persistent settings stored in UserDefaults
public struct DenoiseSettings: Codable {
    public var inputDeviceUID: String?
    public var deClickerEnabled: Bool = true
    public var deClickerSensitivity: Float = 4.0
    public var noiseGateEnabled: Bool = true
    public var noiseGateThreshold: Float = -45.0
    public var eqEnabled: Bool = true
    public var eqLowGain: Float = 0.0
    public var eqMidGain: Float = 0.0
    public var eqHighGain: Float = 0.0
    public var compressorEnabled: Bool = true
    public var compressorThreshold: Float = -20.0
    public var compressorRatio: Float = 4.0
    public var rnnoiseEnabled: Bool = true
    public var monitorDelaySeconds: Float = 1.0
    public var autoStart: Bool = false

    private static let key = "DenoiseSettings"

    public init() {}

    public static func load() -> DenoiseSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(DenoiseSettings.self, from: data)
        else {
            return DenoiseSettings()
        }
        return settings
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Apply settings to an AudioProcessor
    public func apply(to processor: AudioProcessor) {
        processor.deClickerEnabled = deClickerEnabled
        processor.deClickerSensitivity = deClickerSensitivity
        processor.noiseGateEnabled = noiseGateEnabled
        processor.noiseGateThreshold = noiseGateThreshold
        processor.eqEnabled = eqEnabled
        processor.eqLowGain = eqLowGain
        processor.eqMidGain = eqMidGain
        processor.eqHighGain = eqHighGain
        processor.compressorEnabled = compressorEnabled
        processor.compressorThreshold = compressorThreshold
        processor.compressorRatio = compressorRatio
        processor.rnnoiseEnabled = rnnoiseEnabled
        processor.monitorDelaySeconds = monitorDelaySeconds
        processor.updateEQ()
        processor.updateCompressor()
    }

    /// Update from AudioProcessor current state
    public mutating func update(from processor: AudioProcessor) {
        deClickerEnabled = processor.deClickerEnabled
        deClickerSensitivity = processor.deClickerSensitivity
        noiseGateEnabled = processor.noiseGateEnabled
        noiseGateThreshold = processor.noiseGateThreshold
        eqEnabled = processor.eqEnabled
        eqLowGain = processor.eqLowGain
        eqMidGain = processor.eqMidGain
        eqHighGain = processor.eqHighGain
        compressorEnabled = processor.compressorEnabled
        compressorThreshold = processor.compressorThreshold
        compressorRatio = processor.compressorRatio
        rnnoiseEnabled = processor.rnnoiseEnabled
        monitorDelaySeconds = processor.monitorDelaySeconds
    }
}
