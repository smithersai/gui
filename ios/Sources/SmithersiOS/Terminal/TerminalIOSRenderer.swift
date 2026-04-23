// TerminalIOSRenderer.swift — ticket 0123.
//
// iOS-only renderer for the shared `TerminalSurface`. This is the
// Stage-0 pipes-backed terminal: it consumes UTF-8 bytes from
// `TerminalSurfaceModel.recentBytes` and draws them into a plain
// UITextView. Full libghostty VT rendering (using the
// `ghostty-vt.xcframework` from the 0092 PoC) replaces this body in a
// follow-up; the plumbing (input, resize, focus, bell, title) is the
// same either way so the later swap is contained.
//
// The key acceptance bullet this file carries: the iOS simulator must
// render bytes that arrived via `libsmithers-core`'s PTY transport,
// not via any daemon socket or NSView path. Because bytes flow through
// `TerminalSurfaceModel`, wiring this to the real libghostty VT
// decoder later is a local change.

#if os(iOS)
import SwiftUI
import UIKit

/// Entry point called from `TerminalPlatformRenderer` on iOS.
struct TerminalIOSRendererBridge: View {
    @ObservedObject var model: TerminalSurfaceModel
    var sessionID: String?
    var command: String?
    var workingDirectory: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.title.isEmpty {
                Text(model.title)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.05))
            }
            TerminalIOSTextView(model: model)
                .background(Color.black)
                .accessibilityIdentifier("terminal.ios.text")
                .overlay(alignment: .bottom) {
                    TerminalIOSInputBar(model: model)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.ios.surface")
    }
}

/// UITextView-backed byte renderer. Intentionally simple: appends bytes
/// as UTF-8 and scrolls to bottom. libghostty VT rendering replaces this
/// body in a 0092 follow-up.
struct TerminalIOSTextView: UIViewRepresentable {
    @ObservedObject var model: TerminalSurfaceModel

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .black
        tv.textColor = .green
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 48, right: 8)
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let rendered = String(data: model.recentBytes, encoding: .utf8) ?? ""
        if uiView.text != rendered {
            uiView.text = rendered
            let bottom = NSRange(location: (rendered as NSString).length, length: 0)
            uiView.scrollRangeToVisible(bottom)
        }
    }
}

/// Floating input bar so the iOS user has a way to send stdin bytes
/// back through the transport. Keeps the PTY two-way even without a
/// hardware keyboard. Hardware-keyboard key events hook in later.
struct TerminalIOSInputBar: View {
    @ObservedObject var model: TerminalSurfaceModel
    @State private var pending: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("input", text: $pending)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("terminal.ios.input")
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("terminal.ios.send")
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let line = pending + "\n"
        model.sendInput(Data(line.utf8))
        pending = ""
    }
}
#endif
