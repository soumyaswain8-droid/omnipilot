import AVFoundation
import Foundation
import os.log

/// Captures microphone audio and provides PCM chunks for processing
class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private var isCapturing = false
    private var tapInstalled = false
    private var converter: AVAudioConverter?

    /// Unified-logging handle — visible via `log stream --predicate 'subsystem == "in.sidewall.omnipilot"'`
    private static let log = Logger(subsystem: "in.sidewall.omnipilot", category: "AudioCapture")

    /// Buffer to accumulate audio samples
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    /// Callback when a chunk of audio is ready (1 second of 16kHz PCM)
    var onAudioChunk: (([Float]) -> Void)?

    /// Chunk size in samples (1 second at 16kHz — lower latency than 3s)
    private let chunkSamples = 16000 * 1

    init() {
        // Intentionally empty. The audio graph MUST be configured after the engine
        // is prepared — querying the input format in init() returns a 0 Hz format on
        // macOS, which yields a broken converter and silent capture. See configureGraph().
    }

    /// Request microphone permission, then start capturing. The explicit request makes the
    /// TCC prompt deterministic instead of relying on engine.start() to trigger it.
    func startCapture() {
        guard !isCapturing else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    self?.beginEngine()
                } else {
                    Self.log.error("Microphone permission DENIED by user — capture cannot start")
                }
            }
        case .denied, .restricted:
            Self.log.error("Microphone permission is denied/restricted in System Settings > Privacy > Microphone. Capture disabled.")
        @unknown default:
            beginEngine()
        }
    }

    /// Build the audio graph (tap + converter) against the LIVE hardware format, then start.
    private func beginEngine() {
        let inputNode = engine.inputNode

        // Prepare forces the engine to resolve the real hardware input format.
        engine.prepare()
        let hwFormat = inputNode.inputFormat(forBus: 0)
        Self.log.info("Input hardware format: \(hwFormat.sampleRate, format: .fixed(precision: 0))Hz, \(hwFormat.channelCount) ch")

        guard hwFormat.sampleRate > 0 else {
            Self.log.error("Input format reports 0 Hz — no usable microphone. Aborting capture.")
            return
        }

        let desiredFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let converter = AVAudioConverter(from: hwFormat, to: desiredFormat) else {
            Self.log.error("Failed to create audio converter from hardware format")
            return
        }
        self.converter = converter

        if !tapInstalled {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                guard let self = self, self.isCapturing else { return }
                self.processAudioBuffer(buffer, outputFormat: desiredFormat)
            }
            tapInstalled = true
        }

        do {
            try engine.start()
            isCapturing = true
            Self.log.info("Started capturing audio")
        } catch {
            Self.log.error("Failed to start engine: \(error.localizedDescription)")
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter = self.converter, buffer.format.sampleRate > 0 else { return }
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate)
        guard frameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            Self.log.error("Conversion error: \(error.localizedDescription)")
            return
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)

        // Emit chunk when we have enough samples
        if audioBuffer.count >= chunkSamples {
            let chunk = Array(audioBuffer.prefix(chunkSamples))
            audioBuffer.removeFirst(chunkSamples)
            bufferLock.unlock()
            onAudioChunk?(chunk)
        } else {
            bufferLock.unlock()
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.stop()
        isCapturing = false
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        Self.log.info("Stopped capturing audio")
    }

    /// Flush remaining buffer (for when user stops recording)
    func flushBuffer() -> [Float]? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard audioBuffer.count > 1600 else { return nil } // At least 100ms
        let chunk = audioBuffer
        audioBuffer.removeAll()
        return chunk
    }
}
