import Foundation
import SwiftUI

struct SurfaceNotification: Identifiable, Hashable {
    let id: String
    let workspaceId: String?
    let surfaceId: String
    let title: String
    let body: String
    let timestamp: Date
}

@MainActor
final class SurfaceNotificationStore: ObservableObject {
    static let shared = SurfaceNotificationStore()

    @Published private(set) var notificationsBySurfaceId: [String: SurfaceNotification] = [:]
    @Published private(set) var notificationCountBySurfaceId: [String: Int] = [:]
    @Published private(set) var unreadSurfaceIds: Set<String> = []
    @Published private(set) var focusedIndicatorSurfaceIds: Set<String> = []
    @Published private(set) var erroredSurfaceIds: Set<String> = []
    @Published private(set) var surfaceWorkspaceIds: [String: String] = [:]
    @Published private(set) var focusedSurfaceId: String?
    @Published private(set) var focusedWorkspaceId: String?

    private init() {}

    func register(surfaceId: String, workspaceId: String) {
        surfaceWorkspaceIds[surfaceId] = workspaceId
    }

    func unregister(surfaceId: String) {
        surfaceWorkspaceIds[surfaceId] = nil
        notificationsBySurfaceId[surfaceId] = nil
        notificationCountBySurfaceId[surfaceId] = nil
        unreadSurfaceIds.remove(surfaceId)
        focusedIndicatorSurfaceIds.remove(surfaceId)
        erroredSurfaceIds.remove(surfaceId)
        if focusedSurfaceId == surfaceId {
            focusedSurfaceId = nil
        }
    }

    func markErrored(surfaceId: String) {
        erroredSurfaceIds.insert(surfaceId)
    }

    func clearErrored(surfaceId: String) {
        erroredSurfaceIds.remove(surfaceId)
    }

    func hasError(surfaceId: String) -> Bool {
        erroredSurfaceIds.contains(surfaceId)
    }

    func setFocusedSurface(_ surfaceId: String?, workspaceId: String?) {
        focusedSurfaceId = surfaceId
        focusedWorkspaceId = workspaceId
    }

    func addNotification(surfaceId: String, title: String, body: String) {
        let workspaceId = surfaceWorkspaceIds[surfaceId]
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let notification = SurfaceNotification(
            id: UUID().uuidString,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: cleanTitle.isEmpty ? "Terminal" : cleanTitle,
            body: cleanBody,
            timestamp: Date()
        )

        notificationsBySurfaceId[surfaceId] = notification
        notificationCountBySurfaceId[surfaceId, default: 0] += 1
        if focusedSurfaceId == surfaceId {
            focusedIndicatorSurfaceIds.insert(surfaceId)
        } else {
            unreadSurfaceIds.insert(surfaceId)
        }

        if focusedSurfaceId != surfaceId {
            AppNotifications.shared.post(
                title: notification.title,
                message: notification.body.isEmpty ? "Terminal needs attention." : notification.body,
                level: .info
            )
        }
    }

    func markRead(surfaceId: String) {
        unreadSurfaceIds.remove(surfaceId)
        focusedIndicatorSurfaceIds.remove(surfaceId)
        notificationCountBySurfaceId[surfaceId] = 0
    }

    func flashFocusedSurface(duration: TimeInterval = 0.75) {
        guard let focusedSurfaceId else {
            AppNotifications.shared.post(title: "Workspace", message: "No focused pane to flash.", level: .info)
            return
        }

        focusedIndicatorSurfaceIds.insert(focusedSurfaceId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.focusedIndicatorSurfaceIds.remove(focusedSurfaceId)
        }
    }

    func markWorkspaceRead(_ workspaceId: String) {
        let surfaceIds = surfaceWorkspaceIds
            .filter { $0.value == workspaceId }
            .map(\.key)
        for surfaceId in surfaceIds {
            markRead(surfaceId: surfaceId)
        }
    }

    func hasVisibleIndicator(surfaceId: String) -> Bool {
        unreadSurfaceIds.contains(surfaceId) || focusedIndicatorSurfaceIds.contains(surfaceId)
    }

    func workspaceHasIndicator(_ workspaceId: String) -> Bool {
        surfaceWorkspaceIds.contains { surfaceId, mappedWorkspaceId in
            mappedWorkspaceId == workspaceId && hasVisibleIndicator(surfaceId: surfaceId)
        }
    }

    func latestUnreadSurface(in workspaceId: String? = nil) -> String? {
        notificationsBySurfaceId.values
            .filter { notification in
                unreadSurfaceIds.contains(notification.surfaceId)
                    && (workspaceId == nil || notification.workspaceId == workspaceId)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .first?
            .surfaceId
    }
}
