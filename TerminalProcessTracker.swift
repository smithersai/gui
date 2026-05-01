import Darwin
import Foundation

@MainActor
final class TerminalProcessTracker {
    static let shared = TerminalProcessTracker()

    private struct Entry {
        let surfaceId: String
        let workspaceId: String
        let registeredAt: Date
        var shellPid: pid_t?
        var lastReportedName: String?
        let onResolve: (String, String?) -> Void
    }

    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private let tickInterval: TimeInterval = 1.5
    private let ourPid = getpid()

    private init() {}

    func register(
        surfaceId: String,
        workspaceId: String,
        onResolve: @escaping (String, String?) -> Void
    ) {
        entries[surfaceId] = Entry(
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            registeredAt: Date(),
            shellPid: nil,
            lastReportedName: nil,
            onResolve: onResolve
        )
        startTimerIfNeeded()
    }

    func unregister(surfaceId: String) {
        entries.removeValue(forKey: surfaceId)
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let children = listChildPids(ofPpid: ourPid)
        let assigned = Set(entries.values.compactMap { $0.shellPid })
        for (key, entry) in entries where entry.shellPid != nil {
            if !children.contains(entry.shellPid!) {
                var updated = entry
                updated.shellPid = nil
                updated.lastReportedName = nil
                entries[key] = updated
                entry.onResolve(entry.surfaceId, nil)
            }
        }
        let unassignedPids = children.subtracting(assigned)
        if !unassignedPids.isEmpty {
            let waiting = entries.values
                .filter { $0.shellPid == nil }
                .sorted { $0.registeredAt < $1.registeredAt }
            var pidPool = Array(unassignedPids)
            for entry in waiting {
                guard !pidPool.isEmpty else { break }
                let pid = pidPool.removeFirst()
                var updated = entry
                updated.shellPid = pid
                entries[entry.surfaceId] = updated
            }
        }
        for (key, entry) in entries {
            guard let pid = entry.shellPid else { continue }
            let name = foregroundProcessName(shellPid: pid)
            if entry.lastReportedName != name {
                var updated = entry
                updated.lastReportedName = name
                entries[key] = updated
                entry.onResolve(entry.surfaceId, name)
            }
        }
    }

    private func listChildPids(ofPpid parent: pid_t) -> Set<pid_t> {
        var capacity = 256
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteLen = Int32(capacity * MemoryLayout<pid_t>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return proc_listchildpids(parent, base, byteLen)
            }
            if count < 0 { return [] }
            let ret = Int(count) / MemoryLayout<pid_t>.size
            if ret < capacity {
                return Set(buffer.prefix(ret).filter { $0 > 0 })
            }
            capacity *= 2
        }
    }

    private func foregroundProcessName(shellPid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = proc_pidinfo(shellPid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        let fgPgid = pid_t(bitPattern: info.e_tpgid)
        if fgPgid <= 0 || fgPgid == shellPid { return nil }
        if let name = processName(pid: fgPgid) { return name }
        let members = listPgrpPids(pgid: fgPgid)
        for pid in members where pid != shellPid {
            if let name = processName(pid: pid) { return name }
        }
        return nil
    }

    private func listPgrpPids(pgid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteLen = Int32(capacity * MemoryLayout<pid_t>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return proc_listpgrppids(pgid, base, byteLen)
            }
            if count < 0 { return [] }
            let ret = Int(count) / MemoryLayout<pid_t>.size
            if ret < capacity {
                return Array(buffer.prefix(ret).filter { $0 > 0 })
            }
            capacity *= 2
        }
    }

    private func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_name(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        let name = String(cString: buffer)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
