import Foundation
import CSmithersKit
#if canImport(Combine)
import Combine
#endif

// MARK: - Models

struct DevTelemetryEvent: Identifiable, Equatable {
    enum Source: String { case zig, swift }

    let id: UInt64
    let timestamp: Date
    let level: LogLevel
    let subsystem: String
    let name: String
    let durationMs: Int64?
    let fieldsJSON: String?
    let source: Source

    var oneLiner: String {
        var parts = [String]()
        parts.append("\(subsystem)·\(name)")
        if let durationMs { parts.append("\(durationMs)ms") }
        if let fieldsJSON { parts.append(fieldsJSON) }
        return parts.joined(separator: " ")
    }
}

struct DevTelemetryMethodStat: Identifiable, Equatable {
    let id: String
    var key: String { id }
    let count: UInt64
    let errors: UInt64
    let lastMs: Int64
    let maxMs: Int64
    let avgMs: Double
    let buckets: [UInt64]
    let bucketUpperMs: [Int64]

    var errorRate: Double {
        guard count > 0 else { return 0 }
        return Double(errors) / Double(count)
    }
}

struct DevTelemetrySnapshot: Equatable {
    let capturedAt: Date
    let startedAtMs: Int64
    let nowMs: Int64
    let totalEventSeq: UInt64
    let droppedEvents: UInt64
    let ringCapacity: UInt64
    let minLevel: Int
    let counters: [(String, UInt64)]
    let methods: [DevTelemetryMethodStat]

    static func == (lhs: DevTelemetrySnapshot, rhs: DevTelemetrySnapshot) -> Bool {
        lhs.capturedAt == rhs.capturedAt
            && lhs.totalEventSeq == rhs.totalEventSeq
            && lhs.droppedEvents == rhs.droppedEvents
            && lhs.counters.elementsEqual(rhs.counters, by: { $0 == $1 })
            && lhs.methods == rhs.methods
    }

    static let empty = DevTelemetrySnapshot(
        capturedAt: .distantPast,
        startedAtMs: 0,
        nowMs: 0,
        totalEventSeq: 0,
        droppedEvents: 0,
        ringCapacity: 0,
        minLevel: 1,
        counters: [],
        methods: []
    )
}

// MARK: - Store

/// Polls the libsmithers observability runtime and exposes recent events +
/// metrics to the dev-mode UI. Also accepts Swift-side events so the dev
/// timeline shows both Zig and host-side activity in one stream.
@MainActor
final class DevTelemetryStore: ObservableObject {
    static let shared = DevTelemetryStore()

    @Published private(set) var events: [DevTelemetryEvent] = []
    @Published private(set) var snapshot: DevTelemetrySnapshot = .empty
    @Published private(set) var isPolling: Bool = false
    @Published private(set) var lastPollError: String?

    private let bufferLimit = 1000
    private var lastSeqDrained: UInt64 = 0
    private var pollTimer: Timer?
    private var pollIntervalSeconds: TimeInterval = 2

    init() {
        // Loaded lazily; callers invoke start() once the panel is shown.
    }

    /// Begin polling libsmithers for new events + metrics.
    func start() {
        guard !isPolling else { return }
        isPolling = true
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        Task { @MainActor in self.poll() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isPolling = false
    }

    func setPollInterval(_ seconds: TimeInterval) {
        pollIntervalSeconds = max(0.5, seconds)
        if isPolling {
            stop()
            start()
        }
    }

    /// Pull a fresh batch from libsmithers. Safe to call from MainActor.
    func poll() {
        let zigEvents = drainZigEvents()
        if !zigEvents.isEmpty {
            appendEvents(zigEvents)
        }
        snapshot = readMetricsSnapshot()
    }

    /// Record a Swift-side event into the same telemetry stream. This forwards
    /// into the libsmithers ring (via FFI) so the same queryable buffer holds
    /// both sources, AND mirrors locally for immediate UI updates without
    /// waiting for the next poll.
    func emit(
        level: LogLevel = .info,
        subsystem: String,
        name: String,
        durationMs: Int64? = nil,
        fields: [String: String]? = nil
    ) {
        let fieldsJSON: String? = fields.flatMap { encodeFieldsJSON($0) }
        smithers_obs_emit(
            Int32(level.obsLevel),
            subsystem,
            name,
            durationMs ?? -1,
            fieldsJSON
        )
        // Mirror into local UI buffer immediately so users see Swift events
        // without poll lag. The matching record from the next zig drain will
        // be deduped by seq.
        let mirror = DevTelemetryEvent(
            id: UInt64.max - UInt64(events.count + 1), // sentinel; never collides with zig seq
            timestamp: Date(),
            level: level,
            subsystem: subsystem,
            name: name,
            durationMs: durationMs,
            fieldsJSON: fieldsJSON,
            source: .swift
        )
        appendEvents([mirror])
    }

    /// Record a per-method observation in the libsmithers histogram. Use this
    /// to instrument Swift-side wrappers around RPC calls so the metrics
    /// snapshot shows latency for both Zig and Swift methods.
    func recordMethod(_ key: String, durationMs: Int64, isError: Bool) {
        smithers_obs_record_method(key, durationMs, isError)
    }

    func incrementCounter(_ key: String, by delta: UInt64 = 1) {
        smithers_obs_increment_counter(key, delta)
    }

    func clearLocalBuffer() {
        events.removeAll()
        lastSeqDrained = 0
    }

    // MARK: - Private

    private func drainZigEvents() -> [DevTelemetryEvent] {
        let raw = smithers_obs_drain_json(lastSeqDrained)
        defer { smithers_string_free(raw) }
        guard let ptr = raw.ptr else { return [] }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([RawZigEvent].self, from: data)
            var out: [DevTelemetryEvent] = []
            out.reserveCapacity(decoded.count)
            for raw in decoded {
                if raw.seq > lastSeqDrained { lastSeqDrained = raw.seq }
                out.append(.init(
                    id: raw.seq,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.tsMs) / 1000),
                    level: LogLevel(obsLevel: raw.level),
                    subsystem: raw.subsystem,
                    name: raw.name,
                    durationMs: raw.durationMs,
                    fieldsJSON: raw.fieldsString,
                    source: .zig
                ))
            }
            lastPollError = nil
            return out
        } catch {
            lastPollError = "drain decode: \(error.localizedDescription)"
            return []
        }
    }

    private func readMetricsSnapshot() -> DevTelemetrySnapshot {
        let raw = smithers_obs_metrics_json()
        defer { smithers_string_free(raw) }
        guard let ptr = raw.ptr else { return snapshot }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return snapshot }
        do {
            let decoded = try JSONDecoder().decode(RawMetricsSnapshot.self, from: data)
            let sortedCounters = decoded.counters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            let methods = decoded.methods
                .map { (key, value) in
                    DevTelemetryMethodStat(
                        id: key,
                        count: value.count,
                        errors: value.errors,
                        lastMs: value.lastMs,
                        maxMs: value.maxMs,
                        avgMs: value.avgMs,
                        buckets: value.buckets,
                        bucketUpperMs: value.bucketUpperMs
                    )
                }
                .sorted { $0.id < $1.id }
            return DevTelemetrySnapshot(
                capturedAt: Date(),
                startedAtMs: decoded.startedAtMs,
                nowMs: decoded.nowMs,
                totalEventSeq: decoded.eventsSeq,
                droppedEvents: decoded.eventsDropped,
                ringCapacity: decoded.eventsCapacity,
                minLevel: decoded.minLevel,
                counters: sortedCounters,
                methods: methods
            )
        } catch {
            lastPollError = "metrics decode: \(error.localizedDescription)"
            return snapshot
        }
    }

    private func appendEvents(_ new: [DevTelemetryEvent]) {
        events.append(contentsOf: new)
        if events.count > bufferLimit {
            events.removeFirst(events.count - bufferLimit)
        }
    }

    private func encodeFieldsJSON(_ fields: [String: String]) -> String? {
        let sanitized = fields.mapValues { value -> String in
            // Guard against control chars; JSONEncoder handles escaping.
            value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Raw decoding from JSON drained from libsmithers

private struct RawZigEvent: Decodable {
    let seq: UInt64
    let tsMs: Int64
    let level: Int
    let subsystem: String
    let name: String
    let durationMs: Int64?
    let fields: AnyCodable?

    var fieldsString: String? {
        guard let fields else { return nil }
        return fields.compactJSONString
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case tsMs = "ts_ms"
        case level
        case subsystem
        case name
        case durationMs = "duration_ms"
        case fields
    }
}

private struct RawMetricsSnapshot: Decodable {
    let startedAtMs: Int64
    let nowMs: Int64
    let eventsSeq: UInt64
    let eventsDropped: UInt64
    let eventsCapacity: UInt64
    let minLevel: Int
    let counters: [String: UInt64]
    let methods: [String: RawMethod]

    enum CodingKeys: String, CodingKey {
        case startedAtMs = "started_at_ms"
        case nowMs = "now_ms"
        case eventsSeq = "events_seq"
        case eventsDropped = "events_dropped"
        case eventsCapacity = "events_capacity"
        case minLevel = "min_level"
        case counters
        case methods
    }
}

private struct RawMethod: Decodable {
    let count: UInt64
    let errors: UInt64
    let maxMs: Int64
    let lastMs: Int64
    let avgMs: Double
    let buckets: [UInt64]
    let bucketUpperMs: [Int64]

    enum CodingKeys: String, CodingKey {
        case count, errors
        case maxMs = "max_ms"
        case lastMs = "last_ms"
        case avgMs = "avg_ms"
        case buckets
        case bucketUpperMs = "bucket_upper_ms"
    }
}

// Tiny AnyCodable that re-emits as JSON for storage. Cheap and good enough for
// dev-tools display; we don't need typed access to the `fields` blob.
private struct AnyCodable: Decodable {
    let raw: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.raw = nil; return }
        if let v = try? container.decode(Bool.self) { self.raw = v; return }
        if let v = try? container.decode(Int64.self) { self.raw = v; return }
        if let v = try? container.decode(Double.self) { self.raw = v; return }
        if let v = try? container.decode(String.self) { self.raw = v; return }
        if let v = try? container.decode([AnyCodable].self) { self.raw = v.map(\.raw); return }
        if let v = try? container.decode([String: AnyCodable].self) {
            self.raw = v.mapValues { $0.raw as Any }
            return
        }
        self.raw = nil
    }

    var compactJSONString: String? {
        guard let raw, JSONSerialization.isValidJSONObject(raw) || raw is [Any] else {
            // Wrap scalars so JSONSerialization can encode them.
            if let v = raw {
                if let data = try? JSONSerialization.data(withJSONObject: ["v": v], options: [.sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
            }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - LogLevel ↔ obs.zig level mapping

extension LogLevel {
    /// Maps to the integer levels used by smithers.h obs API:
    /// 0=trace, 1=debug, 2=info, 3=warn, 4=error.
    var obsLevel: Int {
        switch self {
        case .debug: return 1
        case .info: return 2
        case .warning: return 3
        case .error: return 4
        }
    }

    init(obsLevel: Int) {
        switch obsLevel {
        case 0, 1: self = .debug
        case 2: self = .info
        case 3: self = .warning
        default: self = .error
        }
    }
}
