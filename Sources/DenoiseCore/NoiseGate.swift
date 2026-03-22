import Foundation
import AVFoundation

/// Simple noise gate that mutes audio below a threshold
public final class NoiseGate: @unchecked Sendable {
    public var thresholdDB: Float = -40.0
    public var attackTime: Float = 0.001   // seconds
    public var releaseTime: Float = 0.05   // seconds
    public var isEnabled: Bool = true

    private var envelope: Float = 0.0

    public init(thresholdDB: Float = -40.0) {
        self.thresholdDB = thresholdDB
    }

    /// Process audio buffer in-place
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Float) {
        guard isEnabled else { return }

        let threshold = powf(10.0, thresholdDB / 20.0)
        let attackCoeff = expf(-1.0 / (attackTime * sampleRate))
        let releaseCoeff = expf(-1.0 / (releaseTime * sampleRate))

        for i in 0..<frameCount {
            let inputLevel = fabsf(buffer[i])

            if inputLevel > envelope {
                envelope = attackCoeff * envelope + (1.0 - attackCoeff) * inputLevel
            } else {
                envelope = releaseCoeff * envelope + (1.0 - releaseCoeff) * inputLevel
            }

            if envelope < threshold {
                buffer[i] = 0.0
            }
        }
    }
}
