import Foundation

/// HTTP client for the OpenClaw gateway /v1/chat/completions endpoint.
/// Maintains conversation history for the duration of a Gemini session,
/// so OpenClaw keeps context across multiple tool calls.
final class OpenClawBridge {

    static let shared = OpenClawBridge()
    private init() {}

    // Persistent conversation history — reset when Gemini session starts
    private var messages: [[String: String]] = []

    private var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Session Management

    /// Call when starting a new Gemini session — clears conversation history
    func resetSession() {
        messages = []
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

        // Append user message to history
        messages.append(["role": "user", "content": task])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",                  forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openClawToken)",  forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model":    "gpt-4o",   // ignored by OpenClaw, required by spec
            "messages": messages    // full history for persistent context
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Remove the user message we added since the call failed
            messages.removeLast()
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
        let content = decoded.choices.first?.message.content ?? "(no response)"

        // Append assistant response to history
        messages.append(["role": "assistant", "content": content])

        return content
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
