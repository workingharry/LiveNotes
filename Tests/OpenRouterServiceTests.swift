import XCTest
@testable import LiveNotesCore

@MainActor
final class OpenRouterServiceTests: XCTestCase {

    func testInitialState() {
        let service = OpenRouterService()
        XCTAssertEqual(service.currentSummary, "")
        XCTAssertFalse(service.isSummarizing)
        XCTAssertEqual(service.model, "openrouter/free")
        XCTAssertEqual(service.allTranscripts.count, 0)
        XCTAssertEqual(service.pendingTranscripts.count, 0)
        XCTAssertEqual(service.copilotAnswer, "")
        XCTAssertFalse(service.isCopilotQuerying)
    }

    func testAddTranscript() {
        let service = OpenRouterService()
        service.addTranscript(text: "Decision made to launch app next week.", timestamp: "14:30:00")
        
        XCTAssertEqual(service.allTranscripts.count, 1)
        XCTAssertEqual(service.pendingTranscripts.count, 1)
        XCTAssertEqual(service.allTranscripts.first, "[14:30:00] Decision made to launch app next week.")
    }

    func testBatchThresholdNotMetDoesNotTrigger() {
        let service = OpenRouterService()
        service.addTranscript(text: "Hello world.", timestamp: "14:30:00") // 2 words < 12 words threshold
        
        service.triggerSummaryCycle(force: false)
        XCTAssertFalse(service.isSummarizing)
    }

    func testSSEChunkParsing() {
        let sseLine = "data: {\"choices\": [{\"delta\": {\"content\": \"## Decisions\\n\"}}]}"
        let parsed = OpenRouterService.parseSSEChunk(line: sseLine)
        XCTAssertEqual(parsed, "## Decisions\n")

        let doneLine = "data: [DONE]"
        XCTAssertNil(OpenRouterService.parseSSEChunk(line: doneLine))

        let nonDataLine = ": ping"
        XCTAssertNil(OpenRouterService.parseSSEChunk(line: nonDataLine))
    }

    func testRetryPolicyBoundsAndJitter() {
        let policy = RetryPolicy(maxAttempts: 5, base: 2.0, cap: 30.0)
        for attempt in 0..<5 {
            let delay = policy.delay(attempt: attempt, retryAfter: nil)
            let maxExpected = min(policy.base * pow(2.0, Double(attempt)), policy.cap)
            XCTAssertGreaterThanOrEqual(delay, 0.0)
            XCTAssertLessThanOrEqual(delay, maxExpected)
        }
    }

    func testRetryPolicyRespectsRetryAfter() {
        let policy = RetryPolicy()
        let delay = policy.delay(attempt: 1, retryAfter: 15.0)
        XCTAssertEqual(delay, 15.0)

        // Clamped between 1 and 60
        let delayCapped = policy.delay(attempt: 1, retryAfter: 120.0)
        XCTAssertEqual(delayCapped, 60.0)

        let delayFloor = policy.delay(attempt: 1, retryAfter: 0.2)
        XCTAssertEqual(delayFloor, 1.0)
    }

    func testSummaryIntervalUpdateAndClamping() {
        let service = OpenRouterService()
        XCTAssertGreaterThanOrEqual(service.summaryIntervalSeconds, 15.0)

        service.updateSummaryInterval(90.0)
        XCTAssertEqual(service.summaryIntervalSeconds, 90.0)

        // Test lower bound clamp (15s)
        service.updateSummaryInterval(5.0)
        XCTAssertEqual(service.summaryIntervalSeconds, 15.0)

        // Test upper bound clamp (600s)
        service.updateSummaryInterval(1000.0)
        XCTAssertEqual(service.summaryIntervalSeconds, 600.0)
    }
}
