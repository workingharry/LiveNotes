import SwiftUI
import AppKit
import LiveNotesCore

@main
struct LiveNotesApp: App {
    @StateObject private var speech = SpeechEngine()
    @StateObject private var summarizer = OpenRouterService()
    @StateObject private var history = MeetingHistoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView(speech: speech, summarizer: summarizer, history: history)
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var summarizer: OpenRouterService
    @ObservedObject var history: MeetingHistoryStore

    @State private var selectedLocale: String = "zh-HK"
    @State private var selectedModel: String = "openrouter/free"
    @State private var showSettings: Bool = false
    @State private var showHistorySidebar: Bool = false
    @State private var selectedHistoricalSession: MeetingSessionItem? = nil
    @State private var copilotQuestion: String = ""
    @State private var toastMessage: String? = nil
    @State private var courseInput: String = ""

    let locales = [
        ("zh-HK", "粵語 (Hong Kong)"),
        ("zh-CN", "普通話 (Mandarin)"),
        ("en-US", "English (US)")
    ]

    let models = [
        ("openrouter/free", "openrouter/free (Auto)"),
        ("minimax/minimax-m3.1-flash:free", "MiniMax M3.1 Flash"),
        ("meta-llama/llama-3.3-70b-instruct:free", "Llama 3.3 70B"),
        ("google/gemini-2.0-flash-exp:free", "Gemini 2.0 Flash")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar Header
            HStack(spacing: 12) {
                // Sidebar Toggle Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showHistorySidebar.toggle()
                        if showHistorySidebar { history.refresh() }
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14))
                }
                .help("Toggle Meeting History Sidebar")

                // Brand
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live Notes")
                            .font(.headline)
                        Text("Apple Speech + OpenRouter AI")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .fixedSize()

                if let archive = selectedHistoricalSession {
                    HStack(spacing: 6) {
                        Text("Viewing Archive: \(archive.dateDisplay)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(6)
                        Button("Return to Live") {
                            selectedHistoricalSession = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()

                // Mode Picker (Student Lecture vs Business Meeting)
                Picker("Mode", selection: $summarizer.currentMode) {
                    ForEach(NoteMode.allCases) { mode in
                        Label(mode.shortTitle, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: summarizer.currentMode) { newMode in
                    UserDefaults.standard.set(newMode.rawValue, forKey: "LiveNotesNoteMode")
                }

                // Language Picker
                Picker("Language", selection: $selectedLocale) {
                    ForEach(locales, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)
                .disabled(speech.isRecording || speech.isAuthorizing)

                // Model Picker
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 175)
                .onChange(of: selectedModel) { newModel in
                    summarizer.model = newModel
                }

                // Far-Field Mic Sensitivity Picker
                Picker("收音", selection: $speech.sensitivity) {
                    ForEach(MicSensitivity.allCases) { sens in
                        Text(sens.shortTitle).tag(sens)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 105)
                .onChange(of: speech.sensitivity) { newSens in
                    speech.updateSensitivity(newSens)
                }
                .help("麥克風遠距增益 (Hardware AGC + Soft-Limiter Pre-Amp)")

                // Record / Stop Button with fixed size to prevent text clipping
                Button(action: toggleRecording) {
                    HStack(spacing: 6) {
                        if speech.isAuthorizing {
                            ProgressView().controlSize(.mini)
                            Text("Starting...")
                                .fontWeight(.semibold)
                        } else {
                            Circle()
                                .fill(speech.isRecording ? Color.red : Color.green)
                                .frame(width: 8, height: 8)
                            Text(speech.isRecording ? "Stop Listening" : (summarizer.currentMode == .studentLecture ? "開始課堂錄音" : "Start Listening"))
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(speech.isRecording ? .red : .blue)
                .disabled(speech.isAuthorizing)
                .fixedSize()

                // Sync & Export Menu (Obsidian, Notion, Markdown)
                Menu {
                    Button(action: syncToObsidian) {
                        Label("同步至 Obsidian Vault", systemImage: "folder.badge.plus")
                    }
                    Button(action: copyForNotion) {
                        Label("複製為 Notion 格式 (Cmd+V 直接貼上)", systemImage: "doc.on.clipboard")
                    }
                    Button(action: syncToNotionAPI) {
                        Label("同步至 Notion 資料庫 (API)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                    Button(action: exportNotes) {
                        Label("匯出為 Markdown (.md)", systemImage: "square.and.arrow.down")
                    }
                    Button(action: copyToClipboard) {
                        Label("複製純文字", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("同步 / 匯出", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderedButton)

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            // Toast Notification Banner
            if let toast = toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(toast)
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Button(action: { toastMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.green.opacity(0.3)), alignment: .bottom)
            }

            // Error & Permission Warning Banner
            if let errorMsg = speech.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 16))
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                    
                    Button("Restart App") {
                        let url = Bundle.main.bundleURL
                        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Open Privacy Settings") {
                        let pane = (speech.failedPermission == .microphone) ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Dismiss") {
                        speech.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.15))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.yellow.opacity(0.4)), alignment: .bottom)
            }

            Divider()

            // Main Workspace (SplitView)
            HSplitView {
                // Optional History Sidebar
                if showHistorySidebar {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label("PAST MEETINGS", systemImage: "folder.fill")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { history.refresh() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Refresh History")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))

                        Divider()

                        if history.sessions.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                Text("No saved meetings yet.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(history.sessions, id: \.self, selection: $selectedHistoricalSession) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.dateDisplay)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(item.id)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .listStyle(.sidebar)
                        }
                    }
                    .frame(minWidth: 180, maxWidth: 240)
                }

                // Left Pane: Speech Transcript (Live or Archived)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(selectedHistoricalSession == nil ? "SPEECH TRANSCRIPT" : "ARCHIVED TRANSCRIPT", systemImage: "mic.fill")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        if speech.isRecording && selectedHistoricalSession == nil {
                            HStack(spacing: 6) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Listening (\(speech.sensitivity.shortTitle))")
                                    .font(.caption2)
                                    .foregroundColor(.green)

                                HStack(spacing: 2) {
                                    ForEach(0..<4) { index in
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(speech.audioLevel > Float(index) * 0.2 ? Color.green : Color.secondary.opacity(0.3))
                                            .frame(width: 3, height: CGFloat(5) + CGFloat(index) * 2.5)
                                    }
                                }
                                .help("即時收音音量訊號")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if let archive = selectedHistoricalSession {
                                    Text(archive.transcriptSnippet.isEmpty ? "No transcript recorded for this session." : archive.transcriptSnippet)
                                        .font(.system(size: 13))
                                        .textSelection(.enabled)
                                        .padding(14)
                                } else {
                                    if speech.transcripts.isEmpty && speech.activePartialText.isEmpty {
                                        VStack(spacing: 8) {
                                            Image(systemName: "mic.badge.plus")
                                                .font(.system(size: 32))
                                                .foregroundColor(.secondary.opacity(0.6))
                                            Text("Click Start Listening and speak into your mic.")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            Text("Transcribed on-device via Apple Speech.framework")
                                                .font(.caption2)
                                                .foregroundColor(.secondary.opacity(0.7))
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 200)
                                        .padding(.top, 40)
                                    }

                                    ForEach(speech.transcripts) { entry in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.timestamp)
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Text(entry.text)
                                                .font(.system(size: 13))
                                                .textSelection(.enabled)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                                        .cornerRadius(8)
                                        .id(entry.id)
                                    }

                                    // Active ongoing partial speech
                                    if !speech.activePartialText.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Live...")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.blue)
                                            Text(speech.activePartialText)
                                                .font(.system(size: 13, weight: .regular))
                                                .italic()
                                                .foregroundColor(.primary.opacity(0.85))
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.blue.opacity(0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                                        .id("active_partial")
                                    }
                                }
                            }
                            .padding(14)
                        }
                        .onChange(of: speech.transcripts.count) { _ in
                            if let last = speech.transcripts.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(minWidth: 320)

                // Right Pane: AI Structured Notes + Copilot Query Bar
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(selectedHistoricalSession == nil 
                            ? (summarizer.currentMode == .studentLecture ? "📚 課堂重點筆記 (STUDENT LECTURE)" : "💼 會議決策與待辦 (MEETING NOTES)") 
                            : "ARCHIVED NOTES", 
                            systemImage: summarizer.currentMode.icon)
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        if summarizer.isSummarizing && selectedHistoricalSession == nil {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Updating...")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        } else if !summarizer.lastUpdated.isEmpty {
                            Text("Updated \(summarizer.lastUpdated)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    // Structured Notes Content
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let archive = selectedHistoricalSession {
                                Text(.init(archive.summarySnippet.isEmpty ? "No notes recorded for this session." : archive.summarySnippet))
                                    .font(.system(size: 13, weight: .regular))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                if summarizer.currentSummary.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .font(.system(size: 32))
                                            .foregroundColor(.secondary.opacity(0.6))
                                        Text("Structured notes will appear as speech accumulates.")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Text("Updated every 25 seconds via OpenRouter AI")
                                            .font(.caption2)
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 200)
                                    .padding(.top, 40)
                                } else {
                                    Text(.init(summarizer.currentSummary))
                                        .font(.system(size: 13, weight: .regular))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                    }

                    // Copilot Answer Box (if active)
                    if summarizer.isCopilotQuerying || !summarizer.copilotAnswer.isEmpty || summarizer.copilotError != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Copilot Answer", systemImage: "sparkle.magnifyingglass")
                                    .font(.caption.bold())
                                    .foregroundColor(.purple)
                                Spacer()
                                if summarizer.isCopilotQuerying {
                                    ProgressView().controlSize(.mini)
                                }
                                Button(action: {
                                    summarizer.copilotAnswer = ""
                                    summarizer.copilotError = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            if let err = summarizer.copilotError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else if !summarizer.copilotAnswer.isEmpty {
                                Text(.init(summarizer.copilotAnswer))
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            } else if summarizer.isCopilotQuerying {
                                Text("Analyzing meeting transcript...")
                                    .font(.caption)
                                    .italic()
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.25), lineWidth: 1))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }

                    Divider()

                    // Student Copilot Quick Prompt Chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(summarizer.currentMode.defaultCopilotPrompts, id: \.self) { promptText in
                                Button(action: {
                                    copilotQuestion = promptText
                                    submitCopilotQuestion()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkle")
                                            .font(.system(size: 9))
                                        Text(promptText)
                                            .font(.system(size: 11))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.purple.opacity(0.12))
                                    .foregroundColor(.purple)
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    }

                    // Ask Copilot Input Bar
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.purple)
                            .font(.system(size: 14))

                        TextField(summarizer.currentMode == .studentLecture ? "向課堂 Copilot 提問 (例如：剛才提到的考試重點是什麼？)..." : "Ask Copilot about this meeting (e.g. What did John say?)...", text: $copilotQuestion)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .onSubmit {
                                submitCopilotQuestion()
                            }

                        Button(action: submitCopilotQuestion) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(copilotQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summarizer.isCopilotQuerying ? .secondary.opacity(0.5) : .purple)
                        }
                        .buttonStyle(.plain)
                        .disabled(copilotQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summarizer.isCopilotQuerying)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(minWidth: 400)
            }

            Divider()

            // Footer Status
            HStack {
                Text("Native Apple Speech Framework • Documents/LiveNotes")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("AI 間隔: \(Int(summarizer.summaryIntervalSeconds))s • 累計語句: \(speech.transcripts.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            speech.onNewTurn = { text in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                summarizer.addTranscript(text: text, timestamp: formatter.string(from: Date()))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(summarizer: summarizer, speech: speech)
        }
    }

    private func toggleRecording() {
        if speech.isRecording {
            speech.stopRecording()
            summarizer.stopSession()
            history.refresh()
        } else {
            selectedHistoricalSession = nil
            summarizer.model = selectedModel
            summarizer.startSession()
            if !summarizer.activeCourseName.isEmpty {
                let terms = summarizer.activeCourseName.components(separatedBy: CharacterSet(charactersIn: " ,/，、")).filter { !$0.isEmpty }
                speech.setContextualTerms(terms)
            }
            speech.startRecording(localeId: selectedLocale)
        }
    }

    private func submitCopilotQuestion() {
        let q = copilotQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        copilotQuestion = ""
        Task {
            await summarizer.askCopilot(question: q)
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func syncToObsidian() {
        let content = selectedHistoricalSession?.summarySnippet ?? summarizer.currentSummary
        guard !content.isEmpty else {
            showToast("⚠️ 尚無內容可同步至 Obsidian")
            return
        }

        let isLecture = summarizer.currentMode == .studentLecture
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let timestampStr = formatter.string(from: Date())
        let title = summarizer.activeCourseName.isEmpty 
            ? (isLecture ? "課堂筆記_\(timestampStr)" : "會議記錄_\(timestampStr)")
            : "\(summarizer.activeCourseName)_\(timestampStr)"

        let tags = isLecture ? ["lecture", "study", "notes", "university"] : ["meeting", "work", "notes"]
        let obsidianMd = ObsidianSyncService.generateObsidianMarkdown(title: title, content: content, tags: tags)

        let vaultPathStr = UserDefaults.standard.string(forKey: "ObsidianVaultPath")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vaultURL: URL
        if !vaultPathStr.isEmpty {
            let expanded = NSString(string: vaultPathStr).expandingTildeInPath
            vaultURL = URL(fileURLWithPath: expanded)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            vaultURL = docs.appendingPathComponent("Obsidian Vault").appendingPathComponent("LiveNotes")
        }

        do {
            let savedFile = try ObsidianSyncService.saveToVault(vaultURL: vaultURL, noteName: title, markdown: obsidianMd)
            showToast("✅ 已同步至 Obsidian Vault: \(savedFile.lastPathComponent)")
            
            // Open the exact saved file in Obsidian without creating a duplicate note
            if let openURL = ObsidianSyncService.buildObsidianOpenFileURL(fileURL: savedFile) {
                NSWorkspace.shared.open(openURL)
            }
        } catch {
            showToast("❌ Obsidian 存檔失敗: \(error.localizedDescription)")
        }
    }

    private func copyForNotion() {
        let content = selectedHistoricalSession?.summarySnippet ?? summarizer.currentSummary
        guard !content.isEmpty else {
            showToast("⚠️ 尚無內容可供複製")
            return
        }
        let title = summarizer.activeCourseName.isEmpty 
            ? (summarizer.currentMode == .studentLecture ? "課堂筆記" : "會議記錄")
            : summarizer.activeCourseName
        let formatted = NotionSyncService.formatForNotionClipboard(title: title, markdown: content)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatted, forType: .string)
        showToast("📋 已複製 Notion 相容格式！在 Notion 頁面按 Cmd+V 即可貼上")
    }

    private func syncToNotionAPI() {
        let content = selectedHistoricalSession?.summarySnippet ?? summarizer.currentSummary
        guard !content.isEmpty else {
            showToast("⚠️ 尚無內容可同步至 Notion")
            return
        }
        let apiKey = UserDefaults.standard.string(forKey: "NotionAPIKey") ?? ""
        let dbId = UserDefaults.standard.string(forKey: "NotionDatabaseID") ?? ""

        guard !apiKey.isEmpty && !dbId.isEmpty else {
            showToast("⚠️ 請先在設定 (⚙️) 中填寫 Notion API Key 與 Database ID")
            showSettings = true
            return
        }

        let isLecture = summarizer.currentMode == .studentLecture
        let title = summarizer.activeCourseName.isEmpty 
            ? (isLecture ? "課堂筆記 \(Date().formatted(.dateTime.year().month().day()))" : "會議記錄 \(Date().formatted(.dateTime.year().month().day()))")
            : "\(summarizer.activeCourseName) - \(Date().formatted(.dateTime.year().month().day()))"

        showToast("⏳ 正在同步至 Notion 資料庫...")
        Task {
            do {
                let url = try await NotionSyncService.syncToDatabase(apiKey: apiKey, databaseId: dbId, title: title, markdown: content)
                showToast("✅ 成功同步至 Notion！已在新視窗開啟")
                NSWorkspace.shared.open(url)
            } catch {
                showToast("❌ Notion 同步失敗: \(error.localizedDescription)")
            }
        }
    }

    private func copyToClipboard() {
        let content = selectedHistoricalSession?.summarySnippet ?? summarizer.currentSummary
        guard !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        showToast("📋 已複製文字至剪貼簿")
    }

    private func exportNotes() {
        let content = selectedHistoricalSession?.summarySnippet ?? summarizer.currentSummary
        guard !content.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.text]
        let prefix = summarizer.currentMode == .studentLecture ? "Lecture_Notes" : "Meeting_Notes"
        savePanel.nameFieldStringValue = "\(prefix)_\(Date().formatted(.iso8601.year().month().day())).md"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            showToast("💾 已匯出至: \(url.lastPathComponent)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var summarizer: OpenRouterService
    @ObservedObject var speech: SpeechEngine
    @Environment(\.dismiss) private var dismiss
    
    @State private var keyInput: String = ""
    @State private var courseInput: String = ""
    @State private var obsidianVaultPath: String = ""
    @State private var notionApiKey: String = ""
    @State private var notionDbId: String = ""
    @State private var intervalInput: Double = 60.0
    @State private var sensitivityInput: MicSensitivity = .lectureHall

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("應用程式與整合設定 (Settings)")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Section 1: 課堂學習情境
                    VStack(alignment: .leading, spacing: 6) {
                        Label("課堂與情境設定", systemImage: "graduationcap.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Picker("預設記錄模式", selection: $summarizer.currentMode) {
                            ForEach(NoteMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        HStack {
                            Text("常用課程名稱:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("例如：計算機概論 CS101 / 經濟學原理", text: $courseInput)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // Section 2: AI 調用頻率設定
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI 摘要生成頻率 (API 調用週期)", systemImage: "timer")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Text("設定錄音期間自動發送逐字稿至 OpenRouter 的間隔時間：")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("調用間隔", selection: $intervalInput) {
                            Text("30 秒 (高即時性)").tag(30.0)
                            Text("45 秒").tag(45.0)
                            Text("60 秒 (推薦，平衡兼顧)").tag(60.0)
                            Text("90 秒 (課堂推薦，低頻率省電)").tag(90.0)
                            Text("120 秒 (2 分鐘，超省 Token)").tag(120.0)
                            Text("180 秒 (3 分鐘)").tag(180.0)
                            Text("300 秒 (5 分鐘，長演講)").tag(300.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 260)

                        Text("💡 提示：原先預設的 25 秒過於頻繁，易觸發免費用戶 429 速率限制並加速電池消耗。在 MacBook 上課堂使用建議設為 60~90 秒，可減少 60%~75% 的網路請求與 Token 消耗。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // Section 3: 遠距離演講廳收音與增益 (Far-Field Audio & Gain)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("遠距收音與靈敏度增益 (Far-Field Mic Boost)", systemImage: "waveform.and.mic")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Text("當教授/講者距離較遠 (3~15 米) 或演講音量較小時，調節 CoreAudio 與軟飽和前級放大器：")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("收音靈敏度", selection: $sensitivityInput) {
                            ForEach(MicSensitivity.allCases) { sens in
                                Text(sens.title).tag(sens)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 320)

                        Text("🎙️ 核心音訊技術：採用 Apple AUVoiceIO 硬件級語音處理（回音消除 AEC + 自動增益 AGC）結合 Hyperbolic Tangent 軟飽和限制器，避免爆音失真，大幅提升階梯講堂中遠距語音辨識率。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // Section 3: Obsidian Vault 設定
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Obsidian 筆記同步", systemImage: "folder.badge.plus")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Text("Obsidian Vault 資料夾路徑:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("~/Documents/Obsidian Vault/LiveNotes", text: $obsidianVaultPath)
                                .textFieldStyle(.roundedBorder)
                            Button("選擇資料夾...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    obsidianVaultPath = url.path
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // Section 4: Notion API 設定
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notion 雲端同步 (可選)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Text("Notion Internal Integration Token (secret_...):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("secret_...", text: $notionApiKey)
                            .textFieldStyle(.roundedBorder)

                        Text("Notion Database ID (32 位元資料庫代碼):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("例如：a1b2c3d4e5...", text: $notionDbId)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // Section 5: OpenRouter API Key
                    VStack(alignment: .leading, spacing: 6) {
                        Label("OpenRouter AI 模型金鑰", systemImage: "key.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.purple)

                        Text("API Key (預設已內建 free-tier 免費模型):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("sk-or-v1-...", text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 400)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存設定") {
                    summarizer.apiKey = keyInput
                    summarizer.activeCourseName = courseInput
                    summarizer.updateSummaryInterval(intervalInput)
                    speech.updateSensitivity(sensitivityInput)
                    UserDefaults.standard.set(keyInput, forKey: "OpenRouterAPIKey")
                    UserDefaults.standard.set(courseInput, forKey: "LiveNotesCourseName")
                    UserDefaults.standard.set(obsidianVaultPath, forKey: "ObsidianVaultPath")
                    UserDefaults.standard.set(notionApiKey, forKey: "NotionAPIKey")
                    UserDefaults.standard.set(notionDbId, forKey: "NotionDatabaseID")
                    UserDefaults.standard.set(summarizer.currentMode.rawValue, forKey: "LiveNotesNoteMode")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 490, height: 500)
        .onAppear {
            keyInput = summarizer.apiKey
            courseInput = summarizer.activeCourseName
            obsidianVaultPath = UserDefaults.standard.string(forKey: "ObsidianVaultPath") ?? ""
            notionApiKey = UserDefaults.standard.string(forKey: "NotionAPIKey") ?? ""
            notionDbId = UserDefaults.standard.string(forKey: "NotionDatabaseID") ?? ""
            intervalInput = summarizer.summaryIntervalSeconds
            sensitivityInput = speech.sensitivity
        }
    }
}
