import Foundation

private enum AppVersionInfo {
    static func currentVersionLabel(bundle: Bundle = .main) -> String {
        let rawShortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let shortVersion = rawShortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBuildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let buildNumber = rawBuildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (shortVersion?.isEmpty == false ? shortVersion : nil, buildNumber?.isEmpty == false ? buildNumber : nil) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return "build-\(build)"
        default:
            return "dev"
        }
    }
}

enum FeedbackCategoryOption: String, CaseIterable, Identifiable, Sendable {
    case bug = "bug"
    case badResult = "bad_result"
    case goodResult = "good_result"
    case other = "other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug:
            return "bug"
        case .badResult:
            return "bad result"
        case .goodResult:
            return "good result"
        case .other:
            return "other"
        }
    }

    var description: String {
        switch self {
        case .bug:
            return "Crash, error message, hang, or broken UI/behavior."
        case .badResult:
            return "Output was off-target, incorrect, incomplete, or unhelpful."
        case .goodResult:
            return "Helpful, correct, high-quality, or delightful result worth celebrating."
        case .other:
            return "Slowness, feature suggestion, UX feedback, or anything else."
        }
    }

    var composerTitle: String {
        "Tell us more (\(title))"
    }

    var placeholder: String {
        "(optional) Write a short description to help us further"
    }

    var sentryLevel: String {
        switch self {
        case .bug, .badResult:
            return "error"
        case .goodResult, .other:
            return "info"
        }
    }

    var displayClassification: String {
        switch self {
        case .bug:
            return "Bug"
        case .badResult:
            return "Bad result"
        case .goodResult:
            return "Good result"
        case .other:
            return "Other"
        }
    }
}

struct FeedbackContext: Sendable, Equatable {
    let appVersion: String
    let workspace: String
    let activeView: String
    let threadID: String
    let recentError: String?

    static func make(
        appVersion: String? = nil,
        workspace: String,
        activeView: String,
        threadID: String?,
        recentError: String?
    ) -> Self {
        let normalizedThread = normalizedThreadID(from: threadID)
        let normalizedError = recentError?.trimmingCharacters(in: .whitespacesAndNewlines)

        return Self(
            appVersion: (appVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                ?? AppVersionInfo.currentVersionLabel(),
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines),
            activeView: activeView.trimmingCharacters(in: .whitespacesAndNewlines),
            threadID: normalizedThread,
            recentError: normalizedError?.nilIfEmpty
        )
    }

    private static func normalizedThreadID(from raw: String?) -> String {
        if let raw, let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return trimmed
        }
        return "no-active-thread-\(UUID().uuidString.lowercased())"
    }
}

struct FeedbackSubmissionRequest: Sendable {
    let category: FeedbackCategoryOption
    let note: String?
    let includeLogs: Bool
    let context: FeedbackContext
}

struct FeedbackUploadResult: Sendable, Equatable {
    let issueURL: URL
    let threadID: String
    let includeLogs: Bool
}

enum FeedbackReporterError: LocalizedError {
    case invalidResponse
    case uploadFailed(statusCode: Int, body: String)
    case jsonEncoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Feedback upload failed because the server response was invalid."
        case let .uploadFailed(statusCode, body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "Feedback upload failed with HTTP \(statusCode)."
            }
            return "Feedback upload failed with HTTP \(statusCode): \(trimmedBody)"
        case let .jsonEncoding(reason):
            return "Feedback payload could not be encoded: \(reason)"
        }
    }
}

struct FeedbackReporter {
    private static let sentryDSN =
        "https://ae32ed50620d7a7792c1ce5df38b3e3e@o33249.ingest.us.sentry.io/4510195390611458"
    private static let sentryEnvelopeURL =
        URL(string: "https://o33249.ingest.us.sentry.io/api/4510195390611458/envelope/")!
    private static let issueBaseURL = URL(string: "https://github.com/openai/codex/issues/new")!
    private static let issueTemplate = "2-bug-report.yml"
    private static let uploadTimeoutSeconds: TimeInterval = 10

    private let sendEnvelope: @Sendable (Data) async throws -> Void
    private let loadLogData: @Sendable () async -> Data?

    init(
        sendEnvelope: @escaping @Sendable (Data) async throws -> Void = { envelope in
            try await FeedbackReporter.defaultSendEnvelope(envelope)
        },
        loadLogData: @escaping @Sendable () async -> Data? = {
            await FeedbackReporter.defaultLoadLogData()
        }
    ) {
        self.sendEnvelope = sendEnvelope
        self.loadLogData = loadLogData
    }

    func submit(_ request: FeedbackSubmissionRequest) async throws -> FeedbackUploadResult {
        let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let logs = request.includeLogs ? (await loadLogData() ?? Data()) : nil
        let envelope = try Self.makeEnvelope(request: request, note: note, logs: logs)
        try await sendEnvelope(envelope)

        return FeedbackUploadResult(
            issueURL: Self.issueURL(for: request.context.threadID),
            threadID: request.context.threadID,
            includeLogs: request.includeLogs
        )
    }

    static func makeEnvelope(request: FeedbackSubmissionRequest, note: String?, logs: Data?) throws -> Data {
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sentAt = DateFormatters.iso8601InternetDateTimeWithFractionalSeconds.string(from: Date())

        var tags: [String: String] = [
            "thread_id": limitedTagValue(request.context.threadID),
            "classification": request.category.rawValue,
            "cli_version": limitedTagValue(request.context.appVersion),
            "workspace": limitedTagValue(request.context.workspace),
            "active_view": limitedTagValue(request.context.activeView),
            "source": "smithers_gui",
        ]

        if let note {
            tags["reason"] = limitedTagValue(note)
        }
        if let recentError = request.context.recentError?.nilIfEmpty {
            tags["recent_error"] = limitedTagValue(recentError)
        }

        let event = SentryEvent(
            eventID: eventID,
            timestamp: sentAt,
            level: request.category.sentryLevel,
            message: "[\(request.category.displayClassification)]: Codex session \(request.context.threadID)",
            tags: tags,
            exception: note.map {
                SentryExceptionContainer(values: [
                    SentryException(type: "[\(request.category.displayClassification)]: Codex session \(request.context.threadID)", value: $0),
                ])
            }
        )

        let encoder = JSONEncoder()
        let eventData = try encoder.encode(event)

        var envelope = Data()
        try appendJSONLine(
            [
                "event_id": eventID,
                "dsn": sentryDSN,
                "sent_at": sentAt,
            ],
            to: &envelope
        )

        try appendJSONLine(
            [
                "type": "event",
                "length": eventData.count,
            ],
            to: &envelope
        )
        envelope.append(eventData)
        envelope.append(0x0A)

        if let logs {
            try appendJSONLine(
                [
                    "type": "attachment",
                    "length": logs.count,
                    "filename": "codex-logs.log",
                    "content_type": "text/plain",
                ],
                to: &envelope
            )
            envelope.append(logs)
            envelope.append(0x0A)
        }

        return envelope
    }

    private static func appendJSONLine(_ object: [String: Any], to envelope: inout Data) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw FeedbackReporterError.jsonEncoding("invalid JSON object")
        }
        let line = try JSONSerialization.data(withJSONObject: object, options: [])
        envelope.append(line)
        envelope.append(0x0A)
    }

    private static func limitedTagValue(_ value: String, limit: Int = 200) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }

    private static func issueURL(for threadID: String) -> URL {
        var components = URLComponents(url: issueBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "template", value: issueTemplate),
            URLQueryItem(name: "steps", value: "Uploaded thread: \(threadID)"),
        ]
        return components?.url ?? issueBaseURL
    }

    private static func defaultLoadLogData() async -> Data? {
        guard let fileURL = await AppLogger.fileWriter.exportLog() else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    private static func defaultSendEnvelope(_ envelope: Data) async throws {
        var request = URLRequest(url: sentryEnvelopeURL)
        request.httpMethod = "POST"
        request.httpBody = envelope
        request.timeoutInterval = uploadTimeoutSeconds
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackReporterError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw FeedbackReporterError.uploadFailed(statusCode: http.statusCode, body: body)
        }
    }
}

private struct SentryEvent: Encodable {
    let eventID: String
    let timestamp: String
    let level: String
    let message: String
    let tags: [String: String]
    let exception: SentryExceptionContainer?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp
        case level
        case message
        case tags
        case exception
    }
}

private struct SentryExceptionContainer: Encodable {
    let values: [SentryException]
}

private struct SentryException: Encodable {
    let type: String
    let value: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
