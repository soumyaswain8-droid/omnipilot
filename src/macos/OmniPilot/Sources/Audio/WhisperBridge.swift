import Foundation

/// Bridges to whisper-server HTTP API for fast speech-to-text.
/// Uses persistent whisper-server (port 18386) which loads model once.
/// Falls back to whisper-cli subprocess if server is unavailable.
class WhisperBridge: @unchecked Sendable {
    private let serverURL = "http://127.0.0.1:18386/inference"
    private let whisperCliPath: String
    private let modelPath: String
    private let tempDir: URL
    private var useServer = false

    init() {
        // Find whisper-cli binary as fallback
        let brewPath = "/usr/local/bin/whisper-cli"
        let altPath = "/opt/homebrew/bin/whisper-cli"
        whisperCliPath = FileManager.default.fileExists(atPath: brewPath) ? brewPath : altPath

        // Model path for CLI fallback
        let projectModels = NSHomeDirectory() + "/Documents/tinker/projects/omnipilot/models"
        let basePath = projectModels + "/ggml-base.en.bin"
        let smallPath = projectModels + "/ggml-small.en.bin"
        modelPath = FileManager.default.fileExists(atPath: basePath) ? basePath : smallPath

        // Temp directory
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omnipilot")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Check if server is available
        checkServer()
        print("[Whisper] Mode: \(useServer ? "Server (fast)" : "CLI (slow)")")
    }

    private func checkServer() {
        guard let url = URL(string: "http://127.0.0.1:18386/") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var available = false
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { available = true }
            semaphore.signal()
        }.resume()
        semaphore.wait(timeout: .now() + 2)
        useServer = available
    }

    /// Transcribe audio — uses HTTP server (fast) or CLI (slow) fallback
    func transcribe(audioSamples: [Float]) async throws -> String {
        if useServer {
            return try await transcribeViaServer(audioSamples)
        } else {
            return try await transcribeViaCLI(audioSamples)
        }
    }

    // MARK: - Server Mode (Fast — model loaded once)

    private func transcribeViaServer(_ samples: [Float]) async throws -> String {
        let wavPath = tempDir.appendingPathComponent("chunk_\(Date().timeIntervalSince1970).wav")
        try writeWAV(samples: samples, to: wavPath, sampleRate: 16000)

        defer { try? FileManager.default.removeItem(at: wavPath) }

        guard let url = URL(string: serverURL) else { throw WhisperError.serverUnavailable }

        // whisper-server expects multipart/form-data with a file upload
        let boundary = "OmniPilot-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let wavData = try Data(contentsOf: wavPath)
        var body = Data()

        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Server failed, try CLI fallback
            useServer = false
            return try await transcribeViaCLI(samples)
        }

        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text
    }

    // MARK: - CLI Mode (Slow — loads model each time)

    private func transcribeViaCLI(_ samples: [Float]) async throws -> String {
        let wavPath = tempDir.appendingPathComponent("chunk_\(Date().timeIntervalSince1970).wav")
        try writeWAV(samples: samples, to: wavPath, sampleRate: 16000)

        defer { try? FileManager.default.removeItem(at: wavPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCliPath)
        process.arguments = ["-m", modelPath, "-f", wavPath.path, "--no-timestamps", "--threads", "4", "-l", "en"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - WAV Writer

    private func writeWAV(samples: [Float], to url: URL, sampleRate: Int) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

        let int16Samples = samples.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max))
        }

        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        header.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt32(UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: (numChannels * (bitsPerSample / 8)).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var sampleData = Data(capacity: int16Samples.count * 2)
        for s in int16Samples {
            sampleData.append(withUnsafeBytes(of: s.littleEndian) { Data($0) })
        }

        var fileData = header
        fileData.append(sampleData)
        try fileData.write(to: url)
    }

    func isAvailable() -> Bool {
        return useServer || FileManager.default.fileExists(atPath: whisperCliPath)
    }

    /// Reconnect to server (call after server starts)
    func reconnectServer() {
        checkServer()
        print("[Whisper] Reconnected: \(useServer ? "Server (fast)" : "CLI (slow)")")
    }

    enum WhisperError: Error {
        case serverUnavailable
    }
}
