#if os(iOS)
import SwiftUI
#if canImport(SmithersAuth)
import SmithersAuth
#endif

@MainActor
final class IOSRemoteAccessGateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case enabled
        case disabled
    }

    @Published private(set) var state: State = .idle

    private let featureFlags: FeatureFlagsClient
    private let refreshInterval: TimeInterval
    private let loadingTimeout: TimeInterval
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var refreshLoopTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        featureFlags: FeatureFlagsClient,
        refreshInterval: TimeInterval = 60,
        loadingTimeout: TimeInterval = 3,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { duration in
            try await Task.sleep(nanoseconds: duration)
        }
    ) {
        self.featureFlags = featureFlags
        self.refreshInterval = refreshInterval
        self.loadingTimeout = loadingTimeout
        self.sleep = sleep
    }

    func activate() {
        guard refreshLoopTask == nil else { return }
        if let override = FeatureFlagsEnvironment.remoteSandboxEnabledOverride() {
            state = override ? .enabled : .disabled
        } else {
            state = .checking
            scheduleLoadingTimeout()
        }

        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow(force: true)

            while !Task.isCancelled {
                try? await self.sleep(Self.nanoseconds(for: self.refreshInterval))
                if Task.isCancelled { break }
                await self.refreshNow(force: true)
            }
        }
    }

    func deactivate(resetState: Bool = true) {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if resetState {
            state = .idle
        }
    }

    func refreshNow(force: Bool = true) async {
        let override = FeatureFlagsEnvironment.remoteSandboxEnabledOverride()
        do {
            let snapshot = try await featureFlags.refresh(force: force)
            cancelLoadingTimeout()
            let isEnabled = override ?? snapshot.isRemoteSandboxEnabled
            state = isEnabled ? .enabled : .disabled
        } catch {
            if let override {
                cancelLoadingTimeout()
                state = override ? .enabled : .disabled
            }
            // Keep the current rendered state. The timeout task collapses
            // the initial `.checking` state after 3s using the best cached
            // value we have, which defaults to disabled/off.
        }
    }

    private func scheduleLoadingTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.nanoseconds(for: self.loadingTimeout))
            if Task.isCancelled { return }
            if self.state == .checking {
                self.state = self.featureFlags.effectiveRemoteSandboxEnabled()
                    ? .enabled
                    : .disabled
            }
        }
    }

    private func cancelLoadingTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }
}

struct SignedInRemoteAccessSurface: View {
    @ObservedObject var access: IOSRemoteAccessGateModel
    @ObservedObject var featureFlags: FeatureFlagsClient
    let baseURL: URL
    let e2e: E2EConfig?
    let bearerProvider: @Sendable () -> String?
    let onSignOut: () -> Void
    let replayTour: () -> Void

    init(
        access: IOSRemoteAccessGateModel,
        featureFlags: FeatureFlagsClient,
        baseURL: URL,
        e2e: E2EConfig?,
        bearerProvider: @escaping @Sendable () -> String?,
        onSignOut: @escaping () -> Void,
        replayTour: @escaping () -> Void = {}
    ) {
        self.access = access
        self.featureFlags = featureFlags
        self.baseURL = baseURL
        self.e2e = e2e
        self.bearerProvider = bearerProvider
        self.onSignOut = onSignOut
        self.replayTour = replayTour
    }

    var body: some View {
        Group {
            switch access.state {
            case .idle, .checking:
                RemoteAccessLoadingView()
            case .disabled:
                RemoteAccessDisabledView(onSignOut: onSignOut)
            case .enabled:
                IOSContentShell(
                    featureFlags: featureFlags,
                    baseURL: baseURL,
                    e2e: e2e,
                    bearerProvider: bearerProvider,
                    onSignOut: onSignOut,
                    replayTour: replayTour
                )
            }
        }
        .task { access.activate() }
        .onDisappear { access.deactivate() }
    }
}

private struct RemoteAccessLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Checking access…")
                .font(.headline)
            Text("This should only take a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("access.loading.ios")
    }
}

private struct RemoteAccessDisabledView: View {
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.slash")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Remote sandboxes aren't enabled for your account. Contact support.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Sign out", role: .destructive, action: onSignOut)
                .accessibilityIdentifier("access.disabled.ios.sign-out")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("access.disabled.ios")
    }
}
#endif
