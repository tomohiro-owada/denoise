import Foundation
import CRNNoise

/// RNNoise C library wrapper for Swift
public final class RNNoiseProcessor: @unchecked Sendable {
    private var state: OpaquePointer?
    public let frameSize: Int

    public init() {
        state = rnnoise_create(nil)
        frameSize = Int(rnnoise_get_frame_size())
    }

    deinit {
        if let state = state {
            rnnoise_destroy(state)
        }
    }

    /// Process a frame of audio samples. Returns voice activity probability (0.0-1.0).
    /// - Parameter samples: Float array of exactly `frameSize` samples. Modified in-place.
    /// - Returns: Voice activity probability
    @discardableResult
    public func processFrame(_ samples: inout [Float]) -> Float {
        guard let state = state else { return 0 }
        precondition(samples.count == frameSize, "Frame must be exactly \(frameSize) samples")
        let vad = rnnoise_process_frame(state, &samples, samples)
        return vad
    }
}
