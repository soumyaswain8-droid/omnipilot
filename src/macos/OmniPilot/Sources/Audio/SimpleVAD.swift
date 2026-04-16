import Foundation
import Accelerate
import Network

/// Voice Activity Detection with Silero ONNX backend (via local TCP service)
/// Falls back to energy-based detection if the Silero service isn't running.
class SimpleVAD: @unchecked Sendable {
    /// Speech threshold (used for energy fallback)
    var speechThreshold: Float = 0.01

    /// Minimum consecutive speech frames to trigger
    var minSpeechFrames: Int = 3
    /// Minimum consecutive silence frames to stop
    var minSilenceFrames: Int = 15

    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0
    private(set) var isSpeaking = false

    /// Silero service connection
    private var sileroConnection: NWConnection?
    private var useSilero = false
    private let sileroHost = "127.0.0.1"
    private let sileroPort: UInt16 = 18384
    private let sileroFrameSize = 512 // Silero expects 512 samples

    /// Pending Silero response
    private var pendingSileroResult: Bool?
    private let sileroLock = NSLock()

    init() {
        connectToSilero()
    }

    /// Try to connect to the Silero VAD service
    private func connectToSilero() {
        let host = NWEndpoint.Host(sileroHost)
        let port = NWEndpoint.Port(rawValue: sileroPort)!
        let connection = NWConnection(host: host, port: port, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.useSilero = true
                print("[VAD] Connected to Silero service (neural network VAD)")
            case .failed, .cancelled:
                self?.useSilero = false
                self?.sileroConnection = nil
                print("[VAD] Silero service not available, using energy-based fallback")
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
        self.sileroConnection = connection
    }

    /// Process a frame of audio samples and return whether speech is detected
    func process(samples: [Float]) -> Bool {
        let isSpeechFrame: Bool

        if useSilero, let conn = sileroConnection {
            isSpeechFrame = processSilero(samples: samples, connection: conn)
        } else {
            isSpeechFrame = processEnergy(samples: samples)
        }

        // State machine: require consecutive frames to change state
        if isSpeechFrame {
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

    /// Process via Silero ONNX service
    private func processSilero(samples: [Float], connection: NWConnection) -> Bool {
        // Silero expects exactly 512 samples — pad or truncate
        var frame = Array(samples.prefix(sileroFrameSize))
        if frame.count < sileroFrameSize {
            frame.append(contentsOf: [Float](repeating: 0, count: sileroFrameSize - frame.count))
        }

        // Send as float32 bytes
        let data = frame.withUnsafeBufferPointer { ptr in
            Data(bytes: ptr.baseAddress!, count: ptr.count * MemoryLayout<Float>.size)
        }

        var result = false
        let semaphore = DispatchSemaphore(value: 0)

        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil {
                semaphore.signal()
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { content, _, _, _ in
                if let content = content, let byte = content.first {
                    result = byte == 0x31 // ASCII '1'
                }
                semaphore.signal()
            }
        })

        // Wait up to 10ms — if Silero is too slow, return false (don't block audio)
        let timeout = semaphore.wait(timeout: .now() + .milliseconds(10))
        if timeout == .timedOut {
            return false
        }

        return result
    }

    /// Fallback: energy-based detection using Accelerate
    private func processEnergy(samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms > speechThreshold
    }

    /// Reset state
    func reset() {
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
        isSpeaking = false
    }

    /// Check if Silero is active
    var isSileroActive: Bool { useSilero }

    /// Reconnect to Silero service
    func reconnectSilero() {
        sileroConnection?.cancel()
        useSilero = false
        connectToSilero()
    }

    deinit {
        sileroConnection?.cancel()
    }
}
