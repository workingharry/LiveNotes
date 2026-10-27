import Foundation

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int = 5
    public var base: TimeInterval = 2.0
    public var cap: TimeInterval = 30.0

    public init(maxAttempts: Int = 5, base: TimeInterval = 2.0, cap: TimeInterval = 30.0) {
        self.maxAttempts = max(1, maxAttempts)
        self.base = max(0, base)
        self.cap = cap
    }

    public func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter = retryAfter, retryAfter.isFinite && !retryAfter.isNaN {
            return min(max(retryAfter, 1.0), 60.0)
        }
        guard cap > 0 else { return 0 }
        let safeAttempt = min(max(0, attempt), 20)
        let exponential = base * pow(2.0, Double(safeAttempt))
        let ceiling = min(exponential, cap)
        guard ceiling > 0 else { return 0 }
        return Double.random(in: 0...ceiling)
    }
}

public struct StreamResult: Sendable {
    public let success: Bool
    public let statusCode: Int
    public let retryAfter: TimeInterval?

    public init(success: Bool, statusCode: Int, retryAfter: TimeInterval? = nil) {
        self.success = success
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

@MainActor
public class OpenRouterService: ObservableObject {
    @Published public var currentSummary: String = ""
    @Published public var isSummarizing: Bool = false
    @Published public var lastUpdated: String = ""
    @Published public var currentMode: NoteMode = .studentLecture
    @Published public var activeCourseName: String = ""
    @Published public var summaryIntervalSeconds: Double = 60.0
    
    // Ask Copilot state
    @Published public var copilotAnswer: String = ""
    @Published public var isCopilotQuerying: Bool = false
    @Published public var copilotError: String? = nil

    public var apiKey: String = ""
    public var model: String = "openrouter/free"
    public var retryPolicy = RetryPolicy()
    public var transport: (@MainActor (String) async -> StreamResult)?
    public var sessionsRoot: URL?
    private var currentSessionId = UUID()
    
    public private(set) var allTranscripts: [String] = []
    public private(set) var pendingTranscripts: [String] = []
    private var timer: Timer?
    private var activeSessionFolder: URL?
    private var needsFollowupCycle: Bool = false

    public var systemPrompt: String {
        return currentMode.systemPrompt
    }

    public init() {
        if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !envKey.isEmpty {
            self.apiKey = envKey
        }
        if let savedKey = UserDefaults.standard.string(forKey: "OpenRouterAPIKey"), !savedKey.isEmpty {
            self.apiKey = savedKey
        }
        if let savedModel = UserDefaults.standard.string(forKey: "OpenRouterModel"), !savedModel.isEmpty {
            self.model = savedModel
        }
        if let savedMode = UserDefaults.standard.string(forKey: "LiveNotesNoteMode"),
           let mode = NoteMode(rawValue: savedMode) {
            self.currentMode = mode
        }
        if let savedCourse = UserDefaults.standard.string(forKey: "LiveNotesCourseName") {
            self.activeCourseName = savedCourse
        }
        let savedInterval = UserDefaults.standard.double(forKey: "OpenRouterSummaryInterval")
        if savedInterval >= 15.0 {
            self.summaryIntervalSeconds = savedInterval
        } else {
            self.summaryIntervalSeconds = 60.0
        }
    }

    public func updateSummaryInterval(_ seconds: Double) {
        let clamped = max(15.0, min(seconds, 600.0))
        self.summaryIntervalSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: "OpenRouterSummaryInterval")
        
        // If a session is active and timer is running, reschedule immediately
        if timer != nil {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerSummaryCycle()
                }
            }
        }
    }

    public func startSession() {
        currentSessionId = UUID()
        needsFollowupCycle = false
        allTranscripts.removeAll()
        pendingTranscripts.removeAll()
        currentSummary = ""
        copilotAnswer = ""
        copilotError = nil
        
        let docs = sessionsRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("LiveNotes")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let prefix = currentMode == .studentLecture ? "Lecture" : "Meeting"
        let folderName = "\(prefix)_\(formatter.string(from: Date()))"
        activeSessionFolder = docs.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: activeSessionFolder!, withIntermediateDirectories: true)

        timer?.invalidate()
        let interval = max(15.0, summaryIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerSummaryCycle()
            }
        }
    }

    public func addTranscript(text: String, timestamp: String) {
        let entry = "[\(timestamp)] \(text)"
        allTranscripts.append(entry)
        pendingTranscripts.append(entry)
        
        // Append to transcript.txt on disk
        if let folder = activeSessionFolder {
            let file = folder.appendingPathComponent("transcript.txt")
            let line = "\(entry)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: file.path) {
                    if let handle = try? FileHandle(forWritingTo: file) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: file)
                }
            }
        }
    }

    public func stopSession() {
        timer?.invalidate()
        timer = nil
        if !pendingTranscripts.isEmpty {
            if isSummarizing {
                needsFollowupCycle = true
            } else {
                triggerSummaryCycle(force: true)
            }
        }
    }

    public func triggerSummaryCycle(force: Bool = false) {
        guard !isSummarizing else { return }
        guard !pendingTranscripts.isEmpty else { return }
        
        let joinedText = pendingTranscripts.joined(separator: " ")
        let wordsCount = joinedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let cjkCount = joinedText.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }.count
        guard force || wordsCount >= 12 || cjkCount >= 15 else { return }

        let chunkToSummarize = pendingTranscripts.joined(separator: "\n")
        let snapshotCount = pendingTranscripts.count
        let contextTail = allTranscripts.suffix(5).joined(separator: "\n")
        let captureSessionId = currentSessionId

        isSummarizing = true

        let userPrompt = """
        ### PREVIOUS MEETING NOTES (Memory):
        \(currentSummary.isEmpty ? "(Meeting just started. No previous notes.)" : currentSummary)

        ### RECENT CONTEXT:
        \(contextTail)

        ### NEW TRANSCRIPT LINES TO INCORPORATE:
        \(chunkToSummarize)

        Update and output the revised structured meeting notes:
        """

        Task {
            let success = await requestOpenRouterStreamWithRetry(userPrompt: userPrompt)
            guard self.currentSessionId == captureSessionId else {
                self.isSummarizing = false
                return
            }
            if success {
                // Remove only the snapshot count so new lines arriving during streaming remain safe
                self.pendingTranscripts.removeFirst(min(snapshotCount, self.pendingTranscripts.count))
            }
            self.isSummarizing = false
            if self.needsFollowupCycle && !self.pendingTranscripts.isEmpty {
                self.needsFollowupCycle = false
                self.triggerSummaryCycle(force: true)
            }
        }
    }

    public static func isSSEError(line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return false }

        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return false
        }
        return json["error"] != nil
    }

    public static func parseSSEChunk(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return nil }

        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    public func requestOpenRouterStreamWithRetry(userPrompt: String) async -> Bool {
        for attempt in 0..<retryPolicy.maxAttempts {
            if Task.isCancelled { return false }
            let res: StreamResult
            if let customTransport = transport {
                res = await customTransport(userPrompt)
            } else {
                let (ok, code, ra) = await requestOpenRouterStream(userPrompt: userPrompt)
                res = StreamResult(success: ok, statusCode: code, retryAfter: ra)
            }

            if res.success {
                return true
            }

            // Don't sleep after the final attempt
            guard attempt < retryPolicy.maxAttempts - 1 else { break }

            // If 429 (rate limit) or 5xx (server queue/error), apply backoff jitter
            if res.statusCode == 429 || (res.statusCode >= 500 && res.statusCode < 600) {
                let delaySeconds = retryPolicy.delay(attempt: attempt, retryAfter: res.retryAfter)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                } catch {
                    return false
                }
            } else {
                // Non-retriable error
                break
            }
        }
        return false
    }

    private func requestOpenRouterStream(userPrompt: String) async -> (Bool, Int, TimeInterval?) {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return (false, 400, nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("https://localhost", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("LiveNotes macOS Native", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "stream": true,
            "temperature": 0.2,
            "reasoning": ["enabled": true]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return (false, 400, nil)
        }
        request.httpBody = httpBody

        let targetSessionId = currentSessionId
        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, 500, nil)
            }

            let retryAfterValue: TimeInterval? = {
                if let str = httpResponse.value(forHTTPHeaderField: "Retry-After"), let sec = Double(str) {
                    return sec
                }
                return nil
            }()

            guard (200...299).contains(httpResponse.statusCode) else {
                return (false, httpResponse.statusCode, retryAfterValue)
            }

            var fullText = ""
            for try await rawLine in asyncBytes.lines {
                guard self.currentSessionId == targetSessionId else {
                    return (false, 499, nil)
                }
                if let deltaText = Self.parseSSEChunk(line: rawLine) {
                    fullText += deltaText
                    self.currentSummary = fullText
                }
            }

            guard self.currentSessionId == targetSessionId else {
                return (false, 499, nil)
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            self.lastUpdated = formatter.string(from: Date())

            // Save summary.md to session folder
            if let folder = activeSessionFolder, !fullText.isEmpty {
                let summaryPath = folder.appendingPathComponent("summary.md")
                let prefix = currentMode == .studentLecture ? "Lecture Notes" : "Meeting Notes"
                let content = "# \(prefix) (\(self.lastUpdated))\n\n\(fullText)\n"
                try? content.data(using: .utf8)?.write(to: summaryPath)
            }
            return (!fullText.isEmpty, httpResponse.statusCode, nil)
        } catch {
            print("OpenRouter stream error: \(error)")
            return (false, 500, nil)
        }
    }

    // MARK: - Ask Copilot Real-Time Query
    public func askCopilot(question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCopilotQuerying else { return }

        isCopilotQuerying = true
        copilotError = nil
        copilotAnswer = ""

        let contextTranscripts = allTranscripts.suffix(40).joined(separator: "\n")
        let isLecture = currentMode == .studentLecture
        let prompt = """
        ### \(isLecture ? "LECTURE NOTES & CONCEPTS" : "MEETING EXECUTIVE NOTES"):
        \(currentSummary.isEmpty ? "(No structured notes yet)" : currentSummary)

        ### RECENT TRANSCRIPT EXCERPTS:
        \(contextTranscripts.isEmpty ? "(No speech recorded yet)" : contextTranscripts)

        ### \(isLecture ? "STUDENT QUESTION" : "USER QUESTION"):
        \(trimmed)

        Please answer the question accurately based ONLY on the \(isLecture ? "lecture" : "meeting") transcript and notes above. If the information was not mentioned, explicitly state that it was not discussed.
        """

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            isCopilotQuerying = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("https://localhost", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("LiveNotes macOS Native Copilot", forHTTPHeaderField: "X-Title")

        let assistantRole = isLecture 
            ? "You are an expert university teaching assistant and tutor. Help the student understand concepts, formulas, exam tips, and assignments based on the provided lecture context."
            : "You are a concise, helpful meeting assistant. Answer accurately based on the provided meeting context."

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": assistantRole],
                ["role": "user", "content": prompt]
            ],
            "stream": true,
            "temperature": 0.3
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            isCopilotQuerying = false
            return
        }
        request.httpBody = httpBody

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                self.copilotError = "Failed to query Copilot (API error)."
                self.isCopilotQuerying = false
                return
            }

            var answer = ""
            for try await rawLine in asyncBytes.lines {
                if let deltaText = Self.parseSSEChunk(line: rawLine) {
                    answer += deltaText
                    self.copilotAnswer = answer
                }
            }
        } catch {
            self.copilotError = "Copilot query failed: \(error.localizedDescription)"
        }

        self.isCopilotQuerying = false
    }
}
