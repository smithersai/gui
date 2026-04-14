import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @State private var mode: SidebarMode = .chats
    @State private var searchText: String = ""

    enum SidebarMode {
        case chats, source, agents
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode Bar
            HStack(spacing: 4) {
                ModeButton(title: "Chats", icon: "message", isSelected: mode == .chats) {
                    mode = .chats
                }
                ModeButton(title: "Source", icon: "arrow.branch", isSelected: mode == .source) {
                    mode = .source
                }
                ModeButton(title: "Agents", icon: "person.2", isSelected: mode == .agents) {
                    mode = .agents
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .border(Theme.border, edges: [.bottom])

            if mode == .chats {
                ChatsContent(store: store, searchText: $searchText)
            } else if mode == .agents {
                AgentsContent(store: store)
            } else {
                Spacer()
                Text("Source")
                    .foregroundColor(Theme.textTertiary)
                    .font(.system(size: 11))
                Spacer()
            }
        }
        .background(Theme.sidebarBg)
    }
}

struct AgentsContent: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RUNNING")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 8)

            let running = store.sessions.filter { $0.agent.isRunning }
            if running.isEmpty {
                Text("No agents running")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 12)
            }
            ForEach(running) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 6, height: 6)
                    Text(session.title)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Spacer()
        }
    }
}

struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(isSelected ? Theme.sidebarSelected : Color.clear)
            .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct ChatsContent: View {
    @ObservedObject var store: SessionStore
    @Binding var searchText: String

    let groups = ["Today", "Yesterday", "Older"]

    var body: some View {
        VStack(spacing: 0) {
            // New Chat + Search
            VStack(spacing: 8) {
                Button(action: { store.newSession() }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("New Chat")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Theme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Theme.textTertiary)
                        .font(.system(size: 12))
                    TextField("Search chats...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.inputBg)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let allSessions = store.chatSessions().filter {
                        searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
                    }
                    ForEach(groups, id: \.self) { group in
                        let sessions = allSessions.filter { $0.group == group }
                        if !sessions.isEmpty {
                            Text(group.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 16)
                                .padding(.bottom, 8)

                            ForEach(sessions) { session in
                                SessionRow(session: session, isSelected: store.activeSessionId == session.id) {
                                    store.selectSession(session.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(session.timestamp)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                Text(session.preview)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Theme.sidebarSelected : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func border(_ color: Color, edges: [Edge]) -> some View {
        overlay(EdgeBorder(width: 1, edges: edges).foregroundColor(color))
    }
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }

            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }

            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return width
                }
            }

            var h: CGFloat {
                switch edge {
                case .top, .bottom: return width
                case .leading, .trailing: return rect.height
                }
            }
            path.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return path
    }
}
