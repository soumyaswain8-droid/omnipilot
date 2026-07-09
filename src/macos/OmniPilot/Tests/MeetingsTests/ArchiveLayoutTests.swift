import XCTest
@testable import OmniPilot

final class ArchiveLayoutTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(ArchiveLayout.slug("Weekly Sync!! #3"), "Weekly-Sync-3")
        XCTAssertEqual(ArchiveLayout.slug(nil), "Meeting")
        XCTAssertEqual(ArchiveLayout.slug("   "), "Meeting")
    }

    func testFolderNaming() {
        let root = URL(fileURLWithPath: "/tmp/archive")
        let layout = ArchiveLayout(root: root)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 9; comps.hour = 14; comps.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let folder = layout.folder(date: date, title: "Weekly Sync")
        XCTAssertEqual(folder.lastPathComponent, "2026-07-09_14-05_Weekly-Sync")
        XCTAssertEqual(folder.deletingLastPathComponent().path, "/tmp/archive")
    }
}
