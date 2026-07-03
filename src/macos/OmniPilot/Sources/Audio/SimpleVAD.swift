import Foundation
import Accelerate
import Network
import os.log

/// Voice Activity Detection with Silero ONNX backend (via local TCP service)
/// Falls back to energy-based detection ONLY if the Silero service is unavailable.
class SimpleVAD: @unchecked Sendable {
    private static let log = Logger(subsystem: "in.sidewall.omnipilot", category: "VAD")
    /// Speech threshold (used for energy fallback)
    var speechThreshold: Float = 0.01

    /// Minimum consecutive speech frames to trigger (2 frames = 60ms — quick to start)
    var minSpeechFrames: Int = 2
    /// Minimum consecutive silence frames to stop (25 frames = 750ms — holds through natural pauses)
    /// Natural speech has 300-500ms pauses between phrases for breath/thought. Must wait longer than that.
    var minSilenceFrames: Int = 25

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
                self?.reset()   // clear the state machine when the neural VAD (re)connects
                Self.log.info("Connected to Silero service — using neural VAD")
            case .failed, .cancelled:
                self?.useSilero = false
                self?.sileroConnection = nil
                Self.log.error("Silero service unavailable — falling back to energy-based VAD")
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

    /// Process via Silero ONNX service. Callers MUST pass exactly 512 samples (Silero is stateful;
    /// wrong-sized or zero-padded frames corrupt its inference). This now runs on Pipeline's VAD
    /// queue, not the audio thread, so we can afford a real timeout instead of bailing to energy.
    private func processSilero(samples: [Float], connection: NWConnection) -> Bool {
        var frame = samples
        if frame.count != sileroFrameSize {
            // Defensive: framing is the caller's job, but never send a wrong size to Silero.
            if frame.count < sileroFrameSize {
                frame.append(contentsOf: [Float](repeating: 0, count: sileroFrameSize - frame.count))
            } else {
                frame = Array(frame.prefix(sileroFrameSize))
            }
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

        // Wait up to 40ms. Silero inference is ~2ms; the headroom absorbs IPC jitter. On the rare
        // timeout we treat the frame as non-speech (conservative) but STAY on Silero — we do NOT
        // fall back to the energy gate, which can't distinguish speech from noise. A genuine
        // connection failure flips `useSilero` off via the state handler.
        if semaphore.wait(timeout: .now() + .milliseconds(40)) == .timedOut {
            Self.log.debug("Silero frame timed out (>40ms); treating as non-speech")
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

    /// Reconnect to Silero service. No-op if already connected — the app calls this after (re)starting
    /// the VAD service, but if we connected at init there's no need to tear down a healthy connection
    /// (doing so caused a ~1.5s flap to the energy gate at startup, during which noise could leak).
    func reconnectSilero() {
        guard !useSilero else { return }
        sileroConnection?.cancel()
        connectToSilero()
    }

    deinit {
        sileroConnection?.cancel()
    }
}
