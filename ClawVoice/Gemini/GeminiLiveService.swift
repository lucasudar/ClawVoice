import Foundation

protocol GeminiLiveServiceDelegate: AnyObject {
    func geminiDidConnect()
    func geminiDidReceiveAudio(_ data: Data)
    func geminiDidReceiveText(_ text: String)
    func geminiDidReceiveToolCall(id: String, name: String, args: [String: String])
    func geminiDidDisconnect(error: Error?)
}

/// WebSocket client for Gemini Live API (audio-only, no video).
final class GeminiLiveService: NSObject {

    // MARK: - Properties

    weak var delegate: GeminiLiveServiceDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false

    // MARK: - Connect / Disconnect

    func connect() {
        let apiKey = AppSettings.shared.geminiApiKey
        let model  = AppSettings.shared.geminiModel
        guard !apiKey.isEmpty else {
            delegate?.geminiDidDisconnect(error: GeminiError.missingApiKey)
            return
        }

        // Gemini Live API — BidiGenerateContent WebSocket endpoint (model specified in setup message)
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return }

        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        sendSetup()
        receiveLoop()
    }

    func disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Send

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        let b64 = data.base64EncodedString()
        let msg = GeminiAudioMessage(
            realtimeInput: .init(mediaChunks: [.init(data: b64, mimeType: "audio/pcm;rate=16000")])
        )
        send(msg)
    }

    func sendToolResponse(id: String, output: String) {
        let msg = GeminiToolResponseMessage(
            toolResponse: .init(functionResponses: [.init(id: id, response: .init(output: output))])
        )
        send(msg)
    }

    // MARK: - Private

    private func sendSetup() {
        send(GeminiConfig.buildSetupMessage())
    }

    private func send<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(json)) { _ in }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.delegate?.geminiDidDisconnect(error: err)
            case .success(let message):
                self.handle(message)
                if self.isConnected { self.receiveLoop() }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        var jsonData: Data?
        switch message {
        case .string(let str): jsonData = str.data(using: .utf8)
        case .data(let d):     jsonData = d
        @unknown default:      return
        }
        guard let data = jsonData,
              let msg = try? JSONDecoder().decode(GeminiServerMessage.self, from: data)
        else { return }

        if msg.setupComplete != nil {
            isConnected = true
            DispatchQueue.main.async { self.delegate?.geminiDidConnect() }
            return
        }

        if let content = msg.serverContent {
            if let parts = content.modelTurn?.parts {
                for part in parts {
                    if let b64 = part.inlineData?.data,
                       let audioData = Data(base64Encoded: b64) {
                        DispatchQueue.main.async { self.delegate?.geminiDidReceiveAudio(audioData) }
                    }
                    if let text = part.text, !text.isEmpty {
                        DispatchQueue.main.async { self.delegate?.geminiDidReceiveText(text) }
                    }
                }
            }
        }

        if let toolCall = msg.toolCall {
            for call in toolCall.functionCalls {
                DispatchQueue.main.async {
                    self.delegate?.geminiDidReceiveToolCall(id: call.id, name: call.name, args: call.args)
                }
            }
        }
    }

    // MARK: - Errors

    enum GeminiError: LocalizedError {
        case missingApiKey
        var errorDescription: String? {
            switch self {
            case .missingApiKey: return "Gemini API key is not configured. Go to Settings."
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        isConnected = false
        DispatchQueue.main.async { self.delegate?.geminiDidDisconnect(error: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            isConnected = false
            let friendly = friendlyError(error)
            DispatchQueue.main.async { self.delegate?.geminiDidDisconnect(error: friendly) }
        }
    }

    private func friendlyError(_ error: Error) -> Error {
        let msg: String
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .badServerResponse:
                msg = "Gemini rejected the connection — check your API key in Settings ⚙️"
            case .notConnectedToInternet, .networkConnectionLost:
                msg = "No internet connection"
            case .timedOut:
                msg = "Connection to Gemini timed out"
            default:
                msg = "Gemini error: \(urlErr.localizedDescription)"
            }
        } else {
            msg = error.localizedDescription
        }
        return NSError(domain: "ClawVoice", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
