import Foundation

/// HTTP client for the OpenClaw gateway /v1/chat/completions endpoint.
/// Maintains conversation history for the duration of a Gemini session,
/// so OpenClaw keeps context across multiple tool calls.
final class OpenClawBridge {

    static let shared = OpenClawBridge()
    private init() {}

    // Stable session ID — same value = same OpenClaw session (derived via `user` field)
    // OpenClaw maintains conversation history server-side, so we only send current message
    private(set) var currentSessionId: String = UUID().uuidString
    private var sessionId: String { currentSessionId }

    private var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 300   // 5 min — tool calls can take long (web search, LLM)
        config.timeoutIntervalForResource = 600   // 10 min total
        return URLSession(configuration: config)
    }()

    // MARK: - Session Management

    /// Call when starting a new Gemini session — clears conversation history
    func resetSession() {
        currentSessionId = UUID().uuidString  // new UUID = new OpenClaw session
    }

    /// Restore a previous session by ID — OpenClaw will pick up its context server-side
    func restoreSession(id: String) {
        currentSessionId = id
    }

    // MARK: - Execute task

    /// Sends a task to OpenClaw with full conversation history and returns the response.
    func execute(task: String) async throws -> String {
        let settings = AppSettings.shared
        guard !settings.openClawToken.isEmpty else {
            throw OpenClawError.notConfigured
        }

        let urlString = "\(settings.openClawBaseURL)/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw OpenClawError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",                  forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openClawToken)",  forHTTPHeaderField: "Authorization")

        // Only send current message — OpenClaw maintains session context server-side via `user` UUID
        let body: [String: Any] = [
            "model":    "gpt-4o",
            "messages": [["role": "user", "content": task]],
            "user":     sessionId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenClawError.httpError(http.statusCode, body)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "(no response)"
    }

    // MARK: - Health check

    func checkHealth() async -> Bool {
        let settings = AppSettings.shared
        guard let url = URL(string: "\(settings.openClawBaseURL)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("Bearer \(settings.openClawToken)", forHTTPHeaderField: "Authorization")
        return (try? await urlSession.data(for: req)) != nil
    }

    // MARK: - Topic Name Generation

    /// Generate a short 2-5 word topic name from user transcript.
    /// Uses Gemini REST API directly (stateless, no session history pollution).
    func generateTopicName(from transcript: String) async -> String? {
        let settings = AppSettings.shared
        guard !settings.openClawToken.isEmpty else { return nil }
        guard let url = URL(string: "\(settings.openClawBaseURL)/v1/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openClawToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let prompt = "Give a very short title (2-5 words, same language as input) for a voice conversation that started with this text: \"\(transcript.prefix(300))\". Reply with ONLY the title, no quotes, no punctuation at the end."
        // Throwaway UUID — creates a tiny ephemeral session that doesn't appear in the ClawVoice UI
        let body: [String: Any] = [
            "model":    "gpt-4o",
            "messages": [["role": "user", "content": prompt]],
            "user":     "naming-\(UUID().uuidString)"
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        guard let (data, resp) = try? await urlSession.data(for: request) else {
            print("⚠️ [TopicName] Network error")
            return nil
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            print("⚠️ [TopicName] HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(100) ?? "")")
            return nil
        }

        struct Resp: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              let text = decoded.choices.first?.message.content else {
            print("⚠️ [TopicName] Unexpected response: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")")
            return nil
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        print("✅ [TopicName] → \"\(cleaned)\"")
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Errors

    enum OpenClawError: LocalizedError {
        case notConfigured
        case invalidURL(String)
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:        return "OpenClaw is not configured. Open Settings ⚙️"
            case .invalidURL(let url):  return "Invalid OpenClaw URL: \(url)"
            case .httpError(let code, let body): return "OpenClaw returned HTTP \(code): \(body)"
            }
        }
    }
}
