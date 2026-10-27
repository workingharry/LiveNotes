import XCTest
@testable import LiveNotesCore

@MainActor final class Counter { var n = 0 }

@MainActor
final class ReviewRegressionTests: XCTestCase {

    private func makeService(_ transport: (@MainActor (String) async -> StreamResult)?) -> OpenRouterService {
        let s = OpenRouterService()
        s.sessionsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        s.retryPolicy = RetryPolicy(maxAttempts: 3, base: 1, cap: 0)
        s.transport = transport
        return s
    }
    
    private func waitUntil(_ cond: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // ---- RetryPolicy ----
    func testRetryPolicyDegenerateInputsDoNotTrap() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 3, base: 2, cap: -5).delay(attempt: 3, retryAfter: nil), 0)
        XCTAssertLessThanOrEqual(RetryPolicy().delay(attempt: 100_000, retryAfter: nil), 30)
        let d = RetryPolicy().delay(attempt: 1, retryAfter: .nan)
        XCTAssertTrue(d.isFinite && d >= 0 && d <= 30)
    }

    // ---- 重試迴圈 ----
    func testRetriesOn429ThenSucceeds() async {
        let c = Counter()
        let s = makeService { _ in 
            c.n += 1
            return c.n < 3 ? .init(success: false, statusCode: 429) : .init(success: true, statusCode: 200) 
        }
        let ok = await s.requestOpenRouterStreamWithRetry(userPrompt: "x")
        XCTAssertTrue(ok)
        XCTAssertEqual(c.n, 3)
    }

    func testNonRetriableStatusStopsImmediately() async {
        let c = Counter()
        let s = makeService { _ in 
            c.n += 1
            return .init(success: false, statusCode: 401) 
        }
        let ok = await s.requestOpenRouterStreamWithRetry(userPrompt: "x")
        XCTAssertFalse(ok)
        XCTAssertEqual(c.n, 1)
    }

    func testNoSleepAfterFinalAttempt() async {
        let s = makeService { _ in .init(success: false, statusCode: 429, retryAfter: 60) }
        s.retryPolicy = RetryPolicy(maxAttempts: 1)
        let t0 = Date()
        _ = await s.requestOpenRouterStreamWithRetry(userPrompt: "x")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    func testCancellationInterruptsBackoff() async {
        let s = makeService { _ in .init(success: false, statusCode: 429, retryAfter: 60) }
        let t = Task { await s.requestOpenRouterStreamWithRetry(userPrompt: "x") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        t.cancel()
        let t0 = Date()
        let ok = await t.value
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    // ---- 摘要週期 ----
    func testCJKThresholdTriggers() {
        let s = makeService { _ in .init(success: true, statusCode: 200) }
        s.addTranscript(text: String(repeating: "今日開會討論發佈", count: 5), timestamp: "10:00:00")
        s.triggerSummaryCycle(force: false)
        XCTAssertTrue(s.isSummarizing)
    }

    func testForceWithEmptyPendingSendsNothing() {
        let c = Counter()
        let s = makeService { _ in 
            c.n += 1
            return .init(success: true, statusCode: 200) 
        }
        s.startSession()
        s.stopSession()
        XCTAssertFalse(s.isSummarizing)
        XCTAssertEqual(c.n, 0)
    }

    func testStopWhileSummarizingRunsFinalCycle() async {
        let c = Counter()
        let s = makeService { _ in 
            c.n += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .init(success: true, statusCode: 200) 
        }
        s.startSession()
        s.addTranscript(text: String(repeating: "alpha beta ", count: 10), timestamp: "10:00:00")
        s.triggerSummaryCycle()
        s.addTranscript(text: "最後一句話", timestamp: "10:00:05")
        s.stopSession()
        await waitUntil { !s.isSummarizing && c.n >= 2 }
        XCTAssertEqual(c.n, 2)
        XCTAssertTrue(s.pendingTranscripts.isEmpty)
    }

    func testStartSessionDuringInflightDoesNotCorruptNewSession() async {
        let s = makeService { _ in 
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .init(success: true, statusCode: 200) 
        }
        s.startSession()
        s.addTranscript(text: String(repeating: "old meeting ", count: 10), timestamp: "10:00:00")
        s.triggerSummaryCycle()
        s.startSession()
        s.addTranscript(text: "new meeting line", timestamp: "11:00:00")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(s.pendingTranscripts.count, 1)
        XCTAssertFalse(s.isSummarizing)
    }

    // ---- SSE ----
    func testSSEErrorDetection() {
        XCTAssertTrue(OpenRouterService.isSSEError(line: #"data: {"error":{"message":"x"}}"#))
        XCTAssertFalse(OpenRouterService.isSSEError(line: "data: [DONE]"))
        XCTAssertFalse(OpenRouterService.isSSEError(line: #"data: {"choices":[]}"#))
    }
}

@MainActor
final class MeetingHistoryRegressionTests: XCTestCase {
    func testDateFormattingIsExactAndCalendarIndependent() {
        XCTAssertEqual(MeetingHistoryStore.formatDateString("20261021_143000"), "2026-10-21 14:30")
        XCTAssertEqual(MeetingHistoryStore.formatDateString("garbage"), "garbage")
    }

    func testSortingFilteringAndMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for n in ["Meeting_20261020_090000", "Meeting_20261022_100000", "Other_Folder"] {
            try fm.createDirectory(at: root.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("Meeting_20261023_000000"), atomically: true, encoding: .utf8)
        let store = MeetingHistoryStore(rootDirectory: root)
        XCTAssertEqual(store.sessions.map(\.id), ["Meeting_20261022_100000", "Meeting_20261020_090000"])

        let missing = MeetingHistoryStore(rootDirectory: root.appendingPathComponent("nope"))
        XCTAssertTrue(missing.sessions.isEmpty)
    }

    func testRefreshAsyncPicksUpNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingHistoryStore(rootDirectory: root)
        XCTAssertTrue(store.sessions.isEmpty)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Meeting_20261022_120000"),
                                                withIntermediateDirectories: true)
        await store.refreshAsync()
        XCTAssertEqual(store.sessions.count, 1)
    }
}
