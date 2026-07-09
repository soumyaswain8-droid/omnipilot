import Foundation

/// Writes the meeting artifact set into a per-meeting folder under the archive root.
struct ArchivePublisher {
    let layout: ArchiveLayout
    init(layout: ArchiveLayout) { self.layout = layout }

    func publish(date: Date, title: String?, notes: String,
                 transcript: String, audio: URL?) throws -> MeetingArtifacts {
        let fm = FileManager.default
        let folder = layout.folder(date: date, title: title)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let notesMD = folder.appendingPathComponent("notes.md")
        let transcriptMD = folder.appendingPathComponent("transcript.md")
        let audioDst = folder.appendingPathComponent("audio.m4a")
        try notes.write(to: notesMD, atomically: true, encoding: .utf8)
        try transcript.write(to: transcriptMD, atomically: true, encoding: .utf8)
        if let audio = audio, fm.fileExists(atPath: audio.path) {
            if fm.fileExists(atPath: audioDst.path) { try fm.removeItem(at: audioDst) }
            try fm.moveItem(at: audio, to: audioDst)
        }
        let pdf = Self.tryRenderPDF(from: notesMD, in: folder)
        return MeetingArtifacts(folder: folder, notesMD: notesMD,
                                transcriptMD: transcriptMD, audioM4A: audioDst, notesPDF: pdf)
    }

    /// Best-effort PDF via `dp content render` if on PATH; never throws.
    private static func tryRenderPDF(from md: URL, in folder: URL) -> URL? {
        let dp = ["/usr/local/bin/dp", "/opt/homebrew/bin/dp"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let dp = dp else { return nil }
        let pdf = folder.appendingPathComponent("notes.pdf")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: dp)
        proc.arguments = ["content", "render", md.path, "-o", pdf.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        return FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil
    }
}
