import Foundation

public struct MeetingSessionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let dateDisplay: String
    public let folderURL: URL
    public let transcriptSnippet: String
    public let summarySnippet: String

    public init(id: String, dateDisplay: String, folderURL: URL, transcriptSnippet: String, summarySnippet: String) {
        self.id = id
        self.dateDisplay = dateDisplay
        self.folderURL = folderURL
        self.transcriptSnippet = transcriptSnippet
        self.summarySnippet = summarySnippet
    }
}

@MainActor
public class MeetingHistoryStore: ObservableObject {
    @Published public var sessions: [MeetingSessionItem] = []
    private let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        if let dir = rootDirectory {
            self.rootDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.rootDirectory = docs.appendingPathComponent("LiveNotes")
        }
        refresh()
    }

    public static func formatDateString(_ raw: String) -> String {
        // Expected format: yyyyMMdd_HHmmss
        let inputFormatter = DateFormatter()
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")
        inputFormatter.dateFormat = "yyyyMMdd_HHmmss"
        if let date = inputFormatter.date(from: raw) {
            let outputFormatter = DateFormatter()
            outputFormatter.locale = Locale(identifier: "en_US_POSIX")
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        return raw
    }

    public func refreshAsync() async {
        refresh()
    }

    public func refresh() {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            self.sessions = []
            return
        }

        guard let items = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: .skipsHiddenFiles) else {
            self.sessions = []
            return
        }

        var loaded: [MeetingSessionItem] = []
        for folder in items where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && (folder.lastPathComponent.hasPrefix("Meeting_") || folder.lastPathComponent.hasPrefix("Lecture_")) {
            let name = folder.lastPathComponent
            let rawDate = name.replacingOccurrences(of: "Meeting_", with: "").replacingOccurrences(of: "Lecture_", with: "")
            let transcriptFile = folder.appendingPathComponent("transcript.txt")
            let summaryFile = folder.appendingPathComponent("summary.md")

            let transcript = (try? String(contentsOf: transcriptFile, encoding: .utf8)) ?? ""
            let summary = (try? String(contentsOf: summaryFile, encoding: .utf8)) ?? ""

            let item = MeetingSessionItem(
                id: name,
                dateDisplay: Self.formatDateString(rawDate),
                folderURL: folder,
                transcriptSnippet: transcript,
                summarySnippet: summary
            )
            loaded.append(item)
        }
        self.sessions = loaded.sorted(by: { $0.id > $1.id })
    }
}
