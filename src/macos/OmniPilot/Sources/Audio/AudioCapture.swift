import AVFoundation
import Foundation

/// Captures microphone audio and provides PCM chunks for processing
class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private var isCapturing = false

    /// Buffer to accumulate audio samples
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    /// Callback when a chunk of audio is ready (3-5 seconds of 16kHz PCM)
    var onAudioChunk: (([Float]) -> Void)?

    /// Chunk size in samples (3 seconds at 16kHz)
    private let chunkSamples = 16000 * 3

    init() {
        setupAudioSession()
    }

    private func setupAudioSession() {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        print("[AudioCapture] Input format: \(format.sampleRate)Hz, \(format.channelCount) channels")

        // Install tap to capture audio
        let desiredFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        guard let converter = AVAudioConverter(from: format, to: desiredFormat) else {
            print("[AudioCapture] Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }
            self.processAudioBuffer(buffer, converter: converter, outputFormat: desiredFormat)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("[AudioCapture] Conversion error: \(error)")
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

    func startCapture() {
        guard !isCapturing else { return }
        do {
            try engine.start()
            isCapturing = true
            print("[AudioCapture] Started capturing audio")
        } catch {
            print("[AudioCapture] Failed to start: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.stop()
        isCapturing = false
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        print("[AudioCapture] Stopped capturing audio")
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
