import SwiftUI
import LibGhosttyWrapper

@main
struct PoCApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var rendered: String = "(loading...)"
    @State private var cursor: String = "-"
    @State private var size: String = "-"
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("libghostty-vt iOS PoC")
                .font(.headline)
            Text("size: \(size)   cursor: \(cursor)")
                .font(.system(.caption, design: .monospaced))
            Divider()
            ScrollView {
                Text(rendered)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .onAppear(perform: replay)
    }

    private func replay() {
        do {
            let term = try GhosttyVT(cols: 80, rows: 24)
            // Feed an inline fixture rather than relying on the bundle —
            // the PoC app is a demo; the authoritative fixture lives in
            // the test bundle alongside CellBufferTests.swift.
            let sample = "\u{1B}[2J\u{1B}[Hhello from libghostty-vt\r\non iOS simulator!\r\n"
            term.write(Array(sample.utf8))
            rendered = try term.plainText()
            let c = term.cursor
            cursor = "(\(c.x), \(c.y))"
            let s = term.size
            size = "\(s.cols)x\(s.rows)"
        } catch {
            self.error = "\(error)"
        }
    }
}
