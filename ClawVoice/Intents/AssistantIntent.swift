import AppIntents
import Foundation

/// Siri Shortcut — "Hey Siri, [your custom phrase]" activates the assistant.
struct ActivateAssistantIntent: AppIntent {

    static var title: LocalizedStringResource = "Activate Assistant"
    static var description = IntentDescription(
        "Wake up your OpenClaw voice assistant and start listening.",
        categoryName: "ClawVoice"
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Small delay to let the app finish launching before we post the notification
        try await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {
            NotificationCenter.default.post(name: .clawVoiceActivate, object: nil)
        }
        return .result()
    }
}

/// Makes ClawVoice discoverable in the Shortcuts app and by Siri.
/// Without this, the intent won't appear in search.
struct ClawVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActivateAssistantIntent(),
            phrases: [
                "Activate \(.applicationName)",
                "Talk to \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Activate Assistant",
            systemImageName: "waveform.circle.fill"
        )
    }
}

extension Notification.Name {
    static let clawVoiceActivate = Notification.Name("clawVoiceActivate")
}
