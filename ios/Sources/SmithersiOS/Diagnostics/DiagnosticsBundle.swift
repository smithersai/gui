#if os(iOS)
import Foundation
import OSLog
import UIKit

actor DiagnosticsBundle {
    typealias FeatureFlagsProvider = () async -> [String: Bool]
    typealias LogLinesProvider = (Int) async -> [String]

    static func generate() async throws -> URL {
        try await DiagnosticsBundle().generate()
    }

    private let logLineLimit: Int
    private let networkRequestLimit: Int
    private let featureFlagsProvider: FeatureFlagsProvider
    private let logLinesProvider: LogLinesProvider
    private let networkRecorder: DiagnosticsNetworkRecorder
    private let bundle: Bundle
    private let fileManager: FileManager
    private let now: () -> Date
    private let deviceInfoProvider: () -> DiagnosticsDeviceInfo

    init(
        logLineLimit: Int = 500,
        networkRequestLimit: Int = 10,
        featureFlagsProvider: @escaping FeatureFlagsProvider = { [:] },
        logLinesProvider: LogLinesProvider? = nil,
        networkRecorder: DiagnosticsNetworkRecorder = .shared,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() },
        deviceInfoProvider: @escaping () -> DiagnosticsDeviceInfo = { DiagnosticsDeviceInfo.current() }
    ) {
        self.logLineLimit = logLineLimit
        self.networkRequestLimit = networkRequestLimit
        self.featureFlagsProvider = featureFlagsProvider
        self.logLinesProvider = logLinesProvider ?? { limit in
            await DiagnosticsOSLogCollector.collectLogLines(limit: limit)
        }
        self.networkRecorder = networkRecorder
        self.bundle = bundle
        self.fileManager = fileManager
        self.now = now
        self.deviceInfoProvider = deviceInfoProvider
    }

    func generate() async throws -> URL {
        let generatedAt = now()
        let payload = DiagnosticsPayload(
            schema_version: 1,
            generated_at: Self.timestampFormatter.string(from: generatedAt),
            app: DiagnosticsAppInfo(bundle: bundle),
            device: deviceInfoProvider(),
            feature_flags: await featureFlagsProvider(),
            logs: await logLinesProvider(logLineLimit),
            network_requests: await networkRecorder.recentRequests(limit: networkRequestLimit)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SmithersDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "smithers-diagnostics-\(Self.filenameFormatter.string(from: generatedAt)).json"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try encoder.encode(payload).write(to: url, options: [.atomic])
        return url
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

actor DiagnosticsNetworkRecorder {
    static let shared = DiagnosticsNetworkRecorder()

    private let maximumStoredRequests: Int
    private var requests: [DiagnosticsNetworkRequest] = []

    init(maximumStoredRequests: Int = 50) {
        self.maximumStoredRequests = max(10, maximumStoredRequests)
    }

    func record(url: URL?, statusCode: Int?, duration: TimeInterval, startedAt: Date = Date()) {
        guard let url else { return }
        requests.append(
            DiagnosticsNetworkRequest(
                url: DiagnosticsNetworkSanitizer.sanitizedURLString(from: url),
                status: statusCode,
                duration_ms: max(0, Int((duration * 1000).rounded())),
                started_at: DiagnosticsNetworkRequest.timestampFormatter.string(from: startedAt)
            )
        )
        if requests.count > maximumStoredRequests {
            requests.removeFirst(requests.count - maximumStoredRequests)
        }
    }

    func recentRequests(limit: Int = 10) -> [DiagnosticsNetworkRequest] {
        let boundedLimit = max(0, limit)
        guard requests.count > boundedLimit else { return requests }
        return Array(requests.suffix(boundedLimit))
    }
}

enum DiagnosticsNetworkObserver {
    private static let lock = NSLock()
    private static var isInstalled = false

    static func install() {
        lock.lock()
        defer { lock.unlock() }

        guard !isInstalled else { return }
        URLProtocol.registerClass(DiagnosticsURLProtocol.self)
        isInstalled = true
    }
}

private final class DiagnosticsURLProtocol: URLProtocol {
    private static let handledKey = "SmithersDiagnosticsURLProtocolHandled"
    private var dataTask: URLSessionDataTask?
    private var startedAt = Date()
    private lazy var forwardingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else {
            return false
        }
        guard let scheme = request.url?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        startedAt = Date()

        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        dataTask = forwardingSession.dataTask(with: mutableRequest as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.forwardingSession.finishTasksAndInvalidate() }

            let duration = Date().timeIntervalSince(self.startedAt)
            let status = (response as? HTTPURLResponse)?.statusCode
            Task {
                await DiagnosticsNetworkRecorder.shared.record(
                    url: response?.url ?? self.request.url,
                    statusCode: status,
                    duration: duration,
                    startedAt: self.startedAt
                )
            }

            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
    }
}

private enum DiagnosticsNetworkSanitizer {
    private static let sensitiveQueryNames: Set<String> = [
        "access_token",
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "client_secret",
        "code",
        "code_verifier",
        "id_token",
        "password",
        "refresh_token",
        "secret",
        "state",
        "token",
    ]

    static func sanitizedURLString(from url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.user = nil
        components.password = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                if sensitiveQueryNames.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "REDACTED")
                }
                return item
            }
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

private enum DiagnosticsOSLogCollector {
    static func collectLogLines(limit: Int) async -> [String] {
        guard limit > 0 else { return [] }

        return await Task.detached(priority: .utility) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let uptime = ProcessInfo.processInfo.systemUptime
                let lookback = min(uptime, 6 * 60 * 60)
                let position = store.position(timeIntervalSinceLatestBoot: uptime - lookback)
                let entries = try store.getEntries(at: position)

                var lines: [String] = []
                for entry in entries {
                    guard let log = entry as? OSLogEntryLog else { continue }
                    lines.append(format(log))
                    if lines.count > limit {
                        lines.removeFirst(lines.count - limit)
                    }
                }
                return lines
            } catch {
                return ["OSLogStore unavailable: \(error.localizedDescription)"]
            }
        }.value
    }

    private static func format(_ log: OSLogEntryLog) -> String {
        let timestamp = timestampFormatter.string(from: log.date)
        let subsystem = log.subsystem.isEmpty ? "default" : log.subsystem
        let category = log.category.isEmpty ? "default" : log.category
        return "\(timestamp) \(String(describing: log.level).uppercased()) \(subsystem) \(category): \(log.composedMessage)"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct DiagnosticsPayload: Encodable, Equatable {
    let schema_version: Int
    let generated_at: String
    let app: DiagnosticsAppInfo
    let device: DiagnosticsDeviceInfo
    let feature_flags: [String: Bool]
    let logs: [String]
    let network_requests: [DiagnosticsNetworkRequest]
}

struct DiagnosticsAppInfo: Encodable, Equatable {
    let bundle_identifier: String
    let version: String
    let build: String

    init(bundle: Bundle) {
        bundle_identifier = bundle.bundleIdentifier ?? "unknown"
        version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
    }
}

struct DiagnosticsDeviceInfo: Encodable, Equatable {
    let system_name: String
    let system_version: String
    let model: String
    let localized_model: String
    let user_interface_idiom: String
    let is_simulator: Bool
    let low_power_mode_enabled: Bool
    let thermal_state: String

    static func current(
        device: UIDevice = .current,
        processInfo: ProcessInfo = .processInfo
    ) -> DiagnosticsDeviceInfo {
        DiagnosticsDeviceInfo(
            system_name: device.systemName,
            system_version: device.systemVersion,
            model: device.model,
            localized_model: device.localizedModel,
            user_interface_idiom: String(describing: device.userInterfaceIdiom),
            is_simulator: isRunningInSimulator,
            low_power_mode_enabled: processInfo.isLowPowerModeEnabled,
            thermal_state: String(describing: processInfo.thermalState)
        )
    }

    private static var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

struct DiagnosticsNetworkRequest: Encodable, Equatable {
    let url: String
    let status: Int?
    let duration_ms: Int
    let started_at: String

    fileprivate static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
