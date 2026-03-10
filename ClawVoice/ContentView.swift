import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: AssistantSession
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false
    @State private var orbScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Orb
                ZStack {
                    // Outer glow ring (active only)
                    if session.state.isActive {
                        Circle()
                            .fill(orbColor.opacity(0.15))
                            .frame(width: 220, height: 220)
                            .scaleEffect(orbScale)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                       value: orbScale)
                    }

                    // Main orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [orbColor.opacity(0.9), orbColor.opacity(0.4)],
                                center: .center,
                                startRadius: 10,
                                endRadius: 80
                            )
                        )
                        .frame(width: 140, height: 140)
                        .scaleEffect(session.state == .speaking ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                                   value: session.state == .speaking)
                        .shadow(color: orbColor.opacity(0.5), radius: 30)
                        .onTapGesture { session.toggle() }
                }
                .onAppear { orbScale = 1.15 }

                // Status label
                Text(session.state.label)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .animation(.easeInOut, value: session.state.label)

                // Transcript
                if !session.transcript.isEmpty {
                    ScrollView {
                        Text(session.transcript)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxHeight: 160)
                }

                Spacer()

                // Config warning
                if !settings.isConfigured {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Configure to get started", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    .padding(.bottom, 4)
                }
            }

            // Settings button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.5))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .alert("Connection Error", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("Settings") { showSettings = true }
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawVoiceActivate)) { _ in
            session.start()
        }
    }

    private var orbColor: Color {
        switch session.state {
        case .idle:        return .white
        case .connecting:  return .gray
        case .listening:   return .blue
        case .paused:      return Color(white: 0.5)  // dim gray
        case .thinking:    return Color(hue: 0.1, saturation: 0.9, brightness: 1.0)
        case .speaking:    return .green
        case .error:       return .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
        .environmentObject(AssistantSession())
}
