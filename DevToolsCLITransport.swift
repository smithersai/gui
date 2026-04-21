import Foundation

// MARK: - Input validation

enum DevToolsInputValidator {
    static func validate(runId: String) throws {
        if try !Smithers.DevTools.validateRunId(runId) {
            throw DevToolsClientError.invalidRunId(runId)
        }
    }

    static func validate(nodeId: String) throws {
        if try !Smithers.DevTools.validateNodeId(nodeId) {
            throw DevToolsClientError.invalidNodeId(nodeId)
        }
    }

    static func validate(iteration: Int) throws {
        if try !Smithers.DevTools.validateIteration(iteration) {
            throw DevToolsClientError.invalidIteration(iteration)
        }
    }

    static func validate(frameNo: Int) throws {
        if try !Smithers.DevTools.validateFrameNo(frameNo) {
            throw DevToolsClientError.invalidFrameNo(frameNo)
        }
    }
}

// MARK: - SQL escaping

enum DevToolsSQL {
    /// Escape a string value for SQLite inlining.
    /// Only used after regex validation; double-escapes apostrophes defensively.
    static func quote(_ value: String) -> String {
        (try? Smithers.DevTools.sqlQuote(value)) ?? "''"
    }
}

// MARK: - Frame XML structures

/// Intermediate representation decoded from the `xml_json` column of `_smithers_frames`
/// (keyframes). Mirrors `WorkflowDAGXMLNode` but with child-array ergonomics we need
/// for the delta applier.
struct DevToolsFrameXMLNode: Codable {
    enum Kind: String, Codable {
        case element
        case text
        case cdata
    }

    let kind: String
    let tag: String?
    var props: [String: String]
    var children: [DevToolsFrameXMLNode]
    var text: String?

    enum CodingKeys: String, CodingKey {
        case kind, tag, props, children, text
    }

    init(
        kind: String,
        tag: String? = nil,
        props: [String: String] = [:],
        children: [DevToolsFrameXMLNode] = [],
        text: String? = nil
    ) {
        self.kind = kind
        self.tag = tag
        self.props = props
        self.children = children
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "element"
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        // props may appear with non-string values; stringify everything.
        if let dict = (try? container.decodeIfPresent([String: String].self, forKey: .props)) ?? nil {
            props = dict
        } else if let rawDict = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .props)) ?? nil {
            var converted: [String: String] = [:]
            for (key, value) in rawDict {
                switch value {
                case .string(let s): converted[key] = s
                case .number(let n):
                    if n == n.rounded() && abs(n) < 1e15 {
                        converted[key] = String(Int64(n))
                    } else {
                        converted[key] = String(n)
                    }
                case .bool(let b): converted[key] = b ? "true" : "false"
                case .null: converted[key] = ""
                default:
                    if let data = try? JSONEncoder().encode(value),
                       let text = String(data: data, encoding: .utf8) {
                        converted[key] = text
                    }
                }
            }
            props = converted
        } else {
            props = [:]
        }
        children = try container.decodeIfPresent([DevToolsFrameXMLNode].self, forKey: .children) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

// MARK: - Frame delta

/// Path-based delta as stored in non-keyframe `_smithers_frames.xml_json` rows.
/// Paths are arrays whose elements are either strings (property name) or ints (child index).
struct DevToolsFrameDelta: Codable {
    struct Op: Codable {
        let op: String
        let path: [PathComponent]
        let value: JSONValue?
    }

    enum PathComponent: Codable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                self = .index(intValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .key(stringValue)
            } else {
                throw DecodingError.typeMismatch(
                    PathComponent.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "PathComponent must be String or Int"
                    )
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .key(let key):
                try container.encode(key)
            case .index(let index):
                try container.encode(index)
            }
        }
    }

    let version: Int
    let ops: [Op]
}

// MARK: - Frame applier

/// Applies path-based deltas to a keyframe tree.
enum DevToolsFrameApplier {
    /// Apply a set of deltas in order to the given base tree.
    /// Mutations happen in a copy; the original tree is left unchanged.
    static func apply(
        deltas: [DevToolsFrameDelta],
        toKeyframe keyframe: DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        try Smithers.DevTools.applyFrameDeltas(deltas, toKeyframe: keyframe)
    }
}

// MARK: - Task index

struct DevToolsTaskIndexEntry: Codable {
    let nodeId: String
    let ordinal: Int?
    let iteration: Int?
    let outputTableName: String?
    let kind: String?
    let agent: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case nodeId
        case ordinal
        case iteration
        case outputTableName
        case kind
        case agent
        case label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
        iteration = try c.decodeIfPresent(Int.self, forKey: .iteration)
        outputTableName = try c.decodeIfPresent(String.self, forKey: .outputTableName)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

// MARK: - Node execution state (from _smithers_nodes)

/// Per-node execution state loaded from `_smithers_nodes`. Populated by a lightweight
/// SQL query in the transport layer and threaded into `DevToolsTreeBuilder.build`
/// so the tree rows can render a real state badge instead of "Unknown".
struct DevToolsNodeStateEntry: Codable, Equatable, Sendable {
    let nodeId: String
    let state: String
    let iteration: Int
    let lastAttempt: Int?
}

/// Normalizes a raw `_smithers_nodes.state` value onto a `TaskExecutionState.rawValue`.
/// The DB emits values like `in-progress` / `skipped` / `complete` that need to map
/// onto the enum cases the UI knows about (`running`, `cancelled`, `finished`, …).
/// Unknown / empty values fall back to `pending` so structural nodes never render
/// as "Unknown" when the underlying data just hasn't populated yet — mirrors the
/// existing normalizer pattern used in `normalizeInspectTaskState`.
func normalizeDevToolsNodeState(_ raw: String) -> String {
    (try? Smithers.DevTools.normalizeNodeState(raw)) ?? raw
}

/// Parent-node rollup precedence. Matches the UX contract described in the ticket:
/// `failed > running > blocked > waitingApproval > pending > finished`. Cancelled is
/// treated as "background noise" and does not override a finished sibling.
/// Computes the rolled-up state of a parent node from its already-normalized
/// child states. Returns `nil` when no child carries a state (caller keeps the
/// parent's existing value).
func devToolsRolledUpState(childStates: [String]) -> String? {
    try? Smithers.DevTools.rolledUpState(childStates: childStates)
}

// MARK: - XML → DevToolsNode conversion

enum DevToolsTreeBuilder {
    /// Convert a decoded frame tree + task index into a `DevToolsNode` tree suitable for the gui.
    /// Integer ids are assigned depth-first so they're stable within a single snapshot.
    ///
    /// - Parameter nodeStates: optional dictionary keyed by `task.nodeId`. When provided,
    ///   task nodes get their `props["state"]` populated (normalized) and structural nodes
    ///   roll up their descendants' states. Pass `[:]` or omit for the legacy behaviour.
    ///
    /// NOTE (live mode): the state map reflects the *final* known state from
    /// `_smithers_nodes`. For historical mode, callers should reconstruct a
    /// per-frame map via `devToolsNodeStatesAtTimestamp(attempts:frameTimestampMs:)`
    /// and pass it here — the builder treats both paths identically. (This lifts the
    /// v1 simplification that used to stamp final state onto historical frames.)
    static func build(
        xml: DevToolsFrameXMLNode,
        taskIndex: [DevToolsTaskIndexEntry],
        nodeStates: [String: DevToolsNodeStateEntry] = [:]
    ) -> DevToolsNode {
        do {
            return try Smithers.DevTools.buildTree(xml: xml, taskIndex: taskIndex, nodeStates: nodeStates)
        } catch {
            return DevToolsNode(id: 0, type: .unknown, name: "node")
        }
    }
}

// MARK: - Node state query

/// SQL helper shared by the live transport and the snapshot loader. Returns the
/// latest (highest iteration) row per `node_id` so a re-run replaces stale state.
enum DevToolsNodeStateQuery {
    /// SQL query text for `_smithers_nodes` loading. Exposed so the caller can pass
    /// it to the existing sqlite3 subprocess runner in `SmithersClient`.
    static func query(runId: String) -> String {
        (try? Smithers.DevTools.nodeStateQuery(runId: runId)) ?? ""
    }

    /// Converts the raw row dicts produced by `execSQLite` into a node-id → entry
    /// dictionary, choosing the highest-iteration row per node_id.
    static func makeDict(fromRows rows: [[String: Any]]) -> [String: DevToolsNodeStateEntry] {
        (try? Smithers.DevTools.nodeStateDict(fromRows: rows)) ?? [:]
    }
}

// MARK: - Per-frame attempt state (historical scrubbing)

/// A single row from `_smithers_attempts` with enough data to decide what state a
/// node was in at a given wall-clock timestamp.
///
/// DB schema (confirmed against `/Users/williamcory/gui/smithers.db`):
///   `_smithers_attempts(run_id, node_id, iteration, attempt, state, started_at_ms,
///    finished_at_ms, heartbeat_at_ms, heartbeat_data_json, error_json, ...)`.
///
/// `finished_at_ms` is nullable; a null value means the attempt was still in flight
/// (or crashed without writing the end timestamp). `state` is the terminal state
/// once `finished_at_ms` is set — values seen in the wild include `finished`,
/// `failed`, `cancelled`, `skipped`.
struct DevToolsAttemptEntry: Codable, Equatable, Sendable {
    let nodeId: String
    let iteration: Int
    let attempt: Int
    /// Terminal / persisted state from the attempt row.
    let state: String
    let startedAtMs: Int64
    let finishedAtMs: Int64?
}

/// SQL + row-decoding helpers for the attempts table, used when the scrubber is
/// rewound to a historical frame and we need to reconstruct per-node state *at
/// that frame's timestamp* rather than the current terminal state.
enum DevToolsAttemptQuery {
    /// Returns all attempts for the run, sorted by start time ascending. Callers
    /// can filter down to a point-in-time view by comparing timestamps in Swift;
    /// doing the filter client-side keeps the SQL simple and means a single query
    /// serves every historical frame without re-hitting sqlite.
    static func query(runId: String) -> String {
        (try? Smithers.DevTools.attemptQuery(runId: runId)) ?? ""
    }

    /// Parses raw sqlite3 -json rows into `DevToolsAttemptEntry` values. Rows missing
    /// a node_id or start time are skipped rather than blowing up the query.
    static func makeEntries(fromRows rows: [[String: Any]]) -> [DevToolsAttemptEntry] {
        (try? Smithers.DevTools.attemptEntries(fromRows: rows)) ?? []
    }
}

/// Derives a per-node state map from attempt rows, evaluated *at a specific
/// timestamp*. This is the core of the historical-scrubber UX fix.
///
/// Contract:
/// - Nodes whose earliest attempt started *after* `frameTimestampMs` are absent
///   from the result (the caller treats "absent" as `pending`).
/// - Nodes with at least one in-flight attempt at the timestamp → `running`.
/// - Otherwise use the latest finished attempt's state (`finished` / `failed` /
///   `cancelled` / `skipped`).
///
/// When multiple attempts exist for the same (node_id, iteration), the *latest*
/// attempt whose start is ≤ the target timestamp wins, matching the behaviour of
/// `_smithers_nodes` which always reflects the most recent attempt.
func devToolsNodeStatesAtTimestamp(
    attempts: [DevToolsAttemptEntry],
    frameTimestampMs: Int64
) -> [String: DevToolsNodeStateEntry] {
    (try? Smithers.DevTools.nodeStatesAtTimestamp(
        attempts: attempts,
        frameTimestampMs: frameTimestampMs
    )) ?? [:]
}
