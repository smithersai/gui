import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import UserNotifications
#endif

enum GUINotificationLevel: String {
    case info
    case success
    case warning
    case error
    case completion
    case approval
    case runUpdate

    var iconName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .completion:
            return "sparkles"
        case .approval:
            return "checkmark.shield.fill"
        case .runUpdate:
            return "arrow.clockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info:
            return Theme.info
        case .success:
            return Theme.success
        case .warning:
            return Theme.warning
        case .error:
            return Theme.danger
        case .completion:
            return Theme.accent
        case .approval:
            return Theme.warning
        case .runUpdate:
            return Theme.info
        }
    }
}

struct GUIToast: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
    let level: GUINotificationLevel
}

struct RunNotificationTracker {
    private(set) var seenRunStates: [String: RunStatus] = [:]
    private(set) var seenApprovals: Set<String> = []

    mutating func shouldToastRunStatus(runId: String, status: RunStatus) -> Bool {
        if seenRunStates[runId] == status {
            return false
        }
        seenRunStates[runId] = status
        return true
    }

    mutating func forgetRun(_ runId: String) {
        seenRunStates.removeValue(forKey: runId)
    }

    mutating func shouldToastApproval(_ approvalId: String) -> Bool {
        if seenApprovals.contains(approvalId) {
            return false
        }
        seenApprovals.insert(approvalId)
        return true
    }
}

protocol NativeNotificationSending: AnyObject {
    func send(title: String, message: String)
}

final class MacNativeNotificationSender: NativeNotificationSending {
    #if os(macOS)
    private lazy var center: UNUserNotificationCenter? = {
        guard !UITestSupport.isRunningUnitTests else { return nil }
        return UNUserNotificationCenter.current()
    }()
    private var requestedAuthorization = false
    #endif

    func send(title: String, message: String) {
        #if os(macOS)
        guard let center else { return }
        requestAuthorizationIfNeeded(center: center)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                AppLogger.ui.warning("Failed to post native notification", metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
        #endif
    }

    #if os(macOS)
    private func requestAuthorizationIfNeeded(center: UNUserNotificationCenter) {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.ui.warning("Native notification authorization request failed", metadata: [
                    "error": error.localizedDescription,
                ])
                return
            }
            AppLogger.ui.info("Native notification authorization status", metadata: [
                "granted": String(granted),
            ])
        }
    }
    #endif
}

#if os(macOS)
private final class AppNotificationObserverTokens {
    var didBecomeActiveObserver: NSObjectProtocol?
    var didResignActiveObserver: NSObjectProtocol?

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let didResignActiveObserver {
            NotificationCenter.default.removeObserver(didResignActiveObserver)
        }
    }
}
#endif

@MainActor
final class AppNotifications: ObservableObject {
    static let shared = AppNotifications()

    static let maxVisibleToasts = 3
    static let defaultDuration: TimeInterval = 5
    static let approvalDuration: TimeInterval = 15

    @Published private(set) var toasts: [GUIToast] = []

    private var tracker = RunNotificationTracker()
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var runEventTask: Task<Void, Never>?
    private var isAppActive = true
    private let nativeNotifications: NativeNotificationSending
    #if os(macOS)
    private let observerTokens = AppNotificationObserverTokens()
    #endif

    init(nativeNotifications: NativeNotificationSending = MacNativeNotificationSender()) {
        self.nativeNotifications = nativeNotifications
        #if os(macOS)
        isAppActive = NSApplication.shared.isActive
        observerTokens.didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppActive = true
            }
        }
        observerTokens.didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppActive = false
            }
        }
        #endif
    }

    func post(
        title: String,
        message: String = "",
        level: GUINotificationLevel,
        duration: TimeInterval = 5,
        nativeWhenInactive: Bool = false
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if toasts.count >= Self.maxVisibleToasts, let oldest = toasts.first {
            cancelDismissalTask(for: oldest.id)
            toasts.removeFirst()
        }

        let toast = GUIToast(
            id: UUID(),
            title: trimmedTitle,
            message: trimmedMessage,
            level: level
        )
        toasts.append(toast)
        scheduleAutoDismiss(for: toast.id, after: duration)

        guard nativeWhenInactive, !isAppActive else { return }
        nativeNotifications.send(title: trimmedTitle, message: trimmedMessage)
    }

    func dismiss(_ id: UUID) {
        cancelDismissalTask(for: id)
        toasts.removeAll { $0.id == id }
    }

    func dismissAll() {
        for toast in toasts {
            cancelDismissalTask(for: toast.id)
        }
        toasts.removeAll()
    }

    func beginRunEventMonitoring(smithers: SmithersClient) {
        guard runEventTask == nil else { return }

        runEventTask = Task {
            while !Task.isCancelled {
                var sawEvent = false
                for await event in smithers.streamRunEvents("all-runs") {
                    if Task.isCancelled { return }
                    sawEvent = true
                    await handleRunSSEEvent(event, smithers: smithers)
                }

                if Task.isCancelled { return }
                let delayNanoseconds: UInt64 = sawEvent ? 1_000_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    func stopRunEventMonitoring() {
        runEventTask?.cancel()
        runEventTask = nil
    }

    private func scheduleAutoDismiss(for id: UUID, after duration: TimeInterval) {
        guard duration > 0 else { return }
        cancelDismissalTask(for: id)
        dismissalTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            self.dismiss(id)
        }
    }

    private func cancelDismissalTask(for id: UUID) {
        dismissalTasks[id]?.cancel()
        dismissalTasks.removeValue(forKey: id)
    }

    private struct RunStreamEvent: Decodable {
        let type: String
        let runId: String
        let status: String?
    }

    private struct RunStreamEnvelope: Decodable {
        let event: RunStreamEvent?
        let data: RunStreamEvent?
    }

    private func handleRunSSEEvent(_ event: SSEEvent, smithers: SmithersClient) async {
        guard let runEvent = decodeRunStreamEvent(event),
              !runEvent.runId.isEmpty else {
            return
        }

        let eventType = runEvent.type.lowercased()
        let status: RunStatus?
        if eventType == "nodewaitingapproval" {
            status = .waitingApproval
        } else {
            status = runStatus(from: runEvent)
        }

        guard let status else { return }
        guard tracker.shouldToastRunStatus(runId: runEvent.runId, status: status) else { return }

        let shortID = String(runEvent.runId.prefix(8))

        switch status {
        case .running, .unknown:
            break
        case .waitingApproval:
            await notifyApprovalNeeded(runId: runEvent.runId, shortID: shortID, smithers: smithers)
        case .finished:
            tracker.forgetRun(runEvent.runId)
            post(
                title: "Run finished",
                message: "\(shortID) completed successfully",
                level: .completion,
                nativeWhenInactive: true
            )
        case .failed:
            tracker.forgetRun(runEvent.runId)
            post(
                title: "Run failed",
                message: "\(shortID) encountered an error",
                level: .error,
                nativeWhenInactive: true
            )
        case .cancelled:
            tracker.forgetRun(runEvent.runId)
            post(
                title: "Run cancelled",
                message: shortID,
                level: .runUpdate,
                nativeWhenInactive: true
            )
        }
    }

    private func notifyApprovalNeeded(runId: String, shortID: String, smithers: SmithersClient) async {
        do {
            let approvals = try await smithers.listPendingApprovals()
            if let approval = approvals.first(where: { $0.runId == runId && $0.isPending }),
               tracker.shouldToastApproval(approval.id) {
                var message = approval.gate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if message.isEmpty {
                    message = "\(shortID) is waiting for approval"
                } else if let workflowPath = approval.workflowPath,
                          !workflowPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message += "\nrun: \(shortID) · \(workflowBaseName(from: workflowPath))"
                }
                post(
                    title: "Approval needed",
                    message: message,
                    level: .approval,
                    duration: Self.approvalDuration,
                    nativeWhenInactive: true
                )
                return
            }
        } catch {
            AppLogger.ui.warning("Failed to fetch pending approvals for toast", metadata: [
                "run_id": shortID,
                "error": error.localizedDescription,
            ])
        }

        post(
            title: "Approval needed",
            message: "\(shortID) is waiting for approval",
            level: .approval,
            duration: Self.approvalDuration,
            nativeWhenInactive: true
        )
    }

    private func decodeRunStreamEvent(_ event: SSEEvent) -> RunStreamEvent? {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else {
            return nil
        }

        if let direct = try? JSONDecoder().decode(RunStreamEvent.self, from: data), !direct.runId.isEmpty {
            return direct
        }

        if let wrapped = try? JSONDecoder().decode(RunStreamEnvelope.self, from: data),
           let nested = wrapped.event ?? wrapped.data,
           !nested.runId.isEmpty {
            return nested
        }

        return nil
    }

    private func runStatus(from event: RunStreamEvent) -> RunStatus? {
        if let raw = event.status {
            let status = RunStatus.normalized(raw)
            if status != .unknown {
                return status
            }
        }

        switch event.type.lowercased() {
        case "runstarted":
            return .running
        case "runfinished":
            return .finished
        case "runfailed":
            return .failed
        case "runcancelled":
            return .cancelled
        default:
            return nil
        }
    }

    private func workflowBaseName(from path: String) -> String {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return base.isEmpty ? path : base
    }

    func setAppActiveForTesting(_ active: Bool) {
        isAppActive = active
    }
}

struct AppToastOverlay: View {
    @ObservedObject private var notifications = AppNotifications.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(notifications.toasts.reversed())) { toast in
                AppToastRow(toast: toast) {
                    notifications.dismiss(toast.id)
                }
            }
        }
        .padding(.top, 16)
        .padding(.trailing, 16)
        .accessibilityIdentifier("notifications.overlay")
    }
}

private struct AppToastRow: View {
    let toast: GUIToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.level.iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(toast.level.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)

                if !toast.message.isEmpty {
                    Text(toast.message)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notifications.dismiss.\(toast.id.uuidString)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.surface2.opacity(0.98))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(toast.level.color.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
        .accessibilityIdentifier("notifications.toast.\(toast.id.uuidString)")
    }
}
