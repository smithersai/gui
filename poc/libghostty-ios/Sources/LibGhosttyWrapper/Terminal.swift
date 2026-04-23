// Thin Swift wrapper over libghostty-vt's terminal + formatter C API.
//
// This is a *render-only* wrapper: bytes go in (via `write`), cell-buffer
// state comes out (via `plainText` / cursor getters). No network, no PTY,
// no input, no Metal. Pure VT state machine.
//
// The wrapper is deliberately minimal; production iOS code would layer
// Swift Concurrency + observation on top. See
// `.smithers/tickets/0120-client-libsmithers-core-production-runtime.md`
// for the production shape.

import Foundation
import GhosttyVt

public enum GhosttyTerminalError: Error, CustomStringConvertible {
    case initializationFailed(code: Int32)
    case resizeFailed(code: Int32)
    case formatterInitFailed(code: Int32)
    case formatFailed(code: Int32)

    public var description: String {
        switch self {
        case .initializationFailed(let c): return "ghostty_terminal_new failed: \(c)"
        case .resizeFailed(let c):         return "ghostty_terminal_resize failed: \(c)"
        case .formatterInitFailed(let c):  return "ghostty_formatter_terminal_new failed: \(c)"
        case .formatFailed(let c):         return "ghostty_formatter_format_alloc failed: \(c)"
        }
    }
}

public final class GhosttyVT {
    /// Opaque terminal handle owned by the C library.
    private var handle: GhosttyTerminal?

    public init(cols: UInt16, rows: UInt16, maxScrollback: Int = 1000) throws {
        let opts = GhosttyTerminalOptions(
            cols: cols,
            rows: rows,
            max_scrollback: maxScrollback
        )
        var h: GhosttyTerminal? = nil
        let rc = ghostty_terminal_new(nil, &h, opts)
        guard rc == GHOSTTY_SUCCESS, h != nil else {
            throw GhosttyTerminalError.initializationFailed(code: Int32(rc.rawValue))
        }
        self.handle = h
    }

    deinit {
        if let h = handle {
            ghostty_terminal_free(h)
        }
    }

    /// Feed raw VT-encoded bytes to the terminal. Synchronous, never fails.
    public func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(handle, buf.baseAddress, buf.count)
        }
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(handle, p, raw.count)
        }
    }

    public var cursor: (x: UInt16, y: UInt16) {
        var x: UInt16 = 0
        var y: UInt16 = 0
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return (x, y)
    }

    public var size: (cols: UInt16, rows: UInt16) {
        var c: UInt16 = 0
        var r: UInt16 = 0
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &c)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        return (c, r)
    }

    /// Render the active screen to plain text via the ghostty formatter.
    /// Uses the `PLAIN` emit mode with trailing-whitespace trim — this is
    /// what the test harness asserts against.
    public func plainText(trim: Bool = true, unwrap: Bool = false) throws -> String {
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = trim
        opts.unwrap = unwrap
        opts.selection = nil

        var fmt: GhosttyFormatter? = nil
        let rc = ghostty_formatter_terminal_new(nil, &fmt, handle, opts)
        guard rc == GHOSTTY_SUCCESS, fmt != nil else {
            throw GhosttyTerminalError.formatterInitFailed(code: Int32(rc.rawValue))
        }
        defer { ghostty_formatter_free(fmt) }

        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: Int = 0
        let rc2 = ghostty_formatter_format_alloc(fmt, nil, &outPtr, &outLen)
        guard rc2 == GHOSTTY_SUCCESS, let p = outPtr else {
            throw GhosttyTerminalError.formatFailed(code: Int32(rc2.rawValue))
        }
        defer { ghostty_free(nil, p, outLen) }
        let data = Data(bytes: p, count: outLen)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
