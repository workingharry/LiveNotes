import XCTest
import AVFoundation
import Speech
@testable import LiveNotesCore

@MainActor
final class SpeechEngineTests: XCTestCase {

    func testInitialState() {
        let engine = SpeechEngine()
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.isAuthorizing)
        XCTAssertEqual(engine.transcripts.count, 0)
        XCTAssertEqual(engine.activePartialText, "")
        XCTAssertNil(engine.errorMessage)
    }

    func testLocaleUpdate() {
        let engine = SpeechEngine()
        engine.updateLocale("en-US")
        XCTAssertEqual(engine.currentLocale, "en-US")
    }

    func testTranscriptTurnEmission() {
        let engine = SpeechEngine()
        var emitted: String? = nil
        engine.onNewTurn = { text in
            emitted = text
        }
        
        engine.testEmitUtterance("Hello team, let's start the review.")
        XCTAssertEqual(emitted, "Hello team, let's start the review.")
        XCTAssertEqual(engine.transcripts.count, 1)
        XCTAssertEqual(engine.transcripts.first?.text, "Hello team, let's start the review.")
        XCTAssertEqual(engine.activePartialText, "")
    }

    func testStopRecordingClearsState() {
        let engine = SpeechEngine()
        engine.activePartialText = "Unfinished sentence..."
        engine.stopRecording()
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.isAuthorizing)
        XCTAssertEqual(engine.activePartialText, "")
    }

    func testMicDeniedReportedBeforeSpeech() {
        let r = SpeechEngine.permissionFailure(mic: .denied, speech: .denied)
        XCTAssertEqual(r?.0, .microphone)
    }

    func testSpeechDeniedWhenMicOK() {
        XCTAssertEqual(SpeechEngine.permissionFailure(mic: .authorized, speech: .denied)?.0, .speech)
    }

    func testBothAuthorizedPasses() {
        XCTAssertNil(SpeechEngine.permissionFailure(mic: .authorized, speech: .authorized))
    }

    func testNotDeterminedSpeechIsNotSilentlySwallowed() {
        XCTAssertNotNil(SpeechEngine.permissionFailure(mic: .authorized, speech: .notDetermined))
    }

    func testErrorClassification() {
        func e(_ c: Int) -> NSError { NSError(domain: "kAFAssistantErrorDomain", code: c) }
        XCTAssertEqual(SpeechEngine.classify(e(216)), .ignorable)
        XCTAssertEqual(SpeechEngine.classify(e(301)), .ignorable)
        XCTAssertEqual(SpeechEngine.classify(e(1110)), .retryQuietly)
        XCTAssertEqual(SpeechEngine.classify(e(1101)), .fatal)
    }

    func testNoDuplicateTurnAfterCommit() {
        let engine = SpeechEngine()
        var turns: [String] = []
        engine.onNewTurn = { turns.append($0) }
        engine.testEmitUtterance("hello")
        engine.testEmitUtterance("hello")
        XCTAssertEqual(turns, ["hello"])
        XCTAssertEqual(engine.transcripts.count, 1)
    }

    func testStopWhenIdleIsSafe() {
        let engine = SpeechEngine()
        engine.stopRecording()
        engine.stopRecording()
        XCTAssertFalse(engine.isRecording)
    }

    func testMicSensitivityValuesAndTitles() {
        XCTAssertEqual(MicSensitivity.normal.rawValue, 1.0)
        XCTAssertEqual(MicSensitivity.classroom.rawValue, 2.0)
        XCTAssertEqual(MicSensitivity.lectureHall.rawValue, 3.5)
        XCTAssertEqual(MicSensitivity.ultra.rawValue, 5.0)

        XCTAssertFalse(MicSensitivity.lectureHall.title.isEmpty)
        XCTAssertFalse(MicSensitivity.lectureHall.shortTitle.isEmpty)
    }

    func testEngineUpdateSensitivity() {
        let engine = SpeechEngine()
        engine.updateSensitivity(.ultra)
        XCTAssertEqual(engine.sensitivity, .ultra)
        engine.updateSensitivity(.lectureHall)
        XCTAssertEqual(engine.sensitivity, .lectureHall)
    }

    func testProcessAudioBufferAmplifiesWeakSignal() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100) else {
            XCTFail("Could not create test audio buffer")
            return
        }
        buffer.frameLength = 100
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Missing floatChannelData")
            return
        }

        // Fill with weak signal (e.g. 0.1)
        for i in 0..<100 {
            channelData[i] = 0.1
        }

        let level = SpeechEngine.processAudioBuffer(buffer: buffer, gain: 2.0)
        // 0.1 * 2.0 = 0.2 (within linear threshold <= 0.8)
        XCTAssertEqual(channelData[0], 0.2, accuracy: 0.001)
        XCTAssertGreaterThan(level, 0.0)
    }

    func testProcessAudioBufferSoftLimiterPreventsClipping() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100) else {
            XCTFail("Could not create test audio buffer")
            return
        }
        buffer.frameLength = 100
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Missing floatChannelData")
            return
        }

        // Fill with loud spike (e.g. +0.9 and -0.9)
        channelData[0] = 0.9
        channelData[1] = -0.9

        // Gain of 3.5x would produce raw 3.15 and -3.15 (severe clipping distortion if uncompressed)
        _ = SpeechEngine.processAudioBuffer(buffer: buffer, gain: 3.5)

        // Limiter should compress strictly <= 1.0 and >= -1.0
        XCTAssertLessThanOrEqual(channelData[0], 1.0)
        XCTAssertGreaterThan(channelData[0], 0.8)

        XCTAssertGreaterThanOrEqual(channelData[1], -1.0)
        XCTAssertLessThan(channelData[1], -0.8)
    }

    func testConvertToMonoReducesMultiChannelToOneChannel() {
        guard let formatStereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: formatStereo, frameCapacity: 50) else {
            XCTFail("Could not create stereo buffer")
            return
        }
        buffer.frameLength = 50
        buffer.floatChannelData?[0][0] = 0.4
        buffer.floatChannelData?[1][0] = 0.2

        let monoBuffer = SpeechEngine.convertToMono(buffer: buffer)
        XCTAssertEqual(monoBuffer.format.channelCount, 1)
        XCTAssertEqual(monoBuffer.frameLength, 50)
        // Equal-power sum average: (0.4 + 0.2) / 2 = 0.3
        XCTAssertEqual(monoBuffer.floatChannelData?[0][0] ?? 0, 0.3, accuracy: 0.001)
    }

    func testConvertToMonoReturnsSameBufferWhenAlreadyMono() {
        guard let formatMono = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: formatMono, frameCapacity: 50) else {
            XCTFail("Could not create mono buffer")
            return
        }
        buffer.frameLength = 50
        buffer.floatChannelData?[0][0] = 0.7

        let result = SpeechEngine.convertToMono(buffer: buffer)
        XCTAssertEqual(result.format.channelCount, 1)
        XCTAssertEqual(result.floatChannelData?[0][0] ?? 0, 0.7, accuracy: 0.001)
    }

    func testAdaptiveGainProtectsLoudSignalFromDistortion() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100) else {
            XCTFail("Could not create test audio buffer")
            return
        }
        buffer.frameLength = 100
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Missing floatChannelData")
            return
        }

        // Fill with loud normal voice (e.g. 0.5)
        for i in 0..<100 {
            channelData[i] = 0.5
        }

        // Even with 3.5x gain, adaptive headroom should scale effective gain so signal stays <= 0.76 (strictly linear)
        _ = SpeechEngine.processAudioBuffer(buffer: buffer, gain: 3.5)
        XCTAssertLessThanOrEqual(channelData[0], 0.76)
        XCTAssertGreaterThan(channelData[0], 0.5)
    }

    func testTurnRotationOnSilenceClearsCurrentUtterance() {
        let engine = SpeechEngine()
        engine.testEmitUtterance("First sentence from professor.")
        XCTAssertEqual(engine.transcripts.count, 1)
        XCTAssertEqual(engine.transcripts.first?.text, "First sentence from professor.")
        XCTAssertEqual(engine.activePartialText, "")

        // Next sentence should be clean and not concatenated with first sentence
        engine.testEmitUtterance("Second sentence starts fresh.")
        XCTAssertEqual(engine.transcripts.count, 2)
        XCTAssertEqual(engine.transcripts[1].text, "Second sentence starts fresh.")
    }

    func testExtractDeltaVariants() {
        // Initial utterance
        XCTAssertEqual(SpeechEngine.extractDelta(full: "所以", committed: ""), "所以")

        // Subsequent Cantonese with spaces
        XCTAssertEqual(SpeechEngine.extractDelta(full: "所以 最緊要有足夠嘅水份啦", committed: "所以"), "最緊要有足夠嘅水份啦")

        // Third utterance
        XCTAssertEqual(SpeechEngine.extractDelta(full: "所以 最緊要有足夠嘅水份啦 咁", committed: "所以 最緊要有足夠嘅水份啦"), "咁")

        // Continuous Chinese without spaces
        XCTAssertEqual(SpeechEngine.extractDelta(full: "最緊要有足夠嘅水份啦咁", committed: "最緊要有足夠嘅水份啦"), "咁")

        // Identical returns empty (prevents duplicate emissions)
        XCTAssertEqual(SpeechEngine.extractDelta(full: "所以", committed: "所以"), "")

        // English multi-word
        XCTAssertEqual(SpeechEngine.extractDelta(full: "Hello world how are you", committed: "Hello world"), "how are you")
    }

    func testContinuousRecordingMultipleConsecutiveTurns() {
        let engine = SpeechEngine()
        engine.testEmitUtterance("所以")
        engine.testEmitUtterance("最緊要有足夠嘅水份啦")
        engine.testEmitUtterance("咁")
        engine.testEmitUtterance("大家記得飲水")

        XCTAssertEqual(engine.transcripts.count, 4)
        XCTAssertEqual(engine.transcripts[0].text, "所以")
        XCTAssertEqual(engine.transcripts[1].text, "最緊要有足夠嘅水份啦")
        XCTAssertEqual(engine.transcripts[2].text, "咁")
        XCTAssertEqual(engine.transcripts[3].text, "大家記得飲水")
    }

    func testChineseNoSpaceMultiCommit() {
        var committed = "你好嗎"
        let r1 = SpeechEngine.extractDelta(full: "你好嗎我很好", committed: committed)
        XCTAssertEqual(r1, "我很好")
        committed = "你好嗎我很好"

        let r2 = SpeechEngine.extractDelta(full: "你好嗎我很好今天", committed: committed)
        XCTAssertEqual(r2, "今天") // Claude finding: verifies that "今" is not dropped

        let r3 = SpeechEngine.extractDelta(full: "你好嗎我很好今天天氣好", committed: "你好嗎我很好今天")
        XCTAssertEqual(r3, "天氣好")
    }
}
