import Foundation
import AVFoundation

/// Continuous mic recorder: accumulates samples for transcription windows and writes an m4a for archive.
final class MeetingRecorder: @unchecked Sendable {
    private let capture: AudioCapture
    private let sampleRate: Int
    private let lock = NSLock()
    private var samples: [Float] = []
    private var audioFile: AVAudioFile?
    private var outputURL: URL?

    init(capture: AudioCapture, sampleRate: Int = 16_000) {
        self.capture = capture
        self.sampleRate = sampleRate
    }

    var totalSamples: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    func start(writingTo url: URL) throws {
        outputURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        capture.onAudioChunk = { [weak self] chunk in self?.ingest(chunk) }
        capture.startCapture()
    }

    /// Test/production seam: accept samples, buffer them, and append to the m4a.
    func ingest(_ chunk: [Float]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        guard let file = audioFile,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            buf.floatChannelData!.pointee.update(from: src.baseAddress!, count: chunk.count)
        }
        try? file.write(from: buf)
    }

    /// Return all samples from `offset` to now, plus the new offset.
    func windowSince(_ offset: Int) -> (samples: [Float], newOffset: Int) {
        lock.lock(); defer { lock.unlock() }
        guard offset < samples.count else { return ([], samples.count) }
        return (Array(samples[offset..<samples.count]), samples.count)
    }

    func stop() -> URL? {
        capture.stopCapture()
        capture.onAudioChunk = nil
        audioFile = nil     // finalizes the m4a
        return outputURL
    }
}
