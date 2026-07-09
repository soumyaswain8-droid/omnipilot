import XCTest
@testable import OmniPilot

final class ArchivePublisherTests: XCTestCase {
    func testPublishWritesArtifacts() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omnipub-\(UUID().uuidString)")
        // a fake audio file to move
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let srcAudio = tmp.appendingPathComponent("in.m4a")
        try Data("AUDIO".utf8).write(to: srcAudio)

        let pub = ArchivePublisher(layout: ArchiveLayout(root: tmp.appendingPathComponent("archive")))
        let art = try pub.publish(date: Date(), title: "Sync",
                                  notes: "# Notes", transcript: "# Transcript", audio: srcAudio)

        XCTAssertTrue(FileManager.default.fileExists(atPath: art.notesMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.transcriptMD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: art.audioM4A.path))
        XCTAssertEqual(try String(contentsOf: art.notesMD, encoding: .utf8), "# Notes")
        XCTAssertTrue(art.folder.lastPathComponent.hasSuffix("_Sync"))
    }
}
