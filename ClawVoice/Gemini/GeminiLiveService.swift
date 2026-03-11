import Foundation

protocol GeminiLiveServiceDelegate: AnyObject {
    func geminiDidConnect()
    func geminiDidReceiveAudio(_ data: Data)
    func geminiDidReceiveText(_ text: String)   // legacy inline text (non-transcription)
    func geminiDidReceiveUserText(_ text: String) // input transcription chunks
    func geminiDidReceiveAIText(_ text: String)   // output transcription chunks
    func geminiDidReceiveToolCall(id: String, name: String, args: [String: String])
    func geminiDidTurnComplete(interrupted: Bool)
    func geminiDidDisconnect(error: Error?)
}

/// WebSocket client for Gemini Live API (audio-only, no video).
@MainActor
final class GeminiLiveService: NSObject {

    // MARK: - Properties

    weak var delegate: GeminiLiveServiceDelegate?
    private(set) var isModelSpeaking = false  // true while Gemini is streaming audio
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let wsDelegate = WebSocketDelegate()
    private let sendQueue = DispatchQueue(label: "clawvoice.gemini.send", qos: .userInitiated)
    private var isReady = false  // true only after setup complete — guard audio sends
    private var pingTimer: Timer?  // keepalive — prevents Gemini from closing idle connection

    // MARK: - Connect / Disconnect

    /// Publicly readable connection state — use to check if WebSocket is alive before resuming.
    var isConnected: Bool { isReady && webSocketTask != nil }

    func connect() {
        // Cancel any stale connection before starting a new one.
        // Without this, old receiveTask keeps reading a dead socket, throws an error,
        // and triggers a second geminiDidDisconnect → double scheduleReconnect cascade.
        isReady = false
        isModelSpeaking = false  // reset so audio isn't silently dropped if disconnect happened mid-speech
        stopPingTimer()
        receiveTask?.cancel()
        receiveTask = nil
        wsDelegate.onOpen  = nil   // nil handlers first so cancel doesn't re-fire delegates
        wsDelegate.onClose = nil
        wsDelegate.onError = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        let apiKey = AppSettings.shared.geminiApiKey
        print("🔌 [Gemini] Connecting, model=\(AppSettings.shared.geminiModel), keyLen=\(apiKey.count)")

        guard !apiKey.isEmpty else {
            delegate?.geminiDidDisconnect(error: makeError("Gemini API key is not configured. Open Settings ⚙️"))
            return
        }

        // v1beta supports realtimeInputConfig + VAD for gemini-2.5-flash-native-audio models
        // v1alpha needed for gemini-2.0-flash-live-001 (v1beta returns 1008 for that model)
        let model = AppSettings.shared.geminiModel
        let apiVersion = model.contains("native-audio") || model.contains("2.5") ? "v1beta" : "v1alpha"
        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.\(apiVersion).GenerativeService.BidiGenerateContent"
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)

        wsDelegate.onOpen = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                print("🟢 [Gemini] WebSocket opened — sending setup...")
                self.sendSetup()
                self.startReceiving()
            }
        }

        wsDelegate.onClose = { [weak self] code, reason in
            guard let self else { return }
            let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            print("🔴 [Gemini] WebSocket closed: code=\(code.rawValue) reason=\(r)")
            Task { @MainActor in self.delegate?.geminiDidDisconnect(error: nil) }
        }

        wsDelegate.onError = { [weak self] error in
            guard let self else { return }
            let msg = error?.localizedDescription ?? "Unknown error"
            print("🔴 [Gemini] Error: \(msg)")
            let friendly = self.friendlyError(msg)
            Task { @MainActor in self.delegate?.geminiDidDisconnect(error: friendly) }
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
    }

    /// Reset speaking state — call on resume so stale isModelSpeaking doesn't block audio.
    func resetSpeakingState() {
        isModelSpeaking = false
    }

    func disconnect() {
        isReady = false
        stopPingTimer()
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        wsDelegate.onOpen = nil
        wsDelegate.onClose = nil
        wsDelegate.onError = nil
    }

    // MARK: - Keepalive ping

    private func startPingTimer() {
        stopPingTimer()
        // Send WS ping every 25s — Gemini closes idle connections after ~60s of silence
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Dispatch to MainActor to access main-actor-isolated webSocketTask
            Task { @MainActor [weak self] in
                self?.webSocketTask?.sendPing { error in
                    if let error {
                        print("⚠️ [ClawVoice] WS ping failed: \(error) — triggering reconnect")
                        Task { @MainActor [weak self] in
                            self?.delegate?.geminiDidDisconnect(error: error)
                        }
                    }
                }
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - Send

    func sendAudio(_ data: Data) {
        guard isReady, let task = webSocketTask else { return }
        let b64 = data.base64EncodedString()
        sendQueue.async {
            Self.sendRaw([
                "realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": b64]]
            ], to: task)
        }
    }

    func sendToolResponse(id: String, output: String) {
        guard let task = webSocketTask else { return }
        sendQueue.async {
            Self.sendRaw([
                "toolResponse": ["functionResponses": [["id": id, "response": ["output": output]]]]
            ], to: task)
        }
    }

    // MARK: - Private

    private func sendSetup() {
        let settings = AppSettings.shared
        let json: [String: Any] = [
            "setup": [
                "model": "models/\(settings.geminiModel)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": settings.voiceName]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [["text": settings.systemPrompt]]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                        "silenceDurationMs": 500,
                        "prefixPaddingMs": 40
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any],
                "tools": [
                    ["functionDeclarations": [
                        [
                            "name": "execute",
                            "description": "Execute any task using OpenClaw: send messages, search the web, check calendar, control smart home, manage notes, and more. Use this whenever the user asks you to DO something.",
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "task": [
                                        "type": "string",
                                        "description": "Clear description of what to do, with all relevant context."
                                    ]
                                ],
                                "required": ["task"]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        sendJSON(json)
    }

    private func sendJSON(_ json: [String: Any]) {
        guard let task = webSocketTask else { return }
        Self.sendRaw(json, to: task)
    }

    private nonisolated static func sendRaw(_ json: [String: Any], to task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { _ in }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    var text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d):   text = String(data: d, encoding: .utf8)
                    @unknown default:    break
                    }
                    if let text { await self.handleMessage(text) }
                } catch {
                    if !Task.isCancelled {
                        let msg = error.localizedDescription
                        await MainActor.run {
                            self.delegate?.geminiDidDisconnect(error: self.friendlyError(msg))
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            print("✅ [Gemini] Setup complete — ready!")
            await MainActor.run {
                self.isReady = true
                self.startPingTimer()
                self.delegate?.geminiDidConnect()
            }
            return
        }

        if let toolCall = json["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let id   = call["id"]   as? String,
                      let name = call["name"] as? String else { continue }
                let args = (call["args"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
                print("🔧 [Gemini] Tool call: \(name)(\(args))")
                await MainActor.run { self.delegate?.geminiDidReceiveToolCall(id: id, name: name, args: args) }
            }
            return
        }

        // GoAway — server about to close, trigger reconnect
        if let goAway = json["goAway"] as? [String: Any] {
            let secs = (goAway["timeLeft"] as? [String: Any])?["seconds"] as? Int ?? 0
            print("⚠️ [Gemini] GoAway: server closing in \(secs)s")
            await MainActor.run { self.delegate?.geminiDidDisconnect(error: nil) }
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {

            // User interrupted model speech
            if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                print("✋ [Gemini] Interrupted")
                await MainActor.run { self.isModelSpeaking = false; self.delegate?.geminiDidTurnComplete(interrupted: true) }
                return
            }

            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let mimeType = inlineData["mimeType"] as? String,
                       mimeType.hasPrefix("audio/pcm"),
                       let b64 = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: b64) {
                        await MainActor.run { self.isModelSpeaking = true; self.delegate?.geminiDidReceiveAudio(audioData) }
                    }
                    if let text = part["text"] as? String, !text.isEmpty {
                        await MainActor.run { self.delegate?.geminiDidReceiveText(text) }
                    }
                }
            }

            // Transcription
            if let t = serverContent["inputTranscription"] as? [String: Any],
               let txt = t["text"] as? String, !txt.isEmpty {
                print("🎙 You: \(txt)")
                await MainActor.run { self.delegate?.geminiDidReceiveUserText(txt) }
            }
            if let t = serverContent["outputTranscription"] as? [String: Any],
               let txt = t["text"] as? String, !txt.isEmpty {
                print("🤖 AI: \(txt)")
                await MainActor.run { self.delegate?.geminiDidReceiveAIText(txt) }
            }

            // Turn complete — model finished speaking, switch back to listening
            // Delay clearing isModelSpeaking by 500ms so echo from speaker drains before mic opens
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                print("✅ [Gemini] Turn complete")
                await MainActor.run { self.delegate?.geminiDidTurnComplete(interrupted: false) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self.isModelSpeaking = false }
            }
        }
    }

    // MARK: - Helpers

    private func friendlyError(_ msg: String) -> Error {
        let friendly: String
        if msg.contains("bad response") || msg.contains("badServerResponse") {
            friendly = "Gemini rejected connection — check your API key in Settings ⚙️"
        } else if msg.contains("not connected") || msg.contains("Socket") {
            friendly = "Gemini connection failed — check your internet and API key ⚙️"
        } else if msg.contains("timed out") {
            friendly = "Connection to Gemini timed out"
        } else {
            friendly = "Gemini: \(msg)"
        }
        return makeError(friendly)
    }

    private func makeError(_ msg: String) -> Error {
        NSError(domain: "ClawVoice.Gemini", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - WebSocket Delegate (non-isolated helper)

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen:  ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        onOpen?(proto)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onError?(error) }
    }
}
