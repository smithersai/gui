import SwiftUI

struct ChatView: View {
    @ObservedObject var agent: AgentService
    var onSend: (String) -> Void
    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("Smithers")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.titlebarFg)
                    if agent.isRunning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.titlebarBg)
            .border(Theme.border, edges: [.bottom])

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if agent.messages.isEmpty {
                            VStack(spacing: 12) {
                                Spacer().frame(height: 80)
                                Text("What can I help you build?")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text("Send a message to start a coding session with Codex.")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(agent.messages) { message in
                            MessageRow(message: message)
                        }
                        if agent.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Codex is thinking...")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textTertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .onChange(of: agent.messages.count) { _ in
                    withAnimation {
                        proxy.scrollTo("bottom")
                    }
                }
            }
            .background(Theme.surface1)

            // Composer
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ask anything...", text: $inputText, axis: .vertical)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .frame(minHeight: 60, alignment: .top)
                        .onSubmit {
                            send()
                        }
                        .onKeyPress(.return) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                return .ignored // let shift+return insert newline
                            }
                            send()
                            return .handled
                        }

                    HStack {
                        HStack(spacing: 12) {
                            Image(systemName: "paperclip")
                            Image(systemName: "at")
                            Image(systemName: "sparkles")
                        }
                        .foregroundColor(Theme.textTertiary)
                        .font(.system(size: 14))

                        Spacer()

                        Button(action: send) {
                            Image(systemName: agent.isRunning ? "stop.fill" : "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.surface1)
                                .frame(width: 24, height: 24)
                                .background(agent.isRunning ? Theme.danger : Theme.accent)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Theme.surface2.opacity(0.5))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 10)

                Text("Return to send")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 8)
            }
            .background(Theme.surface1)
        }
    }

    private func send() {
        NSLog("[ChatView] send() called, isRunning=%d, inputText='%@'", agent.isRunning, inputText)
        if agent.isRunning {
            agent.cancel()
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSLog("[ChatView] send() - text was empty, ignoring")
            FileManager.default.createFile(atPath: "/tmp/smithers_send_empty.txt", contents: Data("empty".utf8))
            return
        }
        inputText = ""
        NSLog("[ChatView] sending: %@", text)
        FileManager.default.createFile(atPath: "/tmp/smithers_send_ok.txt", contents: Data(text.utf8))
        onSend(text)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.type == .user {
                Spacer()
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bubbleUser)
                    .cornerRadius(16, corners: [.topLeft, .bottomLeft, .bottomRight])
                    .foregroundColor(Theme.textPrimary)
            } else if message.type == .assistant {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(4)
                    
                    if let cmd = message.command {
                        CommandBlock(command: cmd)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.bubbleAssistant)
                .cornerRadius(16, corners: [.topRight, .bottomLeft, .bottomRight])
                Spacer()
            } else if message.type == .command {
                if let cmd = message.command {
                    CommandBlock(command: cmd)
                }
                Spacer()
            }
        }
    }
}

struct CommandBlock: View {
    let command: Command
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("$ \(command.cmd)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("exit 0")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.success.opacity(0.15))
                .foregroundColor(Theme.success)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.success.opacity(0.3), lineWidth: 1)
                )
            }
            .padding(12)
            .background(Theme.bubbleCommand)
            
            // Output
            VStack(alignment: .leading, spacing: 4) {
                Text("cwd: \(command.cwd)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.bottom, 8)
                
                Text(command.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(2)
            }
            .padding(12)
        }
        .background(Color.black.opacity(0.2))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

#if os(macOS)
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let p1 = CGPoint(x: rect.minX, y: rect.minY)
        let p2 = CGPoint(x: rect.maxX, y: rect.minY)
        let p3 = CGPoint(x: rect.maxX, y: rect.maxY)
        let p4 = CGPoint(x: rect.minX, y: rect.maxY)
        
        path.move(to: CGPoint(x: rect.minX + (corners.contains(.topLeft) ? radius : 0), y: rect.minY))
        
        // Top edge and Top Right corner
        path.addLine(to: CGPoint(x: rect.maxX - (corners.contains(.topRight) ? radius : 0), y: rect.minY))
        if corners.contains(.topRight) {
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        }
        
        // Right edge and Bottom Right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (corners.contains(.bottomRight) ? radius : 0)))
        if corners.contains(.bottomRight) {
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        }
        
        // Bottom edge and Bottom Left corner
        path.addLine(to: CGPoint(x: rect.minX + (corners.contains(.bottomLeft) ? radius : 0), y: rect.maxY))
        if corners.contains(.bottomLeft) {
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        }
        
        // Left edge and Top Left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (corners.contains(.topLeft) ? radius : 0)))
        if corners.contains(.topLeft) {
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        }
        
        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
#endif
