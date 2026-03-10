import Foundation

protocol GeminiLiveServiceDelegate: AnyObject {
    func geminiDidConnect()
    func geminiDidReceiveAudio(_ data: Data)
    func geminiDidReceiveText(_ text: String)
    func geminiDidReceiveToolCall(id: String, name: String, args: [String: String])
    func geminiDidDisconnect(error: Error?)
}

/// WebSocket client for Gemini Live API (audio-only, no video).
@MainActor
final class GeminiLiveService: NSObject {

    // MARK: - Properties

    weak var delegate: GeminiLiveServiceDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private let wsDelegate = WebSocketDelegate()
    private let sendQueue = DispatchQueue(label: "clawvoice.gemini.send", qos: .userInitiated)

    // MARK: - Connect / Disconnect

    func connect() {
        let apiKey = AppSettings.shared.geminiApiKey
        print("🔌 [Gemini] Connecting, model=\(AppSettings.shared.geminiModel), keyLen=\(apiKey.count)")

        guard !apiKey.isEmpty else {
            delegate?.geminiDidDisconnect(error: makeError("Gemini API key is not configured. Open Settings ⚙️"))
            return
        }

        let baseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
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

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        wsDelegate.onOpen = nil
        wsDelegate.onClose = nil
        wsDelegate.onError = nil
    }

    // MARK: - Send

    func sendAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            let json: [String: Any] = [
                "realtimeInput": [
                    "audio": [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": data.base64EncodedString()
                    ]
                ]
            ]
            self?.sendJSON(json)
        }
    }

    func sendToolResponse(id: String, output: String) {
        sendQueue.async { [weak self] in
            let json: [String: Any] = [
                "toolResponse": [
                    "functionResponses": [
                        ["id": id, "response": ["output": output]]
                    ]
                ]
            ]
            self?.sendJSON(json)
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
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { _ in }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await self.webSocketTask else { break }
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
            await MainActor.run { self.delegate?.geminiDidConnect() }
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

        if let serverContent = json["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let mimeType = inlineData["mimeType"] as? String,
                       mimeType.hasPrefix("audio/pcm"),
                       let b64 = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: b64) {
                        await MainActor.run { self.delegate?.geminiDidReceiveAudio(audioData) }
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
                await MainActor.run { self.delegate?.geminiDidReceiveText("You: \(txt)\n") }
            }
            if let t = serverContent["outputTranscription"] as? [String: Any],
               let txt = t["text"] as? String, !txt.isEmpty {
                print("🤖 AI: \(txt)")
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
