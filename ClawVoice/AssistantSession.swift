import Foundation
import Combine
import UIKit
import AudioToolbox

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
            case .thinking:     return "Processing…"
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
    private var sessionNamed = false    // true after session name is set
    private var turnCount = 0           // counts completed turns for deferred naming
    private var lastUserTurn = ""       // transcript of the most recent completed user turn
    private var postToolSuppressUntil: Date = .distantPast  // suppress mic briefly after tool result sent
    var pendingToolResponseBlocked = false  // set on interrupted=true, prevents stale tool response → 1008

    // MARK: - Init

    init() {
        gemini.delegate = self
        observeSiriShortcut()
        observeAppLifecycle()
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
        sessionNamed = false
        turnCount = 0
        lastUserTurn = ""
        postToolSuppressUntil = .distantPast
        sessionStartTime = Date()
        state = .connecting
        print("🟡 [ClawVoice] Connecting to Gemini...")
        OpenClawBridge.shared.resetSession()  // fresh context for new session
        SessionStore.shared.beginSession(id: OpenClawBridge.shared.currentSessionId)
        DebugLog.connection("START", sessionId: OpenClawBridge.shared.currentSessionId)
        gemini.connect()
    }

    /// Resume a previous session by ID — preserves OpenClaw context server-side
    func startResume(sessionId: String) {
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
        sessionNamed = true  // don't overwrite existing session name
        turnCount = 0
        sessionStartTime = Date()
        state = .connecting
        print("🟡 [ClawVoice] Resuming session \(sessionId.prefix(8))...")
        OpenClawBridge.shared.restoreSession(id: sessionId)  // keep existing ID — NO resetSession()
        DebugLog.connection("RESUME", sessionId: sessionId)
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

    private func withTimeoutOrNil<T>(seconds: Double, task: Task<T, Never>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next()!!
            group.cancelAll()
            return first
        }
    }

    private func scheduleReconnect() {
        // Cancel any in-flight reconnect task before scheduling a new one (prevents race)
        reconnectTask?.cancel()
        reconnectTask = nil

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

    func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // If connection dropped while in background — reconnect on resume
                // Reconnect on foreground only if actively in a non-paused state
                // Never auto-reconnect from .paused — user must resume manually
                if self.state == .connecting || self.state == .listening ||
                   self.state == .speaking || self.state == .thinking {
                    if !self.gemini.isConnected {
                        print("📱 [ClawVoice] Foregrounded with dead connection — reconnecting")
                        self.reconnectAttempts = 0
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }
}

// MARK: - GeminiLiveServiceDelegate

extension AssistantSession: GeminiLiveServiceDelegate {

    nonisolated func geminiDidConnect() {
        Task { @MainActor in
            // Only reset reconnect counter after a stable connection (30s).
            // Resetting immediately causes infinite loops during GoAway scenarios
            // where setup completes but server closes with 1001 right after.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s stable = real success
                if self.state == .listening || self.state == .speaking || self.state == .thinking {
                    self.reconnectAttempts = 0
                }
            }
            self.lastError = nil        // dismiss error dialog on successful reconnect
            self.pendingToolResponseBlocked = false  // reset stale flag from previous session
            DebugLog.connection("CONNECTED", sessionId: OpenClawBridge.shared.currentSessionId)
            // Don't reconnect audio while paused — user paused intentionally
            guard self.state != .paused else {
                print("⏸ [ClawVoice] Connected but state=paused — not starting audio capture")
                return
            }
            self.state = .listening
            do {
                try self.audio.startCapture { [weak self] chunk in
                    guard let self else { return }
                    // Echo suppression (speaker only — headphones use AEC):
                    // 1. While AI is speaking (isModelSpeaking)
                    // 2. Brief window after tool result sent (echo drain before AI starts responding)
                    if !self.audio.headphonesConnected {
                        if self.gemini.isModelSpeaking { return }
                        if Date() < self.postToolSuppressUntil { return }
                    }
                    self.gemini.sendAudio(chunk)
                }
            } catch {
                self.state = .error("Microphone error: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func geminiDidReceiveAudio(_ data: Data) {
        Task { @MainActor in
            // New audio arriving = new model turn started, unblock playback.
            self.audio.allowPlayback()
            // Schedule audio even while paused — playerNode.pause() holds buffers for resume.
            // Don't update visual state to .speaking while paused (user sees .paused).
            if self.state != .paused && self.state != .speaking {
                self.state = .speaking
            }
            self.audio.playAudio(data)
        }
    }

    nonisolated func geminiDidReceiveText(_ text: String) { }  // unused (transcription via separate delegates)

    nonisolated func geminiDidReceiveUserText(_ text: String) {
        Task { @MainActor in
            if !self.userTurnActive {
                // New user turn: clear previous user text and start fresh
                self.userTranscript = ""
                self.userBuffer = ""
                self.userTurnActive = true
                self.awaitingNewAITurn = true  // next AI response should clear AI transcript
            }
            self.appendBuffered(text, to: \.userBuffer, publish: \.userTranscript)
        }
    }

    nonisolated func geminiDidReceiveAIText(_ text: String) {
        Task { @MainActor in
            guard self.state != .paused else { return }  // don't update text while paused
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
            AudioServicesPlayAlertSound(1105)   // "key_press_modifier" — tool start (louder, speaker)
            // Gemini Live expects tool response within ~30s — add timeout
            let result: String
            let handleTask = Task { await self.router.handle(id: id, name: name, args: args) }
            if let r = await withTimeoutOrNil(seconds: 25, task: handleTask) {
                result = r
            } else {
                handleTask.cancel()
                result = "Request timed out after 25 seconds."
                print("⏱ [ClawVoice] Tool response timed out")
            }
            self.currentTask = nil
            // Don't send tool response if the turn was interrupted — Gemini doesn't expect it
            // and will close the connection with code 1008 (unexpected message)
            guard !self.pendingToolResponseBlocked else {
                print("⚠️ [ClawVoice] Tool response suppressed (turn was interrupted)")
                self.pendingToolResponseBlocked = false
                return
            }
            self.gemini.sendToolResponse(id: id, output: result)
            // Suppress mic for 800ms after tool result — gives Gemini time to start speaking
            // without echo from previous AI speech interrupting the new response
            self.postToolSuppressUntil = Date().addingTimeInterval(0.8)
            AudioServicesPlayAlertSound(1054)   // "tweet" — tool done (distinct, speaker)
            // Keep .thinking state — geminiDidReceiveAudio will switch to .speaking
        }
    }

    nonisolated func geminiDidTurnComplete(interrupted: Bool) {
        Task { @MainActor in
            print("✅ [ClawVoice] Turn complete, interrupted=\(interrupted)")
            if interrupted {
                // Drop all buffered AI audio — user spoke, Gemini is starting a new response
                self.audio.clearPlayback()
                // Block any pending tool response — Gemini no longer expects it after interrupt
                // Sending it would cause code=1008 "Operation not supported" disconnect
                self.pendingToolResponseBlocked = true
            }
            if self.state == .speaking || self.state == .thinking {
                self.state = .listening
            }
            self.turnCount += 1
            // Capture the most recent user turn for naming (reflects current topic)
            if !self.userTranscript.isEmpty {
                self.lastUserTurn = self.userTranscript
            }
            // Name after 2+ turns OR when last turn is substantial (≥40 chars)
            if !self.sessionNamed && !self.lastUserTurn.isEmpty &&
               (self.turnCount >= 2 || self.lastUserTurn.count >= 40) {
                SessionStore.shared.nameSession(
                    id: OpenClawBridge.shared.currentSessionId,
                    from: self.lastUserTurn
                )
                self.sessionNamed = true
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
                // Auto-reconnect only if actively listening/speaking/thinking (not paused/idle)
                if self.state == .listening || self.state == .speaking ||
                   self.state == .thinking || self.state == .connecting {
                    self.scheduleReconnect()
                } else {
                    self.lastError = msg
                    self.state = .error(msg)
                }
            } else {
                print("ℹ️ [ClawVoice] Gemini disconnected cleanly")
                DebugLog.connection("DISCONNECT clean", sessionAge: age)
                // Clean disconnect = Gemini session timeout (~10 min limit)
                // Auto-reconnect only if actively in a session (not paused/idle)
                if self.state == .listening || self.state == .speaking ||
                   self.state == .thinking || self.state == .connecting {
                    self.scheduleReconnect()
                } else {
                    self.state = .idle
                }
            }
        }
    }
}
