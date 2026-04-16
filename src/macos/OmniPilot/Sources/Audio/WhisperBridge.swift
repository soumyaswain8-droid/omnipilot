import Foundation

/// Bridges to whisper.cpp CLI for speech-to-text transcription
class WhisperBridge: @unchecked Sendable {
    private let whisperPath: String
    private let modelPath: String
    private let tempDir: URL

    init() {
        // Find whisper-cli binary (homebrew installs as whisper-cli)
        let brewPath = "/usr/local/bin/whisper-cli"
        let altPath = "/opt/homebrew/bin/whisper-cli"
        if FileManager.default.fileExists(atPath: brewPath) {
            whisperPath = brewPath
        } else if FileManager.default.fileExists(atPath: altPath) {
            whisperPath = altPath
        } else {
            whisperPath = "whisper-cpp" // hope it's in PATH
        }

        // Model path — check app bundle first, then project directory
        let modelName = "ggml-small.en.bin"
        if let bundlePath = Bundle.main.path(forResource: "ggml-small.en", ofType: "bin") {
            modelPath = bundlePath
        } else {
            // Fallback: project models directory (for SPM/dev builds)
            let projectRoot = URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // Audio/
                .deletingLastPathComponent() // Sources/
                .deletingLastPathComponent() // OmniPilot/
                .deletingLastPathComponent() // macos/
                .deletingLastPathComponent() // src/
            let projectModelPath = projectRoot.appendingPathComponent("models/\(modelName)").path
            if FileManager.default.fileExists(atPath: projectModelPath) {
                modelPath = projectModelPath
            } else {
                // Last resort: home directory
                modelPath = NSHomeDirectory() + "/Documents/tinker/projects/omnipilot/models/\(modelName)"
            }
        }

        // Temp directory for audio files
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omnipilot")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        print("[WhisperBridge] Binary: \(whisperPath)")
        print("[WhisperBridge] Model: \(modelPath)")
    }

    /// Transcribe a chunk of audio (Float32 PCM, 16kHz, mono)
    func transcribe(audioSamples: [Float]) async throws -> String {
        // Write audio to WAV file
        let wavPath = tempDir.appendingPathComponent("chunk_\(Date().timeIntervalSince1970).wav")
        try writeWAV(samples: audioSamples, to: wavPath, sampleRate: 16000)

        defer {
            try? FileManager.default.removeItem(at: wavPath)
        }

        // Run whisper-cpp
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", modelPath,
            "-f", wavPath.path,
            "--no-timestamps",
            "--threads", "4",
            "--language", "en",
            "--output-txt"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Also check for .txt output file
        let txtPath = wavPath.appendingPathExtension("txt")
        if FileManager.default.fileExists(atPath: txtPath.path) {
            let txtContent = try String(contentsOf: txtPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: txtPath)
            return txtContent.isEmpty ? output : txtContent
        }

        return output
    }

    /// Write Float32 samples to a WAV file
    private func writeWAV(samples: [Float], to url: URL, sampleRate: Int) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        // Convert Float32 [-1,1] to Int16
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        header.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        // Sample data
        var sampleData = Data(capacity: int16Samples.count * 2)
        for sample in int16Samples {
            sampleData.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }

        var fileData = header
        fileData.append(sampleData)
        try fileData.write(to: url)
    }

    /// Check if whisper-cpp and model are available
    func isAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: whisperPath) &&
               FileManager.default.fileExists(atPath: modelPath)
    }
}
