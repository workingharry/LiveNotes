import XCTest
@testable import LiveNotesCore

@MainActor
final class MeetingHistoryStoreTests: XCTestCase {

    func testDateFormatting() {
        let formatted = MeetingHistoryStore.formatDateString("20261021_143000")
        XCTAssertTrue(formatted.contains("2026-10-21") || formatted.contains("14:30"))
    }

    func testLoadFromDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let meetingFolder = tempDir.appendingPathComponent("Meeting_20261022_100000")
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let transcriptFile = meetingFolder.appendingPathComponent("transcript.txt")
        let summaryFile = meetingFolder.appendingPathComponent("summary.md")

        try "[10:00:00] Team sync started.".write(to: transcriptFile, atomically: true, encoding: .utf8)
        try "# Meeting Summary\nDecision approved.".write(to: summaryFile, atomically: true, encoding: .utf8)

        let store = MeetingHistoryStore(rootDirectory: tempDir)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.id, "Meeting_20261022_100000")
        XCTAssertEqual(store.sessions.first?.transcriptSnippet, "[10:00:00] Team sync started.")
        XCTAssertEqual(store.sessions.first?.summarySnippet, "# Meeting Summary\nDecision approved.")

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }
}
