import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var healthStatus: String? = nil
    @State private var checkingHealth = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Gemini
                Section {
                    SecureField("Gemini API Key", text: $settings.geminiApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Model", selection: $settings.geminiModel) {
                        ForEach(GeminiConfig.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField("or type manually", text: $settings.geminiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)

                    Picker("Voice", selection: $settings.voiceName) {
                        ForEach(GeminiConfig.availableVoices, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } header: {
                    Text("Gemini")
                } footer: {
                    Link("Get a free API key →", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }

                // MARK: - OpenClaw Server
                Section {
                    TextField("Host (e.g. https://my.ts.net)", text: $settings.openClawHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("443", value: $settings.openClawPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    SecureField("Gateway Token", text: $settings.openClawToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    // Health check
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            Label("Test Connection", systemImage: "bolt.fill")
                        }
                        .disabled(checkingHealth)

                        Spacer()

                        if checkingHealth {
                            ProgressView().scaleEffect(0.8)
                        } else if let status = healthStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(status.hasPrefix("✅") ? .green : .red)
                        }
                    }
                } header: {
                    Text("OpenClaw Server")
                } footer: {
                    Text("Your OpenClaw gateway must have chatCompletions endpoint enabled.")
                }

                // MARK: - Assistant
                Section("Assistant") {
                    TextField("Name", text: $settings.assistantName)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt").font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $settings.systemPrompt)
                            .frame(minHeight: 100)
                            .font(.system(size: 14))
                    }
                }

                // MARK: - Siri Shortcut
                Section {
                    NavigationLink {
                        SiriShortcutGuideView()
                    } label: {
                        Label("Set Up \"Hey Siri\" Activation", systemImage: "waveform.circle.fill")
                    }
                } header: {
                    Text("Hands-Free Activation")
                } footer: {
                    Text("Use a Siri Shortcut so you can say \"Hey Siri, [your phrase]\" to launch the assistant with screen off.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func testConnection() {
        checkingHealth = true
        healthStatus = nil
        Task {
            let ok = await OpenClawBridge.shared.checkHealth()
            await MainActor.run {
                healthStatus = ok ? "✅ Connected" : "❌ Unreachable"
                checkingHealth = false
            }
        }
    }
}

// MARK: - Siri Guide

struct SiriShortcutGuideView: View {
    var body: some View {
        List {
            Section("How to set up") {
                step(1, "Open the **Shortcuts** app")
                step(2, "Tap **+** (top right) to create a new shortcut")
                step(3, "Tap **Add Action**, search for **ClawVoice**")
                step(4, "Select **Activate Assistant**")
                step(5, "Tap the shortcut name at the top → rename it (e.g. *Mr Krabs*)")
                step(6, "Tap **Add to Siri** → record your phrase")
                step(7, "Say **\"Hey Siri, Mr Krabs\"** — done!")
            }

            Section("Tips") {
                Label("Works with screen off", systemImage: "iphone.slash")
                Label("Works with AirPods", systemImage: "airpodspro")
                Label("Custom phrase = any language", systemImage: "globe")
                Label("iPhone 15 Pro: also try Action Button", systemImage: "button.programmable")
            }
        }
        .navigationTitle("Hey Siri Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Label {
            Text(try! AttributedString(markdown: text))
        } icon: {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.blue)
                .clipShape(Circle())
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
