import Foundation
import Accelerate

/// Simple energy-based Voice Activity Detection
/// Uses RMS energy threshold to detect speech vs silence.
/// Lightweight alternative to Silero VAD — upgrade later when ONNX runtime is integrated.
class SimpleVAD {
    /// RMS energy threshold for speech detection (tunable)
    var speechThreshold: Float = 0.01
    /// Minimum consecutive speech frames to trigger
    var minSpeechFrames: Int = 3
    /// Minimum consecutive silence frames to stop
    var minSilenceFrames: Int = 15

    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0
    private(set) var isSpeaking = false

    /// Process a frame of audio samples and return whether speech is detected
    /// - Parameter samples: Audio samples (Float32, typically 30ms worth at 16kHz = 480 samples)
    /// - Returns: true if speech is currently active
    func process(samples: [Float]) -> Bool {
        let rms = computeRMS(samples)

        if rms > speechThreshold {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0

            if consecutiveSpeechFrames >= minSpeechFrames && !isSpeaking {
                isSpeaking = true
            }
        } else {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0

            if consecutiveSilenceFrames >= minSilenceFrames && isSpeaking {
                isSpeaking = false
            }
        }

        return isSpeaking
    }

    /// Reset state
    func reset() {
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
        isSpeaking = false
    }

    /// Compute RMS energy using Accelerate framework
    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
