import Foundation
import Combine

/// Central coordinator: owns Gemini + Audio + ToolCallRouter.
@MainActor
final class AssistantSession: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case connecting
        case listening
        case paused       // mic muted, connection alive
        case thinking
        case speaking
        case error(String)

        var label: String {
            switch self {
            case .idle:         return "Tap to talk"
            case .connecting:   return "Connecting…"
            case .listening:    return "Listening…"
            case .paused:       return "Paused · tap to resume"
            case .thinking:     return "Working…"
            case .speaking:     return "Speaking…"
            case .error(let e): return e
            }
        }

        var isActive: Bool {
            switch self {
            case .idle, .error: return false
            default:            return true
            }
        }
    }

    // MARK: - Published

    @Published var state: State = .idle
    @Published var transcript: String = ""
    @Published var lastError: String? = nil
    @Published var currentTask: String? = nil  // shown while executing tool calls

    // MARK: - Private

    private let gemini = GeminiLiveService()
    private let audio  = AudioManager()
    private let router = ToolCallRouter()
    private var siriObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        gemini.delegate = self
        observeSiriShortcut()
    }

    // MARK: - Public API

    func toggle() {
        switch state {
        case .idle, .error:
            start()
        case .paused:
            resume()
        case .listening, .speaking, .thinking:
            pause()
        case .connecting:
            stop()
        }
    }

    func pause() {
        audio.setMuted(true)
        state = .paused
    }

    func resume() {
        audio.setMuted(false)
        state = .listening
    }

    func start() {
        guard state == .idle || {
            if case .error = state { return true } else { return false }
        }() else { return }

        transcript = ""
        lastError = nil
        state = .connecting
        print("🟡 [ClawVoice] Connecting to Gemini...")
        gemini.connect()
    }

    func stop() {
        gemini.disconnect()
        audio.stopCapture()
        state = .idle
    }

    // MARK: - Private

    private func observeSiriShortcut() {
        siriObserver = NotificationCenter.default.addObserver(
            forName: .clawVoiceActivate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
    }
}

// MARK: - GeminiLiveServiceDelegate

extension AssistantSession: GeminiLiveServiceDelegate {

    nonisolated func geminiDidConnect() {
        Task { @MainActor in
            self.state = .listening
            do {
                try self.audio.startCapture { [weak self] chunk in
                    self?.gemini.sendAudio(chunk)
                }
            } catch {
                self.state = .error("Microphone error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func geminiDidReceiveAudio(_ data: Data) {
        Task { @MainActor in
            if self.state != .speaking {
                self.state = .speaking
                self.audio.setMuted(true)  // mute mic while model speaks (echo prevention)
            }
            self.audio.playAudio(data)
        }
    }

    nonisolated func geminiDidReceiveText(_ text: String) {
        Task { @MainActor in
            // Any text (transcription) means user is speaking → unmute
            if text.hasPrefix("You: ") {
                self.audio.setMuted(false)
                self.state = .listening
            }
            self.transcript += text
        }
    }

    nonisolated func geminiDidReceiveToolCall(id: String, name: String, args: [String: String]) {
        Task { @MainActor in
            self.audio.setMuted(false)
            self.state = .thinking
            self.currentTask = args["task"] ?? name
            let result = await self.router.handle(id: id, name: name, args: args)
            self.currentTask = nil
            self.gemini.sendToolResponse(id: id, output: result)
            self.state = .listening
        }
    }

    nonisolated func geminiDidDisconnect(error: Error?) {
        Task { @MainActor in
            self.audio.stopCapture()
            if let error {
                let msg = error.localizedDescription
                print("❌ [ClawVoice] Gemini disconnected with error: \(msg)")
                self.lastError = msg
                self.state = .error(msg)
            } else {
                print("ℹ️ [ClawVoice] Gemini disconnected cleanly")
                self.state = .idle
            }
        }
    }
}
