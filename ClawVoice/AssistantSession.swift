import Foundation
import Combine
import UIKit

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

    @Published var state: State = .idle {
        didSet { UIApplication.shared.isIdleTimerDisabled = state.isActive }
    }
    @Published var userTranscript: String = ""   // what user said (cleared on each new user turn)
    @Published var aiTranscript: String = ""     // what AI said (cleared on each new AI turn)
    private var userBuffer: String = ""
    private var aiBuffer: String = ""
    private var transcriptFlushTask: Task<Void, Never>?
    private var awaitingNewAITurn = false         // clear aiTranscript on next AI chunk after turnComplete
    private var userTurnActive = false            // true while user is speaking this turn
    @Published var lastError: String? = nil
    @Published var currentTask: String? = nil  // shown while executing tool calls
    @Published var sessionStartTime: Date? = nil  // set on start(), cleared on stop()

    // MARK: - Private

    private let gemini = GeminiLiveService()
    private let audio  = AudioManager()
    private let router = ToolCallRouter()
    private var siriObserver: NSObjectProtocol?

    // Auto-reconnect
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        gemini.delegate = self
        observeSiriShortcut()
        DebugLog.setup()
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
        audio.pauseCapture()  // stops engine + clears mic indicator
        state = .paused
    }

    func resume() {
        if gemini.isConnected {
            gemini.resetSpeakingState()  // clear stale isModelSpeaking so audio isn't blocked after pause
            audio.resumeCapture()  // restarts engine + mic
            state = .listening
        } else {
            // WebSocket died while paused — start a fresh connection instead of silently resuming into void
            print("⚠️ [ClawVoice] Resume: Gemini not connected, starting fresh reconnect")
            audio.stopCapture()
            reconnectAttempts = 0
            reconnectTask?.cancel()
            state = .connecting
            gemini.connect()
        }
    }

    func start() {
        guard state == .idle || {
            if case .error = state { return true } else { return false }
        }() else { return }

        reconnectAttempts = 0
        reconnectTask?.cancel()
        userTranscript = ""
        aiTranscript = ""
        userBuffer = ""
        aiBuffer = ""
        transcriptFlushTask?.cancel()
        awaitingNewAITurn = false
        userTurnActive = false
        lastError = nil
        sessionStartTime = Date()
        state = .connecting
        print("🟡 [ClawVoice] Connecting to Gemini...")
        OpenClawBridge.shared.resetSession()  // fresh context for new session
        SessionStore.shared.beginSession(id: OpenClawBridge.shared.currentSessionId)
        DebugLog.connection("START", sessionId: OpenClawBridge.shared.currentSessionId)
        gemini.connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectAttempts = 0
        let age = sessionStartTime.map { Date().timeIntervalSince($0) }
        DebugLog.connection("STOP", sessionId: OpenClawBridge.shared.currentSessionId, sessionAge: age)
        SessionStore.shared.endSession(id: OpenClawBridge.shared.currentSessionId)
        gemini.disconnect()
        audio.stopCapture()
        sessionStartTime = nil
        state = .idle
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ [ClawVoice] Max reconnect attempts reached, giving up")
            let msg = "Connection to Gemini lost. Tap to reconnect."
            DebugLog.error("MAX_RECONNECT_REACHED | \(msg)")
            lastError = msg
            state = .error(msg)
            return
        }
        reconnectAttempts += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = Double(1 << (reconnectAttempts - 1))
        let age = sessionStartTime.map { Date().timeIntervalSince($0) }
        DebugLog.connection("RECONNECT attempt=\(reconnectAttempts)/\(maxReconnectAttempts) delay=\(Int(delay))s",
                            sessionId: OpenClawBridge.shared.currentSessionId, sessionAge: age)
        print("🔁 [ClawVoice] Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")
        state = .connecting

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.gemini.connect()
            }
        }
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
            self.reconnectAttempts = 0  // reset on successful connect
            self.lastError = nil        // dismiss error dialog on successful reconnect
            DebugLog.connection("CONNECTED", sessionId: OpenClawBridge.shared.currentSessionId)
            self.state = .listening
            do {
                try self.audio.startCapture { [weak self] chunk in
                    guard let self else { return }
                    // Echo suppression: when using phone speaker, skip audio while model speaks.
                    // With headphones: always send (AEC handles it, enables interruption).
                    // headphonesConnected is cached on main thread — safe to read here.
                    // Without headphones: suppress mic while Gemini speaks to prevent speaker→mic echo.
                    // With headphones: AEC handles it — mic stays open so user can interrupt.
                    if self.gemini.isModelSpeaking && !self.audio.headphonesConnected { return }
                    self.gemini.sendAudio(chunk)
                }
            } catch {
                self.state = .error("Microphone error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func geminiDidReceiveAudio(_ data: Data) {
        Task { @MainActor in
            guard self.state != .paused else { return }  // drop audio while paused — avoids main thread pileup
            if self.state != .speaking {
                self.state = .speaking
            }
            self.audio.playAudio(data)
        }
    }

    nonisolated func geminiDidReceiveText(_ text: String) { }  // unused (transcription via separate delegates)

    nonisolated func geminiDidReceiveUserText(_ text: String) {
        Task { @MainActor in
            let isFirstTurn = !self.userTurnActive && self.userTranscript.isEmpty && self.aiTranscript.isEmpty
            if !self.userTurnActive {
                // New user turn: clear previous user text and start fresh
                self.userTranscript = ""
                self.userBuffer = ""
                self.userTurnActive = true
                self.awaitingNewAITurn = true  // next AI response should clear AI transcript
            }
            self.appendBuffered(text, to: \.userBuffer, publish: \.userTranscript)
            // Auto-name session from first user message
            if isFirstTurn {
                SessionStore.shared.nameSession(
                    id: OpenClawBridge.shared.currentSessionId,
                    from: self.userBuffer
                )
            }
        }
    }

    nonisolated func geminiDidReceiveAIText(_ text: String) {
        Task { @MainActor in
            if self.awaitingNewAITurn {
                // New AI turn: clear previous AI text
                self.aiTranscript = ""
                self.aiBuffer = ""
                self.awaitingNewAITurn = false
                self.userTurnActive = false
            }
            self.appendBuffered(text, to: \.aiBuffer, publish: \.aiTranscript)
        }
    }

    @MainActor
    private func appendBuffered(_ text: String,
                                 to buffer: ReferenceWritableKeyPath<AssistantSession, String>,
                                 publish target: ReferenceWritableKeyPath<AssistantSession, String>) {
        self[keyPath: buffer] += text
        let hasWordBoundary = self[keyPath: buffer].last.map { $0.isWhitespace || $0.isPunctuation } ?? false
        if hasWordBoundary {
            let needsSpace = !(self[keyPath: target].isEmpty || self[keyPath: target].last?.isWhitespace == true)
            self[keyPath: target] += (needsSpace ? " " : "") + self[keyPath: buffer]
            self[keyPath: buffer] = ""
            transcriptFlushTask?.cancel()
        } else {
            transcriptFlushTask?.cancel()
            transcriptFlushTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if !self[keyPath: buffer].isEmpty {
                        let ns = !(self[keyPath: target].isEmpty || self[keyPath: target].last?.isWhitespace == true)
                        self[keyPath: target] += (ns ? " " : "") + self[keyPath: buffer]
                        self[keyPath: buffer] = ""
                    }
                }
            }
        }
    }

    nonisolated func geminiDidReceiveToolCall(id: String, name: String, args: [String: String]) {
        Task { @MainActor in
            self.state = .thinking
            self.currentTask = args["task"] ?? name
            let result = await self.router.handle(id: id, name: name, args: args)
            self.currentTask = nil
            self.gemini.sendToolResponse(id: id, output: result)
            self.state = .listening
        }
    }

    nonisolated func geminiDidTurnComplete(interrupted: Bool) {
        Task { @MainActor in
            print("✅ [ClawVoice] Turn complete, interrupted=\(interrupted)")
            if self.state == .speaking || self.state == .thinking {
                self.state = .listening
            }
            self.userTurnActive = false  // ready for next user input
        }
    }

    nonisolated func geminiDidDisconnect(error: Error?) {
        Task { @MainActor in
            self.audio.stopCapture()
            let age = self.sessionStartTime.map { Date().timeIntervalSince($0) }
            if let error {
                let msg = error.localizedDescription
                print("❌ [ClawVoice] Gemini disconnected with error: \(msg)")
                DebugLog.connection("DISCONNECT error=\(msg)",
                                    sessionId: OpenClawBridge.shared.currentSessionId,
                                    sessionAge: age)
                // Auto-reconnect if user was active (not manually stopped)
                if self.state != .idle {
                    self.scheduleReconnect()
                } else {
                    self.lastError = msg
                    self.state = .error(msg)
                }
            } else {
                print("ℹ️ [ClawVoice] Gemini disconnected cleanly")
                DebugLog.connection("DISCONNECT clean", sessionAge: age)
                self.state = .idle
            }
        }
    }
}
