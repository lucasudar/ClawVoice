import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Stored properties

    @Published var geminiApiKey: String {
        didSet { store("geminiApiKey", geminiApiKey) }
    }
    @Published var openClawHost: String {
        didSet { store("openClawHost", openClawHost) }
    }
    @Published var openClawPort: Int {
        didSet { UserDefaults.standard.set(openClawPort, forKey: "openClawPort") }
    }
    @Published var openClawToken: String {
        didSet { store("openClawToken", openClawToken) }
    }
    @Published var assistantName: String {
        didSet { store("assistantName", assistantName) }
    }
    @Published var geminiModel: String {
        didSet { store("geminiModel", geminiModel) }
    }
    @Published var voiceName: String {
        didSet { store("voiceName", voiceName) }
    }
    @Published var systemPrompt: String {
        didSet { store("systemPrompt", systemPrompt) }
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        geminiApiKey  = ud.string(forKey: "geminiApiKey")  ?? ""
        openClawHost  = ud.string(forKey: "openClawHost")  ?? ""
        openClawPort  = ud.integer(forKey: "openClawPort") != 0
                        ? ud.integer(forKey: "openClawPort") : 443
        openClawToken = ud.string(forKey: "openClawToken") ?? ""
        assistantName = ud.string(forKey: "assistantName") ?? "Assistant"
        geminiModel   = ud.string(forKey: "geminiModel")   ?? "gemini-2.5-flash-native-audio-preview-12-2025"
        voiceName     = ud.string(forKey: "voiceName")     ?? "Aoede"
        systemPrompt  = ud.string(forKey: "systemPrompt")  ??
            "You are a helpful voice assistant. Keep responses concise and conversational. When the user asks you to do something (send a message, search the web, check calendar, etc.), use the execute tool."
    }

    // MARK: - Computed

    var openClawBaseURL: String {
        let host = openClawHost.hasSuffix("/") ? String(openClawHost.dropLast()) : openClawHost
        let port = openClawPort
        // If host already includes a port or is https on 443, skip appending port
        if (openClawHost.hasPrefix("https://") && port == 443) ||
           (openClawHost.hasPrefix("http://") && port == 80) {
            return host
        }
        return "\(host):\(port)"
    }

    var isConfigured: Bool {
        !geminiApiKey.isEmpty && !openClawHost.isEmpty && !openClawToken.isEmpty
    }

    // MARK: - Private

    private func store(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
