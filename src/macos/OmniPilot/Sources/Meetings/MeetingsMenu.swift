import AppKit

/// Owns the detector+coordinator and exposes control hooks + status text for the menu bar.
@MainActor
final class MeetingsController {
    let detector: MeetingDetector
    let coordinator: MeetingCoordinator
    private(set) var statusText = "Meetings: Idle"
    var onStatusChange: ((String) -> Void)?

    init(assistant: Pipeline?, whisper: WhisperBridge, ollama: OllamaClient) {
        let root = Self.archiveRoot()
        let cfg = MeetingConfig()
        self.detector = MeetingDetector(config: cfg)
        self.coordinator = MeetingCoordinator(assistant: assistant, whisper: whisper,
                                              ollama: ollama, archiveRoot: root, config: cfg)
        detector.onEvent = { [weak self] e in self?.coordinator.handle(e) }
        coordinator.onStateChange = { [weak self] s in self?.updateStatus(s) }
    }

    static func archiveRoot() -> URL {
        if let p = UserDefaults.standard.string(forKey: "meeting.archiveRoot"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OmniPilot Meetings")
    }

    func startAutoDetect() {
        if UserDefaults.standard.object(forKey: "meeting.autoDetect") as? Bool ?? true { detector.start() }
    }

    private func updateStatus(_ s: MeetingState) {
        switch s {
        case .idle: statusText = "Meetings: Idle"
        case .recording: statusText = "Meetings: Recording…"
        case .finalizing: statusText = "Meetings: Transcribing…"
        case .publishing: statusText = "Meetings: Publishing…"
        }
        onStatusChange?(statusText)
    }

    func manualToggle() {
        if coordinator.state == .idle { detector.manualStart() } else { detector.manualStop() }
    }

    func openArchive() {
        let root = Self.archiveRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
