import XCTest
import AVFoundation
import Speech
@testable import LiveNotesCore

@MainActor
final class SpeechEngineTests: XCTestCase {

    func testMicDeniedReportedBeforeSpeech() {
        let r = SpeechEngine.permissionFailure(mic: .denied, speech: .denied)
        XCTAssertEqual(r?.0, .microphone)          // 先報麥克風，導向正確面板
    }
    func testSpeechDeniedWhenMicOK() {
        XCTAssertEqual(SpeechEngine.permissionFailure(mic: .authorized, speech: .denied)?.0, .speech)
    }
    func testBothAuthorizedPasses() {
        XCTAssertNil(SpeechEngine.permissionFailure(mic: .authorized, speech: .authorized))
    }
    func testNotDeterminedSpeechIsNotSilentlySwallowed() {
        // 原版 notDetermined 回呼沒有 else 分支，會無訊息失敗
        XCTAssertNotNil(SpeechEngine.permissionFailure(mic: .authorized, speech: .notDetermined))
    }
    func testErrorClassification() {
        func e(_ c: Int) -> NSError { NSError(domain: "kAFAssistantErrorDomain", code: c) }
        XCTAssertEqual(SpeechEngine.classify(e(216)), .ignorable)
        XCTAssertEqual(SpeechEngine.classify(e(301)), .ignorable)
        XCTAssertEqual(SpeechEngine.classify(e(1110)), .retryQuietly)
        XCTAssertEqual(SpeechEngine.classify(e(1101)), .fatal)   // Dictation 關閉
    }
    func testNoDuplicateTurnAfterCommit() {
        let engine = SpeechEngine()
        var turns: [String] = []
        engine.onNewTurn = { turns.append($0) }
        engine.testEmitUtterance("hello")
        engine.testEmitUtterance("hello")          // 相同文字不應重複提交
        XCTAssertEqual(turns, ["hello"])
        XCTAssertEqual(engine.transcripts.count, 1)
    }
    func testStopWhenIdleIsSafe() {
        let engine = SpeechEngine()
        engine.stopRecording(); engine.stopRecording()
        XCTAssertFalse(engine.isRecording)
    }
}