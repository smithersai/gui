#if os(iOS)
import Foundation
import SwiftUI
import UIKit

struct SettingsView: View {
    let replayTour: () -> Void
    let onSignOut: () -> Void

    @StateObject private var model: SettingsViewModel
    @State private var backendURLText: String
    @State private var showDeleteConfirmation = false
    @State private var deleteConfirmationText = ""
    @State private var showLicenses = false
    @State private var diagnosticsShareItem: DiagnosticsShareItem?
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsExportError: String?

    private let isBackendEditable: Bool
    private let bundle: Bundle
    private let diagnosticsBundle: DiagnosticsBundle

    init(
        baseURL: URL,
        bearerProvider: @escaping @Sendable () -> String?,
        featureFlagsProvider: @escaping DiagnosticsBundle.FeatureFlagsProvider = { [:] },
        isBackendEditable: Bool = SettingsEnvironment.isPreviewBackendEditable(),
        replayTour: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        resetCachedData: @escaping @MainActor () async throws -> Void = {
            try SettingsLocalCache.resetWithoutActiveRuntime()
        },
        urlSession: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.replayTour = replayTour
        self.onSignOut = onSignOut
        self.isBackendEditable = isBackendEditable
        self.bundle = bundle
        self.diagnosticsBundle = DiagnosticsBundle(
            featureFlagsProvider: featureFlagsProvider,
            bundle: bundle
        )
        _backendURLText = State(initialValue: baseURL.absoluteString)
        _model = StateObject(
            wrappedValue: SettingsViewModel(
                baseURL: baseURL,
                bearerProvider: bearerProvider,
                resetCachedData: resetCachedData,
                urlSession: urlSession,
                bundle: bundle
            )
        )
    }

    var body: some View {
        List {
            accountSection
            preferencesSection
            supportSection
            aboutSection
        }
        .accessibilityIdentifier("settings.root")
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.loadUserIfNeeded()
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            deleteAccountSheet
        }
        .sheet(isPresented: $showLicenses) {
            SettingsLicensesView(documents: SettingsLicenseDocument.bundled(in: bundle))
        }
        .sheet(item: $diagnosticsShareItem) { item in
            DiagnosticsActivityView(url: item.url)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            switch model.accountState {
            case .idle, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading account...")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.account.loading")
            case .loaded(let profile):
                LabeledContent("Email") {
                    Text(profile.email ?? "Not provided")
                        .foregroundStyle(profile.email == nil ? .secondary : .primary)
                }
                .accessibilityIdentifier("settings.account.email")

                LabeledContent("github_username") {
                    Text(profile.githubUsername ?? "Not provided")
                        .foregroundStyle(profile.githubUsername == nil ? .secondary : .primary)
                }
                .accessibilityIdentifier("settings.account.github-username")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await model.loadUser() }
                    }
                    .accessibilityIdentifier("settings.account.retry")
                }
                .accessibilityIdentifier("settings.account.error")
            }

            Button(role: .destructive, action: onSignOut) {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("settings.sign-out")

            Button(role: .destructive) {
                deleteConfirmationText = ""
                model.resetDeleteState()
                showDeleteConfirmation = true
            } label: {
                Label("Delete account", systemImage: "trash")
            }
            .accessibilityIdentifier("settings.delete-account")
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            if isBackendEditable {
                TextField("Backend URL", text: $backendURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.backend-url")
            } else {
                LabeledContent("Backend URL") {
                    Text(backendURLText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.backend-url")
            }

            Button {
                replayTour()
            } label: {
                Label("Replay tour", systemImage: "play.rectangle")
            }
            .accessibilityIdentifier("settings.replay-tour")

            Button {
                Task { await model.resetCachedData() }
            } label: {
                Label("Reset all cached data", systemImage: "arrow.clockwise.circle")
            }
            .disabled(model.isResetting)
            .accessibilityIdentifier("settings.reset-cache")

            if let resetStatus = model.resetStatusText {
                Text(resetStatus)
                    .font(.footnote)
                    .foregroundStyle(model.resetStatusIsError ? .red : .secondary)
                    .accessibilityIdentifier("settings.reset-cache.status")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: model.versionText)
                .accessibilityIdentifier("settings.version")

            Link(destination: URL(string: "https://smithers.ai/privacy")!) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settings.privacy-policy")

            Link(destination: URL(string: "https://smithers.ai/terms")!) {
                Label("Terms of service", systemImage: "doc.text")
            }
            .accessibilityIdentifier("settings.terms-of-service")

            Button {
                showLicenses = true
            } label: {
                Label("Open-source licenses", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("settings.open-source-licenses")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            Button {
                Task { await exportDiagnostics() }
            } label: {
                if isExportingDiagnostics {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing diagnostics...")
                    }
                } else {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExportingDiagnostics)
            .accessibilityIdentifier("settings.export-diagnostics")

            if let diagnosticsExportError {
                Text(diagnosticsExportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.export-diagnostics.error")
            }
        }
    }

    private func exportDiagnostics() async {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        diagnosticsExportError = nil
        do {
            let url = try await diagnosticsBundle.generate()
            diagnosticsShareItem = DiagnosticsShareItem(url: url)
        } catch {
            diagnosticsExportError = "Diagnostics export failed: \(SettingsViewModel.describe(error))"
        }
        isExportingDiagnostics = false
    }

    private var deleteAccountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Permanently delete your account? Type DELETE to confirm.")
                        .font(.body)

                    TextField("DELETE", text: $deleteConfirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.delete-account.confirm-input")

                    if let message = model.deleteErrorText {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.delete-account.error")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            let didDelete = await model.deleteAccount(confirmText: deleteConfirmationText)
                            if didDelete {
                                onSignOut()
                            }
                        }
                    } label: {
                        if model.isDeletingAccount {
                            ProgressView()
                        } else {
                            Text("Delete account")
                        }
                    }
                    .disabled(deleteConfirmationText != "DELETE" || model.isDeletingAccount)
                    .accessibilityIdentifier("settings.delete-account.confirm-button")
                }
            }
            .accessibilityIdentifier("settings.delete-account.modal")
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showDeleteConfirmation = false
                    }
                    .accessibilityIdentifier("settings.delete-account.cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DiagnosticsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticsActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
final class SettingsViewModel: ObservableObject {
    enum AccountState: Equatable {
        case idle
        case loading
        case loaded(SettingsUserProfile)
        case failed(String)
    }

    enum CacheResetState: Equatable {
        case idle
        case resetting
        case reset
        case failed(String)
    }

    enum DeleteState: Equatable {
        case idle
        case deleting
        case deleted
        case failed(String)
    }

    @Published private(set) var accountState: AccountState = .idle
    @Published private(set) var cacheResetState: CacheResetState = .idle
    @Published private(set) var deleteState: DeleteState = .idle

    let versionText: String

    private let baseURL: URL
    private let bearerProvider: @Sendable () -> String?
    private let resetCachedDataHandler: @MainActor () async throws -> Void
    private let client: SettingsAPIClient
    private let accountDeletionEnabled: Bool

    init(
        baseURL: URL,
        bearerProvider: @escaping @Sendable () -> String?,
        resetCachedData: @escaping @MainActor () async throws -> Void,
        urlSession: URLSession,
        bundle: Bundle,
        accountDeletionEnabled: Bool = SettingsEnvironment.isAccountDeletionEnabled()
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.resetCachedDataHandler = resetCachedData
        self.client = SettingsAPIClient(session: urlSession)
        self.accountDeletionEnabled = accountDeletionEnabled
        self.versionText = SettingsViewModel.versionText(from: bundle)
    }

    var isResetting: Bool {
        cacheResetState == .resetting
    }

    var resetStatusText: String? {
        switch cacheResetState {
        case .idle:
            return nil
        case .resetting:
            return "Resetting cached data..."
        case .reset:
            return "Cached data reset."
        case .failed(let message):
            return message
        }
    }

    var resetStatusIsError: Bool {
        if case .failed = cacheResetState {
            return true
        }
        return false
    }

    var isDeletingAccount: Bool {
        deleteState == .deleting
    }

    var deleteErrorText: String? {
        if case .failed(let message) = deleteState {
            return message
        }
        return nil
    }

    func loadUserIfNeeded() async {
        guard accountState == .idle else { return }
        await loadUser()
    }

    func loadUser() async {
        guard let bearer = currentBearer() else {
            accountState = .failed("No active session.")
            return
        }

        accountState = .loading
        do {
            let profile = try await client.fetchCurrentUser(baseURL: baseURL, bearer: bearer)
            accountState = .loaded(profile)
        } catch {
            accountState = .failed(Self.describe(error))
        }
    }

    func resetCachedData() async {
        guard cacheResetState != .resetting else { return }
        cacheResetState = .resetting
        do {
            try await resetCachedDataHandler()
            cacheResetState = .reset
        } catch {
            cacheResetState = .failed("Cache reset failed: \(Self.describe(error))")
        }
    }

    func resetDeleteState() {
        deleteState = .idle
    }

    func deleteAccount(confirmText: String) async -> Bool {
        guard confirmText == "DELETE" else {
            deleteState = .failed("Type DELETE to confirm.")
            return false
        }
        guard accountDeletionEnabled else {
            deleteState = .failed("Account deletion is disabled in E2E mode.")
            return false
        }
        guard let bearer = currentBearer() else {
            deleteState = .failed("No active session.")
            return false
        }

        deleteState = .deleting
        do {
            try await client.deleteCurrentUser(baseURL: baseURL, bearer: bearer)
            deleteState = .deleted
            return true
        } catch {
            deleteState = .failed(Self.describe(error))
            return false
        }
    }

    private func currentBearer() -> String? {
        guard let token = bearerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private static func versionText(from bundle: Bundle) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case (.some(let version), .some(let build)):
            return "\(version) (\(build))"
        case (.some(let version), .none):
            return version
        case (.none, .some(let build)):
            return build
        case (.none, .none):
            return "Unknown"
        }
    }

    fileprivate static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct SettingsUserProfile: Equatable, Decodable {
    let email: String?
    let githubUsername: String?

    init(email: String?, githubUsername: String?) {
        self.email = email
        self.githubUsername = githubUsername
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.user, .data, .account] {
            if let nested = try? container.decode(SettingsUserProfile.self, forKey: key) {
                self = nested
                return
            }
        }

        self.email = Self.firstString(in: container, keys: [.email, .lowerEmail])
        self.githubUsername = Self.firstString(
            in: container,
            keys: [.githubUsername, .githubUsernameCamel, .githubLogin, .username, .login]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case user
        case data
        case account
        case email
        case lowerEmail = "lower_email"
        case githubUsername = "github_username"
        case githubUsernameCamel = "githubUsername"
        case githubLogin = "github_login"
        case username
        case login
    }

    private static func firstString(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

private final class SettingsAPIClient {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchCurrentUser(baseURL: URL, bearer: String) async throws -> SettingsUserProfile {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/user"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = try Self.statusCode(from: response)
        guard (200...299).contains(status) else {
            throw SettingsAPIError.badStatus(status, Self.responseSnippet(data))
        }
        do {
            return try JSONDecoder().decode(SettingsUserProfile.self, from: data)
        } catch {
            throw SettingsAPIError.invalidUserResponse
        }
    }

    func deleteCurrentUser(baseURL: URL, bearer: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/user"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = try Self.statusCode(from: response)
        guard (200...299).contains(status) else {
            throw SettingsAPIError.badStatus(status, Self.responseSnippet(data))
        }
    }

    private static func statusCode(from response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else {
            throw SettingsAPIError.invalidHTTPResponse
        }
        return http.statusCode
    }

    private static func responseSnippet(_ data: Data) -> String {
        let body = String(data: data.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? "No response body." : body
    }
}

private enum SettingsAPIError: LocalizedError, Equatable {
    case invalidHTTPResponse
    case invalidUserResponse
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Server returned an invalid response."
        case .invalidUserResponse:
            return "Server returned an unexpected account response."
        case .badStatus(let status, let body):
            return "Server returned HTTP \(status): \(body)"
        }
    }
}

enum SettingsLocalCache {
    static func resetWithoutActiveRuntime() throws {
        URLCache.shared.removeAllCachedResponses()
        try removeRuntimeCacheDirectory()
    }

    static func resetWithActiveRuntime(_ session: RuntimeSession?) throws {
        URLCache.shared.removeAllCachedResponses()
        if let session {
            try session.wipeCache()
        } else {
            try removeRuntimeCacheDirectory()
        }
    }

    private static func removeRuntimeCacheDirectory() throws {
        guard let directory = runtimeCacheDirectoryURL() else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func runtimeCacheDirectoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SmithersRuntime", isDirectory: true)
    }
}

enum SettingsEnvironment {
    static func isPreviewBackendEditable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Bool {
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return true
        }
        if parsedPreviewURL(environment["PLUE_PREVIEW_URL"]) != nil {
            return true
        }
        return parsedPreviewURL(bundle.object(forInfoDictionaryKey: "SmithersPreviewURL")) != nil
    }

    static func isAccountDeletionEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["PLUE_E2E_MODE"] != "1"
    }

    private static func parsedPreviewURL(_ rawValue: Any?) -> URL? {
        guard let raw = rawValue as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}

struct SettingsLicenseDocument: Identifiable, Equatable {
    let id: String
    let name: String
    let body: String

    static func bundled(in bundle: Bundle = .main) -> [SettingsLicenseDocument] {
        guard let resourceURL = bundle.resourceURL else { return [] }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var documents: [SettingsLicenseDocument] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let lowercased = name.lowercased()
            guard lowercased.contains("license") || lowercased.contains("notice") else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else {
                continue
            }
            documents.append(
                SettingsLicenseDocument(
                    id: url.path,
                    name: name,
                    body: body.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return documents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SettingsLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    let documents: [SettingsLicenseDocument]

    var body: some View {
        NavigationStack {
            List {
                if documents.isEmpty {
                    Text("No bundled LICENSE files found.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.licenses.empty")
                } else {
                    ForEach(documents) { document in
                        NavigationLink(document.name) {
                            ScrollView {
                                Text(document.body)
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .textSelection(.enabled)
                            }
                            .navigationTitle(document.name)
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .accessibilityIdentifier("settings.licenses.row.\(document.name)")
                    }
                }
            }
            .accessibilityIdentifier("settings.licenses.sheet")
            .navigationTitle("Open-source licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.licenses.close")
                }
            }
        }
    }
}
#endif
