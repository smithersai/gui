#if os(iOS)
import Foundation
import SwiftUI
import UIKit

struct DevtoolsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DevtoolsPanelViewModel

    init(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String,
        bearerProvider: @escaping DevtoolsSnapshotsClient.BearerProvider
    ) {
        _model = StateObject(
            wrappedValue: DevtoolsPanelViewModel(
                client: DevtoolsSnapshotsClient(
                    baseURL: baseURL,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    sessionID: sessionID,
                    bearerProvider: bearerProvider
                )
            )
        )
    }

    init(
        client: DevtoolsSnapshotsClient,
        viewModel: DevtoolsPanelViewModel? = nil
    ) {
        _model = StateObject(
            wrappedValue: viewModel ?? DevtoolsPanelViewModel(client: client)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.isLoading && !model.hasLoadedOnce {
                        ProgressView("Loading snapshots...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    }

                    if let errorMessage = model.errorMessage {
                        DevtoolsPanelErrorBanner(message: errorMessage) {
                            Task { await model.reload() }
                        }
                    }

                    if model.hasLoadedOnce && model.snapshots.isEmpty && model.errorMessage == nil {
                        ContentUnavailableView(
                            "No snapshots",
                            systemImage: "wrench.and.screwdriver",
                            description: Text("No devtools snapshots for this agent session.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                        .accessibilityIdentifier("devtools.panel.empty")
                    }

                    ForEach(model.snapshots) { snapshot in
                        DevtoolsSnapshotCard(snapshot: snapshot)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("devtools.panel.root")
            .refreshable {
                await model.reload()
            }
            .task {
                await model.loadIfNeeded()
            }
            .navigationTitle("Devtools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

@MainActor
final class DevtoolsPanelViewModel: ObservableObject {
    @Published private(set) var snapshots: [DevtoolsSnapshotItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false

    private let client: DevtoolsSnapshotsClient
    private var didLoad = false

    init(client: DevtoolsSnapshotsClient) {
        self.client = client
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        do {
            snapshots = try await client.fetchLatestSnapshots()
            errorMessage = nil
        } catch {
            errorMessage = DevtoolsSnapshotsClient.describe(error)
        }
    }
}

struct DevtoolsSnapshotsClient {
    typealias BearerProvider = () -> String?

    enum Error: Swift.Error {
        case notSignedIn
        case invalidResponse
        case http(status: Int, body: String)
        case invalidPayload
    }

    let baseURL: URL
    let repoOwner: String
    let repoName: String
    let sessionID: String
    let bearerProvider: BearerProvider
    let session: URLSession

    init(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String,
        bearerProvider: @escaping BearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.sessionID = sessionID
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func fetchLatestSnapshots() async throws -> [DevtoolsSnapshotItem] {
        guard let bearer = bearerProvider(), !bearer.isEmpty else {
            throw Error.notSignedIn
        }

        var url = baseURL
        for component in ["api", "repos", repoOwner, repoName, "devtools", "snapshots", "latest"] {
            url.appendPathComponent(component)
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Error.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
        guard let finalURL = components.url else {
            throw Error.invalidResponse
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw Error.http(status: http.statusCode, body: body)
        }
        guard !data.isEmpty else { return [] }
        return try DevtoolsSnapshotParser.decodeSnapshots(from: data)
    }

    static func describe(_ error: Swift.Error) -> String {
        guard let error = error as? Error else {
            return error.localizedDescription
        }
        switch error {
        case .notSignedIn:
            return "Sign in again to load devtools snapshots."
        case .invalidResponse:
            return "The server returned an invalid devtools response."
        case .invalidPayload:
            return "The devtools snapshot payload was not in the expected format."
        case .http(let status, let body):
            if body.isEmpty {
                return "Devtools request failed with HTTP \(status)."
            }
            return "Devtools request failed with HTTP \(status): \(body)"
        }
    }
}

struct DevtoolsSnapshotItem: Identifiable {
    let id: String
    let kind: String
    let payload: Any
    let createdAtText: String?
    let summary: String?

    var accessibilityKind: String {
        DevtoolsSnapshotPayload.identifierKind(for: kind)
    }
}

private enum DevtoolsSnapshotParser {
    private static let envelopeKeys: Set<String> = [
        "count", "cursor", "data", "items", "latest", "next_cursor", "rows", "snapshots",
    ]

    private static let rowKeys: Set<String> = [
        "createdAt", "created_at", "id", "kind", "payload", "payloadJson", "payload_json",
        "repository_id", "session_id", "snapshotId", "snapshot_id", "summary", "workspace_id",
        "timestamp",
    ]

    static func decodeSnapshots(from data: Data) throws -> [DevtoolsSnapshotItem] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return snapshots(from: object)
    }

    private static func snapshots(from object: Any) -> [DevtoolsSnapshotItem] {
        if let array = object as? [Any] {
            return array.enumerated().compactMap { index, value in
                snapshot(from: value, fallbackKind: nil, index: index)
            }
        }

        guard let dict = object as? [String: Any] else {
            return []
        }

        for key in ["snapshots", "latest", "items", "rows", "data"] {
            if let nestedArray = dict[key] as? [Any] {
                return snapshots(from: nestedArray)
            }
            if let nestedDict = dict[key] as? [String: Any],
               !isSnapshotDictionary(dict) {
                let nested = snapshots(from: nestedDict)
                if !nested.isEmpty {
                    return nested
                }
            }
        }

        if isSnapshotDictionary(dict) {
            return snapshot(from: dict, fallbackKind: nil, index: 0).map { [$0] } ?? []
        }

        let mapped = dict.keys.sorted().enumerated().compactMap { index, key -> DevtoolsSnapshotItem? in
            guard !envelopeKeys.contains(key), let value = dict[key] else { return nil }
            return snapshot(from: value, fallbackKind: key, index: index)
        }
        return mapped
    }

    private static func snapshot(
        from value: Any,
        fallbackKind: String?,
        index: Int
    ) -> DevtoolsSnapshotItem? {
        if let dict = value as? [String: Any] {
            let kind = string(dict["kind"]) ?? fallbackKind
            guard let kind, !kind.isEmpty else { return nil }

            let payload = normalizedPayload(
                dict["payload"] ??
                    dict["payload_json"] ??
                    dict["payloadJson"] ??
                    dict["content"] ??
                    dict["value"]
            ) ?? dict

            return DevtoolsSnapshotItem(
                id: string(dict["id"]) ??
                    string(dict["snapshot_id"]) ??
                    string(dict["snapshotId"]) ??
                    "\(kind)-\(index)",
                kind: kind,
                payload: payload,
                createdAtText: string(dict["timestamp"]) ??
                    string(dict["created_at"]) ??
                    string(dict["createdAt"]),
                summary: string(dict["summary"])
            )
        }

        guard let fallbackKind, !fallbackKind.isEmpty else { return nil }
        return DevtoolsSnapshotItem(
            id: "\(fallbackKind)-\(index)",
            kind: fallbackKind,
            payload: normalizedPayload(value) ?? value,
            createdAtText: nil,
            summary: nil
        )
    }

    private static func isSnapshotDictionary(_ dict: [String: Any]) -> Bool {
        if string(dict["kind"]) != nil { return true }
        let keys = Set(dict.keys)
        return keys.contains("payload") &&
            !keys.isDisjoint(with: rowKeys)
    }

    private static func normalizedPayload(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) {
            return object
        }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String,
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

private struct DevtoolsSnapshotCard: View {
    let snapshot: DevtoolsSnapshotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(
                    snapshot.kind
                        .replacingOccurrences(of: "_", with: " ")
                        .replacingOccurrences(of: "-", with: " ")
                        .capitalized
                )
                    .font(.headline)

                Spacer(minLength: 8)

                if let createdAtText = snapshot.createdAtText {
                    Text(createdAtText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = snapshot.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            renderedPayload
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devtools.snapshot.\(snapshot.accessibilityKind).card")
    }

    @ViewBuilder
    private var renderedPayload: some View {
        switch snapshot.kind.lowercased() {
        case "command_output", "command-output", "console":
            DevtoolsCodeBlock(
                text: DevtoolsSnapshotPayload.commandOutputText(from: snapshot.payload)
            )
        case "screenshot":
            if let image = DevtoolsSnapshotPayload.image(from: snapshot.payload) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Not a screenshot")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case "tool_state", "tool-state", "file_tree", "file-tree", "network":
            DevtoolsCodeBlock(
                text: DevtoolsSnapshotPayload.prettyPrinted(snapshot.payload)
            )
        default:
            DevtoolsCodeBlock(
                text: DevtoolsSnapshotPayload.prettyPrinted(snapshot.payload)
            )
        }
    }
}

private struct DevtoolsCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text.isEmpty ? " " : text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DevtoolsPanelErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private enum DevtoolsSnapshotPayload {
    static func identifierKind(for kind: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let replacement = UnicodeScalar("-")
        var output = ""
        for scalar in kind.lowercased().unicodeScalars {
            output.unicodeScalars.append(allowed.contains(scalar) ? scalar : replacement)
        }
        return output.isEmpty ? "unknown" : output
    }

    static func commandOutputText(from payload: Any) -> String {
        if let string = payload as? String {
            return string
        }

        guard let dict = payload as? [String: Any] else {
            return prettyPrinted(payload)
        }

        var sections: [String] = []
        for key in ["command", "stdout", "stderr", "output", "text", "message"] {
            guard let value = stringValue(dict[key]), !value.isEmpty else { continue }
            if key == "output" || key == "text" || key == "message" {
                sections.append(value)
            } else {
                sections.append("\(key):\n\(value)")
            }
        }

        if !sections.isEmpty {
            return sections.joined(separator: "\n")
        }
        return prettyPrinted(payload)
    }

    static func prettyPrinted(_ value: Any) -> String {
        if let string = value as? String {
            if let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: []) {
                return prettyPrinted(object)
            }
            return string
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let rendered = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return rendered
    }

    static func image(from payload: Any) -> UIImage? {
        for candidate in imageCandidates(in: payload, keyHint: nil) {
            if let image = image(fromBase64: candidate) {
                return image
            }
        }
        return nil
    }

    private static func imageCandidates(in value: Any, keyHint: String?) -> [String] {
        if let string = value as? String {
            let lowered = string.lowercased()
            let hasImageHint = keyHint.map { isImageKey($0) } ?? false
            if hasImageHint || lowered.hasPrefix("data:image/") {
                return [string]
            }
            return []
        }

        if let dict = value as? [String: Any] {
            var directMatches: [String] = []
            let mimeType = stringValue(dict["mime_type"]) ?? stringValue(dict["mimeType"])
            if mimeType?.lowercased().hasPrefix("image/") == true,
               let data = stringValue(dict["data"]) {
                directMatches.append(data)
            }
            return dict.flatMap { entry in
                imageCandidates(in: entry.value, keyHint: entry.key)
            } + directMatches
        }

        if let array = value as? [Any] {
            return array.flatMap { imageCandidates(in: $0, keyHint: keyHint) }
        }

        return []
    }

    private static func image(fromBase64 raw: String) -> UIImage? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = candidate.range(of: "base64,", options: .caseInsensitive) {
            candidate = String(candidate[range.upperBound...])
        }
        candidate = candidate
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: candidate, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: data)
    }

    private static func isImageKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("base64") ||
            lowered.contains("image") ||
            lowered.contains("jpeg") ||
            lowered.contains("jpg") ||
            lowered.contains("png") ||
            lowered.contains("screenshot")
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
#endif
