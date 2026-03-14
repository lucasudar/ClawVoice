import SwiftUI

struct SessionsDrawer: View {
    @EnvironmentObject var session: AssistantSession
    @ObservedObject var store: SessionStore = .shared
    @Binding var isOpen: Bool

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .leading) {
            // Dim background
            if isOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
            }

            // Drawer panel
            if isOpen {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        HStack {
                            Text("ClawVoice")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer()
                            Button { close() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(8)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 56)
                        .padding(.bottom, 16)

                        Divider().background(Color.white.opacity(0.1))

                        // New session button
                        Button {
                            startNewSession()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue.opacity(0.9))
                                Text("New Session")
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        }

                        Divider().background(Color.white.opacity(0.1))

                        // Session list
                        if store.sessions.isEmpty {
                            VStack {
                                Spacer()
                                Text("No sessions yet")
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.white.opacity(0.3))
                                Spacer()
                            }
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    // Section header
                                    Text("Recents")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.35))
                                        .padding(.horizontal, 20)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)

                                    ForEach(store.sessions) { record in
                                        SessionRow(record: record, isCurrent: record.id == currentSessionId) {
                                            resumeSession(record)
                                        }
                                    }
                                }
                            }
                        }

                        Spacer()
                    }
                    .frame(width: min(geo.size.width * 0.78, 300))
                    .background(Color(white: 0.08))
                    .ignoresSafeArea(edges: .vertical)
                    .transition(.move(edge: .leading))

                    Spacer()
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isOpen)
        } // GeometryReader
    }

    // MARK: - Helpers

    private var currentSessionId: String {
        OpenClawBridge.shared.currentSessionId
    }

    private func close() {
        withAnimation { isOpen = false }
    }

    private func startNewSession() {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if session.state.isActive { session.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                session.start()
            }
        }
    }

    private func resumeSession(_ record: SessionRecord) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if session.state.isActive { session.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                session.startResume(sessionId: record.id)
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let record: SessionRecord
    let isCurrent: Bool
    let onTap: () -> Void

    private func sessionSubtitle(_ r: SessionRecord) -> String {
        if isCurrent { return r.displayTime + " · active" }
        return r.displayTime + " · " + r.displayDuration
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Active indicator dot
                Circle()
                    .fill(isCurrent ? Color.blue : Color.clear)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundColor(isCurrent ? .white : .white.opacity(0.75))
                        .lineLimit(1)

                    Text(sessionSubtitle(record))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isCurrent ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
