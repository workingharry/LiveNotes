import Foundation
import Speech
import AVFoundation

public struct TranscriptEntry: Identifiable, Equatable {
    public let id: UUID
    public let timestamp: String
    public let text: String

    public init(id: UUID = UUID(), timestamp: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

public enum PermissionType: Equatable {
    case speech
    case microphone
    case unknown
}

public enum SpeechErrorKind: Equatable {
    case ignorable
    case retryQuietly
    case fatal
}

public enum MicSensitivity: Double, CaseIterable, Identifiable, Sendable {
    case normal = 1.0         // 1.0x (0 dB) - 近距離
    case classroom = 2.0      // 2.0x (+6 dB) - 教室中距
    case lectureHall = 3.5    // 3.5x (+11 dB) - 階梯講堂遠距 (推薦)
    case ultra = 5.0          // 5.0x (+14 dB) - 超遠距/講者低語

    public var id: Double { rawValue }

    public var title: String {
        switch self {
        case .normal: return "1.0x (標準近距 0dB)"
        case .classroom: return "2.0x (教室中距 +6dB)"
        case .lectureHall: return "3.5x (講堂遠距 +11dB 推薦)"
        case .ultra: return "5.0x (超遠距/低音量 +14dB)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .normal: return "1.0x 近距"
        case .classroom: return "2.0x 教室"
        case .lectureHall: return "3.5x 講堂"
        case .ultra: return "5.0x 增強"
        }
    }
}

@MainActor
public class SpeechEngine: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published public var isRecording: Bool = false
    @Published public var isAuthorizing: Bool = false
    @Published public var transcripts: [TranscriptEntry] = []
    @Published public var activePartialText: String = ""
    @Published public var errorMessage: String? = nil
    @Published public var failedPermission: PermissionType = .unknown
    @Published public var sensitivity: MicSensitivity = .lectureHall
    @Published public var audioLevel: Float = 0.0
    public var contextualStrings: [String] = []
    
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastEmittedText: String = ""
    private var currentUtterance: String = ""
    private var currentFullText: String = ""
    private var committedPrefix: String = ""
    private var isTapInstalled: Bool = false
    public private(set) var currentLocale: String = "zh-HK"

    public var onNewTurn: ((String) -> Void)?

    public override init() {
        super.init()
        if let savedSens = UserDefaults.standard.object(forKey: "LiveNotesMicSensitivity") as? Double,
           let sens = MicSensitivity(rawValue: savedSens) {
            self.sensitivity = sens
        } else {
            self.sensitivity = .lectureHall
        }
    }

    public func setContextualTerms(_ terms: [String]) {
        self.contextualStrings = terms.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func updateSensitivity(_ newSens: MicSensitivity) {
        self.sensitivity = newSens
        UserDefaults.standard.set(newSens.rawValue, forKey: "LiveNotesMicSensitivity")
    }

    public static func permissionFailure(mic: AVAuthorizationStatus, speech: SFSpeechRecognizerAuthorizationStatus) -> (PermissionType, String)? {
        if mic == .denied || mic == .restricted {
            return (.microphone, "Microphone access is not permitted. Enable LiveNotes in System Settings > Privacy & Security > Microphone.")
        }
        if speech == .denied || speech == .restricted {
            return (.speech, "Speech recognition was denied. Please allow LiveNotes in System Settings > Privacy & Security > Speech Recognition.")
        }
        if speech == .notDetermined {
            return (.speech, "Speech recognition permission is required to transcribe meetings.")
        }
        if mic != .authorized || speech != .authorized {
            return (.unknown, "Audio or speech permission has not been granted.")
        }
        return nil
    }

    public static func classify(_ error: NSError) -> SpeechErrorKind {
        if error.code == 216 || error.code == 301 || error.code == 203 {
            return .ignorable
        }
        if error.code == 1110 {
            return .retryQuietly
        }
        if error.code == 1101 {
            return .fatal
        }
        return .retryQuietly
    }

    public func updateLocale(_ localeId: String) {
        self.currentLocale = localeId
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        self.recognizer?.delegate = self
    }

    public func startRecording(localeId: String) {
        self.currentLocale = localeId
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        self.recognizer?.delegate = self
        self.errorMessage = nil
        self.failedPermission = .unknown
        self.isAuthorizing = true
        self.lastEmittedText = ""

        // 1. Verify Microphone Access First
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            self.checkSpeechAuthorization()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.checkSpeechAuthorization()
                    } else {
                        self.isAuthorizing = false
                        self.isRecording = false
                        self.failedPermission = .microphone
                        self.errorMessage = "Microphone access was denied. Please allow LiveNotes in System Settings > Privacy & Security > Microphone."
                    }
                }
            }
        case .denied, .restricted:
            self.isAuthorizing = false
            self.isRecording = false
            self.failedPermission = .microphone
            self.errorMessage = "Microphone access is not permitted. Enable LiveNotes in System Settings > Privacy & Security > Microphone."
        @unknown default:
            self.isAuthorizing = false
            self.isRecording = false
            self.errorMessage = "Unknown microphone permission status."
        }
    }

    private func checkSpeechAuthorization() {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            self.isAuthorizing = false
            self.beginAudioSession()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isAuthorizing = false
                    if newStatus == .authorized {
                        self.beginAudioSession()
                    } else {
                        let failure = Self.permissionFailure(mic: .authorized, speech: newStatus)
                        self.failedPermission = failure?.0 ?? .speech
                        self.errorMessage = failure?.1 ?? "Speech recognition access denied."
                        self.isRecording = false
                    }
                }
            }
        case .denied, .restricted:
            self.isAuthorizing = false
            let failure = Self.permissionFailure(mic: .authorized, speech: status)
            self.failedPermission = failure?.0 ?? .speech
            self.errorMessage = failure?.1 ?? "Speech recognition access denied."
            self.isRecording = false
        @unknown default:
            self.isAuthorizing = false
            self.errorMessage = "Unknown speech authorization status."
            self.isRecording = false
        }
    }

    private func beginAudioSession() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            self.errorMessage = "Speech recognizer is currently unavailable for locale \(currentLocale)."
            self.isRecording = false
            return
        }

        // Fresh engine instance per recording session to avoid dead CoreAudio HAL states
        if let old = audioEngine {
            if old.isRunning { old.stop() }
            if isTapInstalled {
                old.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            old.reset()
        }

        self.committedPrefix = ""
        self.currentUtterance = ""
        self.activePartialText = ""

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode

        // Use native hardware capture format (standard 1-channel mono 48kHz Float32).
        // Note: Do NOT call setVoiceProcessingEnabled(true) on macOS; on MacBook arrays it switches
        // to a 7-channel beamforming diagnostic layout that SFSpeechAudioBufferRecognitionRequest rejects with Code 1110.
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            self.errorMessage = "Microphone input format is invalid (sample rate or channels are 0). Please check your default input device in System Settings."
            self.isRecording = false
            return
        }

        self.startRecognitionTask()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let gain = Float(self.sensitivity.rawValue)
            let level = Self.processAudioBuffer(buffer: buffer, gain: gain)
            DispatchQueue.main.async {
                self.audioLevel = level
            }
            let monoBuffer = Self.convertToMono(buffer: buffer)
            self.request?.append(monoBuffer)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            self.isRecording = true
            self.errorMessage = nil
            self.failedPermission = .unknown
        } catch {
            let nsError = error as NSError
            if nsError.code == 1937010544 {
                self.failedPermission = .microphone
                self.errorMessage = "Audio hardware was stopped. If you just granted permissions, please restart LiveNotes to activate audio capture."
            } else {
                self.errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            }
            self.isRecording = false
        }
    }

    public func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        commitCurrentUtterance(isFinal: true)
        
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            engine.reset()
        }
        audioEngine = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        isAuthorizing = false
        activePartialText = ""
        currentUtterance = ""
        committedPrefix = ""
        audioLevel = 0.0
    }

    // Single-pole envelope follower state to prevent inter-buffer gain pumping
    private static var smoothEnvelope: Float = 0.0

    @discardableResult
    public static func processAudioBuffer(buffer: AVAudioPCMBuffer, gain: Float) -> Float {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        // Step 1: Measure peak sample across channels
        var rawPeak: Float = 0
        for ch in 0..<channelCount {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameLength {
                let absVal = abs(channelData[i])
                if absVal > rawPeak { rawPeak = absVal }
            }
        }

        // Single-pole envelope follower (fast attack 0.7, smooth release 0.05)
        let attack: Float = 0.7
        let release: Float = 0.05
        if rawPeak > smoothEnvelope {
            smoothEnvelope = smoothEnvelope + attack * (rawPeak - smoothEnvelope)
        } else {
            smoothEnvelope = smoothEnvelope + release * (rawPeak - smoothEnvelope)
        }

        // Adaptive Dynamic Headroom:
        // Use peak detection with smooth envelope follower to catch immediate attacks without clipping
        let peakThreshold = max(rawPeak, smoothEnvelope)
        let targetPeak: Float = 0.75
        let effectiveGain: Float
        if peakThreshold > 0.001 && peakThreshold * gain > targetPeak {
            effectiveGain = max(1.0, targetPeak / peakThreshold)
        } else {
            effectiveGain = gain
        }

        var sumSquares: Float = 0
        var totalSamples: Int = 0

        for ch in 0..<channelCount {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameLength {
                let raw = channelData[i]
                let amplified = raw * effectiveGain

                // Soft-knee saturation limiter: strictly linear within [-0.8, 0.8], smooth hyperbolic saturation beyond
                let clipped: Float
                if amplified > 0.8 {
                    clipped = 0.8 + 0.2 * tanh((amplified - 0.8) / 0.2)
                } else if amplified < -0.8 {
                    clipped = -0.8 + 0.2 * tanh((amplified + 0.8) / 0.2)
                } else {
                    clipped = amplified
                }

                channelData[i] = clipped
                sumSquares += clipped * clipped
                totalSamples += 1
            }
        }

        let rms = totalSamples > 0 ? sqrt(sumSquares / Float(totalSamples)) : 0
        return min(1.0, rms * 4.0) // Normalized 0.0 - 1.0 for UI audio meter
    }

    public static func convertToMono(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channelCount = Int(buffer.format.channelCount)
        if channelCount <= 1 {
            return buffer
        }

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
            return buffer
        }

        monoBuffer.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)

        guard let dest = monoBuffer.floatChannelData?[0] else { return buffer }

        // Equal-Power Sum / Average across active channels
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += buffer.floatChannelData?[ch][i] ?? 0
            }
            dest[i] = sum * scale
        }

        return monoBuffer
    }

    public static func extractDelta(full: String, committed: String) -> String {
        let trimmedFull = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommitted = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommitted.isEmpty { return trimmedFull }

        // Fast path: exact prefix match
        if trimmedFull.hasPrefix(trimmedCommitted) {
            let remainder = trimmedFull.dropFirst(trimmedCommitted.count)
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }

        // Normalized matching: ignore spaces and punctuation to find alignment in full text
        // (Prevents dropped Chinese/Cantonese characters caused by spacing/punctuation drift)
        let committedNorm = trimmedCommitted.filter { !$0.isWhitespace && !$0.isPunctuation }
        if committedNorm.isEmpty { return trimmedFull }

        var normMatched = 0
        var matchEndIndex = trimmedFull.startIndex

        for idx in trimmedFull.indices {
            let ch = trimmedFull[idx]
            if ch.isWhitespace || ch.isPunctuation {
                continue
            }
            if normMatched < committedNorm.count {
                let normChar = committedNorm[committedNorm.index(committedNorm.startIndex, offsetBy: normMatched)]
                if ch == normChar {
                    normMatched += 1
                    matchEndIndex = trimmedFull.index(after: idx)
                } else {
                    normMatched = 0
                }
            }
        }

        if normMatched == committedNorm.count {
            let remainder = trimmedFull[matchEndIndex...]
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }

        if trimmedFull.count > trimmedCommitted.count {
            let remainder = trimmedFull.suffix(trimmedFull.count - trimmedCommitted.count)
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }

        return ""
    }

    private func createRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        if !contextualStrings.isEmpty {
            req.contextualStrings = contextualStrings
        }
        return req
    }

    private func startRecognitionTask() {
        guard let recognizer = recognizer, recognizer.isAvailable else { return }

        let req = createRecognitionRequest()
        self.request = req

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let result = result {
                    let fullText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    let delta = Self.extractDelta(full: fullText, committed: self.committedPrefix)
                    if !delta.isEmpty {
                        self.currentUtterance = delta
                        self.currentFullText = fullText
                        self.activePartialText = delta
                        self.resetSilenceTimer()
                    }
                    if result.isFinal {
                        self.commitCurrentUtterance(isFinal: true)
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    let kind = Self.classify(nsError)
                    switch kind {
                    case .ignorable:
                        break
                    case .retryQuietly:
                        self.restartTask()
                    case .fatal:
                        self.errorMessage = "Speech recognition disabled: \(nsError.localizedDescription)"
                        self.stopRecording()
                    }
                }
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.commitCurrentUtterance(isFinal: false)
            }
        }
    }

    private func commitCurrentUtterance(isFinal: Bool) {
        let text = currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty && text != lastEmittedText else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())

        let entry = TranscriptEntry(timestamp: timeStr, text: text)
        self.transcripts.append(entry)
        self.onNewTurn?(text)

        // Advance the committed prefix so subsequent speech delta is cleanly extracted.
        // We sync directly with the recognizer's fullText to prevent artificial spacing drift.
        if !self.currentFullText.isEmpty {
            self.committedPrefix = self.currentFullText
        } else if self.committedPrefix.isEmpty {
            self.committedPrefix = text
        } else {
            self.committedPrefix += text
        }

        self.lastEmittedText = text
        self.activePartialText = ""
        self.currentUtterance = ""

        if isFinal {
            self.committedPrefix = ""
            self.currentFullText = ""
            self.restartTask()
        }
    }

    public func testEmitUtterance(_ text: String) {
        self.currentUtterance = text
        if self.currentFullText.isEmpty {
            self.currentFullText = text
        } else {
            self.currentFullText += text
        }
        self.commitCurrentUtterance(isFinal: false)
    }

    private func restartTask() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        let oldReq = request
        let oldTask = task
        self.request = nil
        self.task = nil
        oldReq?.endAudio()
        oldTask?.cancel()

        guard let engine = audioEngine, engine.isRunning, let recognizer = recognizer, recognizer.isAvailable else { return }

        self.committedPrefix = ""
        self.currentFullText = ""
        self.startRecognitionTask()
    }
}
