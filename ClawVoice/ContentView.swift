import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: AssistantSession
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false
    @State private var showDrawer = false
    @State private var rippleScale: CGFloat = 1.0
    @State private var now: Date = Date()
    private let clockTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {
                Spacer()

                // Orb
                ZStack {
                    // Ripple ring — only when listening or speaking
                    if isAnimated {
                        Circle()
                            .strokeBorder(orbColor.opacity(0.25), lineWidth: 2)
                            .frame(width: 200, height: 200)
                            .scaleEffect(rippleScale)
                            .opacity(2.0 - rippleScale)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: rippleScale
                            )
                    }

                    // Main orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [orbColor.opacity(0.95), orbColor.opacity(0.4)],
                                center: .center,
                                startRadius: 5,
                                endRadius: 70
                            )
                        )
                        .frame(width: 130, height: 130)
                        .shadow(color: orbColor.opacity(isAnimated ? 0.5 : 0.15), radius: isAnimated ? 24 : 8)
                        .scaleEffect(session.state == .speaking ? 1.06 : 1.0)
                        .animation(
                            session.state == .speaking
                                ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.3),
                            value: session.state == .speaking
                        )
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            session.toggle()
                        }
                }
                .onAppear { rippleScale = 1.6 }

                // Status
                VStack(spacing: 8) {
                    Text(session.state.label)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.2), value: session.state.label)

                    // Session duration — shown when active
                    if let start = session.sessionStartTime {
                        Text(sessionDurationLabel(since: start))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.white.opacity(0.3))
                            .transition(.opacity)
                    }

                    // Dynamic task label (while executing OpenClaw)
                    if let task = session.currentTask {
                        Text(task)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .lineLimit(2)
                            .transition(.opacity)
                    }
                }

                // Transcript
                let hasTranscript = !session.userTranscript.isEmpty || !session.aiTranscript.isEmpty
                if hasTranscript {
                    VStack(spacing: 6) {
                        if !session.userTranscript.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("You:")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.blue.opacity(0.8))
                                Text(session.userTranscript)
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 32)
                        }
                        if !session.aiTranscript.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("AI:")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.green.opacity(0.8))
                                Text(session.aiTranscript)
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 32)
                        }
                    }
                }

                Spacer()

                // Config warning
                if !settings.isConfigured {
                    Button { showSettings = true } label: {
                        Label("Setup required", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    .padding(.bottom, 4)
                }
            }

            // Top buttons: hamburger (left) + gear (right)
            VStack {
                HStack {
                    Button { withAnimation { showDrawer = true } } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.35))
                            .padding(20)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.35))
                            .padding(20)
                    }
                }
                Spacer()
            }

            // Sessions drawer overlay
            SessionsDrawer(isOpen: $showDrawer)
                .environmentObject(session)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
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
        .onReceive(clockTimer) { date in
            now = date
        }
    }

    // MARK: - Helpers

    private func sessionDurationLabel(since start: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(start))
        let minutes = elapsed / 60
        if minutes < 1 {
            return "< 1 min"
        } else if minutes < 60 {
            return "\(minutes) min"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = TimeZone(identifier: "America/Vancouver")
            return "since \(formatter.string(from: start))"
        }
    }

    // Animate only when actively listening or speaking
    private var isAnimated: Bool {
        session.state == .listening || session.state == .speaking
    }

    private var orbColor: Color {
        switch session.state {
        case .idle:        return Color(white: 0.6)
        case .connecting:  return Color(white: 0.4)
        case .listening:   return .blue
        case .paused:      return Color(white: 0.35)   // dim, no animation
        case .thinking:    return Color(hue: 0.08, saturation: 0.9, brightness: 1.0)  // amber
        case .speaking:    return Color(hue: 0.38, saturation: 0.8, brightness: 0.9)  // green
        case .error:       return .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
        .environmentObject(AssistantSession())
}
