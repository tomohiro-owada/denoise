import Foundation

/// Removes impulsive transient noise (clicks, pops) by detecting sudden spikes
/// and replacing them with interpolated values from surrounding samples.
public final class DeClicker: @unchecked Sendable {
    public var isEnabled: Bool = true
    /// How many times louder than the running average a sample must be to count as a click
    public var sensitivity: Float = 4.0
    /// Number of samples to interpolate over when a click is detected
    public var interpolationWidth: Int = 64
    /// Smoothing factor for the running envelope (0-1, lower = slower tracking)
    private let envelopeAlpha: Float = 0.001

    private var envelope: Float = 0.0

    public init(sensitivity: Float = 4.0) {
        self.sensitivity = sensitivity
    }

    /// Process audio buffer in-place, replacing detected clicks with interpolation
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard isEnabled, frameCount > 0 else { return }

        // First pass: update envelope and detect click regions
        var clickMask = [Bool](repeating: false, count: frameCount)

        for i in 0..<frameCount {
            let level = fabsf(buffer[i])

            // Update running envelope (slow tracker of average level)
            envelope = envelopeAlpha * level + (1.0 - envelopeAlpha) * envelope

            // Detect: sample is much louder than running average
            let threshold = max(envelope * sensitivity, 0.001)
            if level > threshold {
                // Mark this sample and surrounding region as click
                let start = max(0, i - interpolationWidth / 2)
                let end = min(frameCount, i + interpolationWidth / 2)
                for j in start..<end {
                    clickMask[j] = true
                }
            }
        }

        // Second pass: replace click regions with linear interpolation
        var i = 0
        while i < frameCount {
            if clickMask[i] {
                // Find the extent of this click region
                var clickEnd = i
                while clickEnd < frameCount && clickMask[clickEnd] {
                    clickEnd += 1
                }

                // Get boundary values for interpolation
                let leftVal = (i > 0) ? buffer[i - 1] : 0.0
                let rightVal = (clickEnd < frameCount) ? buffer[clickEnd] : 0.0
                let span = Float(clickEnd - i + 1)

                // Linear interpolation across the click
                for j in i..<clickEnd {
                    let t = Float(j - i + 1) / span
                    buffer[j] = leftVal * (1.0 - t) + rightVal * t
                }

                i = clickEnd
            } else {
                i += 1
            }
        }
    }
}
