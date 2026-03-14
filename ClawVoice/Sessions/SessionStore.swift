import Foundation

// MARK: - Session Record

struct SessionRecord: Codable, Identifiable {
    let id: String          // matches OpenClawBridge sessionId
    let startedAt: Date
    var endedAt: Date?
    var name: String        // auto-generated from first user message, or "Session HH:MM"
    var durationSeconds: Int { Int((endedAt ?? Date()).timeIntervalSince(startedAt)) }

    var displayDuration: String {
        let mins = durationSeconds / 60
        if mins < 1 { return "< 1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60; let m = mins % 60
        return "\(h)h \(m)m"
    }

    var displayTime: String {
        let formatter = DateFormatter()
        let age = Date().timeIntervalSince(startedAt)
        if age < 3600 {
            formatter.dateFormat = "h:mm a"
        } else if age < 86400 {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        formatter.timeZone = TimeZone(identifier: "America/Vancouver")
        return formatter.string(from: startedAt)
    }
}

// MARK: - Session Store

final class SessionStore: ObservableObject {

    static let shared = SessionStore()
    private init() { load() }

    @Published private(set) var sessions: [SessionRecord] = []

    private var storageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("sessions.json")
    }

    // MARK: - API

    func beginSession(id: String) {
        let fallbackName = "Session " + {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            f.timeZone = TimeZone(identifier: "America/Vancouver")
            return f.string(from: Date())
        }()
        let record = SessionRecord(id: id, startedAt: Date(), endedAt: nil, name: fallbackName)
        sessions.insert(record, at: 0)
        save()
    }

    func endSession(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].endedAt = Date()
        save()
    }

    /// Called with first user message to auto-name the session
    func nameSession(id: String, from firstMessage: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Trim to ~30 chars for display
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.count > 30 ? String(trimmed.prefix(28)) + "…" : trimmed
        guard !name.isEmpty else { return }
        sessions[idx].name = name
        save()
    }

    // MARK: - Persistence

    private func save() {
        // Keep only last 50 sessions
        if sessions.count > 50 { sessions = Array(sessions.prefix(50)) }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) else { return }
        sessions = decoded
    }
}
