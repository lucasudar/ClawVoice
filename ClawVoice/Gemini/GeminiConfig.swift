import Foundation

/// Static config builders — uses AppSettings at call time.
struct GeminiConfig {

    static func buildSetupMessage() -> GeminiSetupMessage {
        let s = AppSettings.shared
        return GeminiSetupMessage(
            setup: .init(
                model: "models/\(s.geminiModel)",
                generationConfig: .init(
                    responseModalities: ["AUDIO"],
                    speechConfig: .init(
                        voiceConfig: .init(
                            prebuiltVoiceConfig: .init(voiceName: s.voiceName)
                        )
                    )
                ),
                systemInstruction: .init(parts: [.init(text: s.systemPrompt)]),
                tools: [executeTool]
            )
        )
    }

    // Single "execute" tool — routes everything through OpenClaw
    static let executeTool = GeminiSetupMessage.Tool(
        functionDeclarations: [
            .init(
                name: "execute",
                description: "Execute any task or action using OpenClaw: send messages, search the web, check calendar, control smart home, manage notes, etc. Use this tool whenever the user asks you to DO something.",
                parameters: .init(
                    type: "object",
                    properties: [
                        "task": .init(
                            type: "string",
                            description: "Clear description of what to do, in plain English."
                        )
                    ],
                    required: ["task"]
                )
            )
        ]
    )

    // Available voice options for Settings UI
    static let availableVoices = ["Aoede", "Charon", "Fenrir", "Kore", "Puck"]

    // Models to try (Google renames/breaks these frequently)
    // Endpoint is always v1alpha BidiGenerateContent
    static let availableModels = [
        "gemini-2.5-flash-native-audio-preview-12-2025",
        "gemini-2.0-flash-live-001",
        "gemini-live-2.0-flash-001",
        "gemini-2.0-flash-exp",
        "gemini-live-2.5-flash",
        "gemini-2.5-flash-native-audio-preview-12-2025",
    ]
}
