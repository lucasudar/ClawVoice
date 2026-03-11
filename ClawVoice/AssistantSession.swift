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
    @Published var transcript: String = ""
    private var transcriptBuffer: String = ""      // accumulate until word boundary
    private var transcriptFlushTask: Task<Void, Never>?
    @Published var lastError: String? = nil
    @Published var currentTask: String? = nil  // shown while executing tool calls

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
        audio.resumeCapture()  // restarts engine + mic
        state = .listening
    }

    func start() {
        guard state == .idle || {
            if case .error = state { return true } else { return false }
        }() else { return }

        reconnectAttempts = 0
        reconnectTask?.cancel()
        transcript = ""
        transcriptBuffer = ""
        transcriptFlushTask?.cancel()
        lastError = nil
        state = .connecting
        print("🟡 [ClawVoice] Connecting to Gemini...")
        OpenClawBridge.shared.resetSession()  // fresh context for new session
        gemini.connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectAttempts = 0
        gemini.disconnect()
        audio.stopCapture()
        state = .idle
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ [ClawVoice] Max reconnect attempts reached, giving up")
            return
        }
        reconnectAttempts += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = Double(1 << (reconnectAttempts - 1))
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
            self.state = .listening
            do {
                try self.audio.startCapture { [weak self] chunk in
                    guard let self else { return }
                    // Echo suppression only when using phone speaker (no headphones).
                    // With headphones: always send audio → Gemini can hear user and interrupt.
                    // With speaker: suppress while model speaks to avoid feedback loop.
                    if self.gemini.isModelSpeaking && !self.audio.isHeadphonesConnected { return }
                    self.gemini.sendAudio(chunk)
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
            }
            self.audio.playAudio(data)
        }
    }

    nonisolated func geminiDidReceiveText(_ text: String) {
        Task { @MainActor in
            if text.hasPrefix("You: ") {
                self.state = .listening
            }

            // Buffer small chunks — flush on word boundary (space/punctuation) or after 300ms
            self.transcriptBuffer += text
            let hasWordBoundary = self.transcriptBuffer.last.map {
                $0.isWhitespace || $0.isPunctuation
            } ?? false

            if hasWordBoundary {
                self.transcript += self.transcriptBuffer
                self.transcriptBuffer = ""
                self.transcriptFlushTask?.cancel()
                self.transcriptFlushTask = nil
            } else {
                // Fallback flush after 300ms so it doesn't feel frozen
                self.transcriptFlushTask?.cancel()
                self.transcriptFlushTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if !self.transcriptBuffer.isEmpty {
                            self.transcript += self.transcriptBuffer
                            self.transcriptBuffer = ""
                        }
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
        }
    }

    nonisolated func geminiDidDisconnect(error: Error?) {
        Task { @MainActor in
            self.audio.stopCapture()
            if let error {
                let msg = error.localizedDescription
                print("❌ [ClawVoice] Gemini disconnected with error: \(msg)")
                // Auto-reconnect if user was active (not manually stopped)
                if self.state != .idle {
                    self.scheduleReconnect()
                } else {
                    self.lastError = msg
                    self.state = .error(msg)
                }
            } else {
                print("ℹ️ [ClawVoice] Gemini disconnected cleanly")
                self.state = .idle
            }
        }
    }
}
