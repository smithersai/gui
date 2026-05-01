import SwiftUI

/// Sheet shown after the `quick-launch` parser returns. Presents the proposed inputs
/// for the target workflow with inline editing, and launches on confirm.
struct QuickLaunchConfirmSheet: View {
    @ObservedObject var smithers: SmithersClient
    let target: Workflow
    let fields: [WorkflowLaunchField]
    let initialInputs: [String: JSONValue]
    let notes: String
    let prompt: String
    let onLaunched: (SmithersClient.LaunchResult) -> Void
    let onDismiss: () -> Void

    @State private var values: [String: String] = [:]
    @State private var isLaunching = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                header
                Divider().background(Theme.border)
                body_
                Divider().background(Theme.border)
                footer
            }
            .frame(minWidth: 560, maxWidth: 720)
            .background(Theme.surface1)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 120)
            .padding(.horizontal, 24)
        }
        .onAppear { seedValues() }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Launch \(target.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if !prompt.isEmpty {
                    Text("“\(prompt)”")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text("Esc")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var body_: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !notes.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(Theme.textTertiary)
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface2)
                    .cornerRadius(6)
                }

                if fields.isEmpty {
                    Text("This workflow takes no inputs.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    ForEach(fields, id: \.key) { field in
                        fieldRow(field)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 380)
    }

    private func fieldRow(_ field: WorkflowLaunchField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let type = field.type {
                    Text(type)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
                if field.required {
                    Text("required")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            TextField(
                field.defaultValue ?? "",
                text: Binding(
                    get: { values[field.key] ?? "" },
                    set: { values[field.key] = $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Theme.textPrimary)
            .padding(8)
            .background(Theme.surface2)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)

            Button(action: launch) {
                HStack(spacing: 6) {
                    if isLaunching { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
                    Text(isLaunching ? "Launching…" : "Launch")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLaunching)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func seedValues() {
        var seeded: [String: String] = [:]
        for field in fields {
            if let value = initialInputs[field.key] {
                seeded[field.key] = value.workflowInputText
            } else if let def = field.defaultValue {
                seeded[field.key] = def
            } else {
                seeded[field.key] = ""
            }
        }
        values = seeded
    }

    private func launch() {
        guard !isLaunching else { return }
        isLaunching = true
        errorMessage = nil

        let resolved = resolvedInputs()
        let targetCopy = target
        Task { @MainActor in
            do {
                let result = try await smithers.runWorkflow(targetCopy, inputs: resolved)
                isLaunching = false
                onLaunched(result)
            } catch {
                isLaunching = false
                errorMessage = "Failed to launch: \(error.localizedDescription)"
            }
        }
    }

    private func resolvedInputs() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for field in fields {
            let text = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out[field.key] = coerce(text: text, type: field.type)
        }
        return out
    }

    private func coerce(text: String, type: String?) -> JSONValue {
        let lower = (type ?? "string").lowercased()
        switch lower {
        case "number", "int", "integer", "float", "double":
            if let d = Double(text) { return .number(d) }
            return .string(text)
        case "boolean", "bool":
            if ["true", "yes", "1"].contains(text.lowercased()) { return .bool(true) }
            if ["false", "no", "0"].contains(text.lowercased()) { return .bool(false) }
            return .string(text)
        case "array", "object", "json":
            if let data = text.data(using: .utf8),
               let obj = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return obj
            }
            return .string(text)
        default:
            return .string(text)
        }
    }
}
