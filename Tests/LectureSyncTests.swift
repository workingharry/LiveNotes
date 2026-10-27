import XCTest
@testable import LiveNotesCore

final class LectureSyncTests: XCTestCase {

    func testNoteModePrompts() {
        let lectureMode = NoteMode.studentLecture
        XCTAssertEqual(lectureMode.shortTitle, "課堂模式")
        XCTAssertTrue(lectureMode.systemPrompt.contains("academic note-taking AI assistant"))
        XCTAssertTrue(lectureMode.systemPrompt.contains("必考重點"))
        XCTAssertFalse(lectureMode.defaultCopilotPrompts.isEmpty)
        XCTAssertTrue(lectureMode.defaultCopilotPrompts.contains("這堂課有提到哪些考試重點？"))

        let meetingMode = NoteMode.generalMeeting
        XCTAssertEqual(meetingMode.shortTitle, "會議模式")
        XCTAssertTrue(meetingMode.systemPrompt.contains("Decisions"))
    }

    func testObsidianMarkdownGeneration() {
        let title = "CS101 Intro to AI"
        let content = "## 核心概念\n機器學習與神經網路"
        let tags = ["cs101", "lecture", "ai"]
        let fixedDate = Date(timeIntervalSince1970: 1761100000)

        let result = ObsidianSyncService.generateObsidianMarkdown(
            title: title,
            content: content,
            tags: tags,
            date: fixedDate
        )

        XCTAssertTrue(result.hasPrefix("---\n"))
        XCTAssertTrue(result.contains("title: \"CS101 Intro to AI\""))
        XCTAssertTrue(result.contains("tags:\n  - cs101\n  - lecture\n  - ai"))
        XCTAssertTrue(result.contains("source: \"LiveNotes macOS\""))
        XCTAssertTrue(result.contains("## 核心概念\n機器學習與神經網路"))
    }

    func testObsidianVaultSaving() throws {
        let tempVault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempVault) }

        let markdown = "# Test Notes\nContent here"
        let savedURL = try ObsidianSyncService.saveToVault(
            vaultURL: tempVault,
            noteName: "Lecture_20261022",
            markdown: markdown
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let readBack = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertEqual(readBack, markdown)
    }

    func testObsidianAppURLBuilding() {
        let url = ObsidianSyncService.buildObsidianAppURL(
            vaultName: "MyStudyVault",
            noteName: "Lecture 1",
            markdown: "Notes body"
        )
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "obsidian")
        XCTAssertEqual(url?.host, "new")
        let str = url?.absoluteString ?? ""
        XCTAssertTrue(str.contains("name=Lecture-1") || str.contains("name=Lecture%201"))
        XCTAssertTrue(str.contains("vault=MyStudyVault"))
    }

    func testYAMLFrontmatterEscaping() {
        let maliciousTitle = "CS101: \"Intro to AI\"\nInjection: true"
        let md = ObsidianSyncService.generateObsidianMarkdown(
            title: maliciousTitle,
            content: "Lecture body",
            tags: ["ai\"quote", "study"]
        )

        XCTAssertTrue(md.contains("title: \"CS101: \\\"Intro to AI\\\" Injection: true\""))
        XCTAssertTrue(md.contains("  - ai\\\"quote"))
    }

    func testObsidianFilenameSanitizationAndOpenURL() throws {
        let tempVault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempVault) }

        let unsafeNoteName = "課堂筆記_10/22/2026: 14:30*?"
        let savedURL = try ObsidianSyncService.saveToVault(
            vaultURL: tempVault,
            noteName: unsafeNoteName,
            markdown: "# Safe Note"
        )

        XCTAssertFalse(savedURL.lastPathComponent.contains(":"))
        XCTAssertFalse(savedURL.lastPathComponent.contains("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))

        let openURL = ObsidianSyncService.buildObsidianOpenFileURL(fileURL: savedURL)
        XCTAssertEqual(openURL?.scheme, "obsidian")
        XCTAssertEqual(openURL?.host, "open")
        XCTAssertTrue(openURL?.absoluteString.contains("path=") ?? false)
    }

    func testNotionSingleNewlineBlockParsing() {
        let lectureMarkdown = """
        # 📚 課堂核心概念
        本堂課介紹微積分基本定理。
        ## 💡 必考重點
        - ⚠️ 定積分與不定積分的關聯
        ## ✍️ 課堂作業
        - [ ] 習題 4.2 第 1-10 題
        - [x] 預習第五章
        """

        let blocks = NotionSyncService.buildNotionBlocks(from: lectureMarkdown)
        XCTAssertEqual(blocks.count, 7)
        XCTAssertEqual(blocks[0]["type"] as? String, "heading_1")
        XCTAssertEqual(blocks[1]["type"] as? String, "paragraph")
        XCTAssertEqual(blocks[2]["type"] as? String, "heading_2")
        XCTAssertEqual(blocks[3]["type"] as? String, "bulleted_list_item")
        XCTAssertEqual(blocks[4]["type"] as? String, "heading_2")
        XCTAssertEqual(blocks[5]["type"] as? String, "to_do")
        XCTAssertEqual(blocks[6]["type"] as? String, "to_do")

        let checkedTodo = blocks[6]["to_do"] as? [String: Any]
        XCTAssertEqual(checkedTodo?["checked"] as? Bool, true)
    }

    func testNotionClipboardFormatting() {
        let formatted = NotionSyncService.formatForNotionClipboard(
            title: "微積分 Calculus I",
            markdown: "### 極限定理\n- 定理 1"
        )
        XCTAssertTrue(formatted.contains("# 微積分 Calculus I"))
        XCTAssertTrue(formatted.contains("Recorded via LiveNotes macOS Native Lecture Assistant"))
        XCTAssertTrue(formatted.contains("### 極限定理"))
    }

    func testNotionSyncValidationFailsWithoutKey() async {
        do {
            _ = try await NotionSyncService.syncToDatabase(
                apiKey: "",
                databaseId: "12345",
                title: "Test",
                markdown: "Content"
            )
            XCTFail("Should have thrown error on empty key")
        } catch {
            let nsErr = error as NSError
            XCTAssertEqual(nsErr.code, 401)
        }
    }
}
