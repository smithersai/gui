#if os(iOS) && canImport(GhosttyVt)
import Foundation
import UIKit
import GhosttyVt

enum TerminalIOSGhosttyError: Error {
    case terminalInit(GhosttyResult)
    case renderStateInit(GhosttyResult)
    case rowIteratorInit(GhosttyResult)
    case rowCellsInit(GhosttyResult)
    case terminalResize(GhosttyResult)
    case renderStateUpdate(GhosttyResult)
    case renderStateGet(GhosttyResult)
    case rowGet(GhosttyResult)
    case cellGet(GhosttyResult)
}

struct TerminalIOSCellSnapshot {
    let text: String
    let foregroundColor: UIColor
    let backgroundColor: UIColor
    let bold: Bool
    let italic: Bool
    let faint: Bool
    let underline: Bool
    let strikethrough: Bool
    let invisible: Bool
    let span: Int
    let isSpacer: Bool
}

struct TerminalIOSCursorSnapshot {
    let column: Int
    let row: Int
    let span: Int
    let color: UIColor
}

struct TerminalIOSRenderSnapshot {
    let cols: Int
    let rows: Int
    let defaultForeground: UIColor
    let defaultBackground: UIColor
    let cells: [[TerminalIOSCellSnapshot]]
    let cursor: TerminalIOSCursorSnapshot?
    let plainText: String
}

final class TerminalIOSGhostty {
    private let maxScrollback: Int

    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?

    private var cols: UInt16
    private var rows: UInt16
    private var cellWidthPx: UInt32
    private var cellHeightPx: UInt32

    var titleHandler: ((String) -> Void)?
    var workingDirectoryHandler: ((String) -> Void)?
    var bellHandler: (() -> Void)?

    private var lastTitle: String = ""
    private var lastWorkingDirectory: String = ""

    init(
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        maxScrollback: Int = 4_000
    ) throws {
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.maxScrollback = maxScrollback
        try recreateTerminal()
    }

    deinit {
        if let rowCells {
            ghostty_render_state_row_cells_free(rowCells)
        }
        if let rowIterator {
            ghostty_render_state_row_iterator_free(rowIterator)
        }
        if let renderState {
            ghostty_render_state_free(renderState)
        }
        if let terminal {
            ghostty_terminal_free(terminal)
        }
    }

    func replaceStream(with data: Data) throws {
        try recreateTerminal()
        write(data)
    }

    func write(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        if data.contains(0x07) {
            bellHandler?()
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(terminal, base, raw.count)
        }
        publishMetadata()
    }

    func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) throws {
        guard let terminal else { return }
        guard self.cols != cols ||
                self.rows != rows ||
                self.cellWidthPx != cellWidthPx ||
                self.cellHeightPx != cellHeightPx else { return }

        let result = ghostty_terminal_resize(terminal, cols, rows, cellWidthPx, cellHeightPx)
        guard result == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.terminalResize(result)
        }
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        publishMetadata()
    }

    func scrollViewport(deltaRows: Int) {
        guard let terminal, deltaRows != 0 else { return }
        var viewport = GhosttyTerminalScrollViewport()
        viewport.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        viewport.value.delta = Int(deltaRows)
        ghostty_terminal_scroll_viewport(terminal, viewport)
    }

    func snapshot() throws -> TerminalIOSRenderSnapshot {
        guard let terminal,
              let renderState,
              let rowIterator,
              let rowCells else {
            throw TerminalIOSGhosttyError.renderStateUpdate(GHOSTTY_INVALID_VALUE)
        }

        let updateResult = ghostty_render_state_update(renderState, terminal)
        guard updateResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateUpdate(updateResult)
        }

        var renderColors = GhosttyRenderStateColors()
        renderColors.size = MemoryLayout<GhosttyRenderStateColors>.size
        let colorsResult = ghostty_render_state_colors_get(renderState, &renderColors)
        guard colorsResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(colorsResult)
        }

        var iteratorRef = rowIterator
        let iteratorResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &iteratorRef
        )
        guard iteratorResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(iteratorResult)
        }

        let defaultForeground = Self.uiColor(renderColors.foreground)
        let defaultBackground = Self.uiColor(renderColors.background)

        var cellsByRow: [[TerminalIOSCellSnapshot]] = []
        cellsByRow.reserveCapacity(Int(rows))

        var plainTextRows: [String] = []
        plainTextRows.reserveCapacity(Int(rows))

        var rowIndex = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            var rowCellsRef = rowCells
            let rowResult = ghostty_render_state_row_get(
                rowIterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &rowCellsRef
            )
            guard rowResult == GHOSTTY_SUCCESS else {
                throw TerminalIOSGhosttyError.rowGet(rowResult)
            }

            var rowCellsSnapshot: [TerminalIOSCellSnapshot] = []
            rowCellsSnapshot.reserveCapacity(Int(cols))

            var plainScalars: [Character] = []
            plainScalars.reserveCapacity(Int(cols))

            while ghostty_render_state_row_cells_next(rowCells) {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                let styleResult = ghostty_render_state_row_cells_get(
                    rowCells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                    &style
                )
                guard styleResult == GHOSTTY_SUCCESS else {
                    throw TerminalIOSGhosttyError.cellGet(styleResult)
                }

                var rawCell: GhosttyCell = 0
                let rawResult = ghostty_render_state_row_cells_get(
                    rowCells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                    &rawCell
                )
                guard rawResult == GHOSTTY_SUCCESS else {
                    throw TerminalIOSGhosttyError.cellGet(rawResult)
                }

                var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
                let wideResult = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide)
                guard wideResult == GHOSTTY_SUCCESS else {
                    throw TerminalIOSGhosttyError.cellGet(wideResult)
                }

                var graphemeLength: UInt32 = 0
                let lengthResult = ghostty_render_state_row_cells_get(
                    rowCells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &graphemeLength
                )
                guard lengthResult == GHOSTTY_SUCCESS else {
                    throw TerminalIOSGhosttyError.cellGet(lengthResult)
                }

                let text = try Self.graphemeString(from: rowCells, count: graphemeLength)
                let foregroundColor = try Self.cellColor(
                    rowCells,
                    dataKind: GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    fallback: defaultForeground
                )
                let backgroundColor = try Self.cellColor(
                    rowCells,
                    dataKind: GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    fallback: defaultBackground
                )

                let span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1
                let isSpacer = wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD

                rowCellsSnapshot.append(
                    TerminalIOSCellSnapshot(
                        text: text,
                        foregroundColor: style.inverse ? backgroundColor : foregroundColor,
                        backgroundColor: style.inverse ? foregroundColor : backgroundColor,
                        bold: style.bold,
                        italic: style.italic,
                        faint: style.faint,
                        underline: style.underline != 0,
                        strikethrough: style.strikethrough,
                        invisible: style.invisible,
                        span: span,
                        isSpacer: isSpacer
                    )
                )

                if isSpacer {
                    plainScalars.append(" ")
                } else if let char = text.first {
                    plainScalars.append(char)
                } else {
                    plainScalars.append(" ")
                }
            }

            while rowCellsSnapshot.count < Int(cols) {
                rowCellsSnapshot.append(
                    TerminalIOSCellSnapshot(
                        text: "",
                        foregroundColor: defaultForeground,
                        backgroundColor: defaultBackground,
                        bold: false,
                        italic: false,
                        faint: false,
                        underline: false,
                        strikethrough: false,
                        invisible: false,
                        span: 1,
                        isSpacer: false
                    )
                )
                plainScalars.append(" ")
            }

            cellsByRow.append(rowCellsSnapshot)
            plainTextRows.append(Self.trimmedPlainRow(String(plainScalars)))
            rowIndex += 1
        }

        while rowIndex < Int(rows) {
            cellsByRow.append(
                Array(
                    repeating: TerminalIOSCellSnapshot(
                        text: "",
                        foregroundColor: defaultForeground,
                        backgroundColor: defaultBackground,
                        bold: false,
                        italic: false,
                        faint: false,
                        underline: false,
                        strikethrough: false,
                        invisible: false,
                        span: 1,
                        isSpacer: false
                    ),
                    count: Int(cols)
                )
            )
            plainTextRows.append("")
            rowIndex += 1
        }

        return TerminalIOSRenderSnapshot(
            cols: Int(cols),
            rows: Int(rows),
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            cells: cellsByRow,
            cursor: try cursorSnapshot(defaultColor: defaultForeground),
            plainText: plainTextRows.joined(separator: "\n")
        )
    }

    private func recreateTerminal() throws {
        if let terminal {
            ghostty_terminal_free(terminal)
            self.terminal = nil
        }
        if let renderState {
            ghostty_render_state_free(renderState)
            self.renderState = nil
        }
        if let rowIterator {
            ghostty_render_state_row_iterator_free(rowIterator)
            self.rowIterator = nil
        }
        if let rowCells {
            ghostty_render_state_row_cells_free(rowCells)
            self.rowCells = nil
        }

        var terminalRef: GhosttyTerminal?
        let terminalOptions = GhosttyTerminalOptions(
            cols: cols,
            rows: rows,
            max_scrollback: maxScrollback
        )
        let terminalResult = ghostty_terminal_new(nil, &terminalRef, terminalOptions)
        guard terminalResult == GHOSTTY_SUCCESS, let terminalRef else {
            throw TerminalIOSGhosttyError.terminalInit(terminalResult)
        }
        terminal = terminalRef

        var renderStateRef: GhosttyRenderState?
        let renderStateResult = ghostty_render_state_new(nil, &renderStateRef)
        guard renderStateResult == GHOSTTY_SUCCESS, let renderStateRef else {
            throw TerminalIOSGhosttyError.renderStateInit(renderStateResult)
        }
        renderState = renderStateRef

        var rowIteratorRef: GhosttyRenderStateRowIterator?
        let rowIteratorResult = ghostty_render_state_row_iterator_new(nil, &rowIteratorRef)
        guard rowIteratorResult == GHOSTTY_SUCCESS, let rowIteratorRef else {
            throw TerminalIOSGhosttyError.rowIteratorInit(rowIteratorResult)
        }
        rowIterator = rowIteratorRef

        var rowCellsRef: GhosttyRenderStateRowCells?
        let rowCellsResult = ghostty_render_state_row_cells_new(nil, &rowCellsRef)
        guard rowCellsResult == GHOSTTY_SUCCESS, let rowCellsRef else {
            throw TerminalIOSGhosttyError.rowCellsInit(rowCellsResult)
        }
        rowCells = rowCellsRef

        let resizeResult = ghostty_terminal_resize(terminalRef, cols, rows, cellWidthPx, cellHeightPx)
        guard resizeResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.terminalResize(resizeResult)
        }

        publishMetadata()
    }

    private func publishMetadata() {
        let title = terminalString(for: GHOSTTY_TERMINAL_DATA_TITLE)
        if title != lastTitle {
            lastTitle = title
            titleHandler?(title)
        }

        let workingDirectory = terminalString(for: GHOSTTY_TERMINAL_DATA_PWD)
        if workingDirectory != lastWorkingDirectory {
            lastWorkingDirectory = workingDirectory
            workingDirectoryHandler?(workingDirectory)
        }
    }

    private func cursorSnapshot(defaultColor: UIColor) throws -> TerminalIOSCursorSnapshot? {
        guard let renderState else {
            throw TerminalIOSGhosttyError.renderStateGet(GHOSTTY_INVALID_VALUE)
        }

        var cursorVisible = false
        var cursorHasValue = false
        var cursorX: UInt16 = 0
        var cursorY: UInt16 = 0
        var cursorWideTail = false

        let visibleResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
            &cursorVisible
        )
        guard visibleResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(visibleResult)
        }

        let hasValueResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &cursorHasValue
        )
        guard hasValueResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(hasValueResult)
        }

        guard cursorVisible, cursorHasValue else { return nil }

        let xResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
            &cursorX
        )
        guard xResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(xResult)
        }

        let yResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
            &cursorY
        )
        guard yResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(yResult)
        }

        let tailResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL,
            &cursorWideTail
        )
        guard tailResult == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.renderStateGet(tailResult)
        }

        var cursorColor = GhosttyColorRgb()
        let colorResult = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR,
            &cursorColor
        )

        let color = colorResult == GHOSTTY_SUCCESS ? Self.uiColor(cursorColor) : defaultColor
        let column = max(0, Int(cursorX) - (cursorWideTail ? 1 : 0))
        return TerminalIOSCursorSnapshot(
            column: column,
            row: Int(cursorY),
            span: cursorWideTail ? 2 : 1,
            color: color
        )
    }

    private func terminalString(for dataKind: GhosttyTerminalData) -> String {
        guard let terminal else { return "" }
        var value = GhosttyString(ptr: nil, len: 0)
        let result = ghostty_terminal_get(terminal, dataKind, &value)
        guard result == GHOSTTY_SUCCESS,
              let ptr = value.ptr,
              value.len > 0 else {
            return ""
        }
        let buffer = UnsafeBufferPointer(start: ptr, count: value.len)
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func graphemeString(
        from rowCells: GhosttyRenderStateRowCells,
        count: UInt32
    ) throws -> String {
        guard count > 0 else { return "" }
        var codepoints = Array(repeating: UInt32(0), count: Int(count))
        let result = codepoints.withUnsafeMutableBufferPointer { buffer in
            ghostty_render_state_row_cells_get(
                rowCells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                buffer.baseAddress
            )
        }
        guard result == GHOSTTY_SUCCESS else {
            throw TerminalIOSGhosttyError.cellGet(result)
        }

        var unicodeScalars = String.UnicodeScalarView()
        for codepoint in codepoints {
            if let scalar = UnicodeScalar(codepoint) {
                unicodeScalars.append(scalar)
            }
        }
        return String(unicodeScalars)
    }

    private static func cellColor(
        _ rowCells: GhosttyRenderStateRowCells,
        dataKind: GhosttyRenderStateRowCellsData,
        fallback: UIColor
    ) throws -> UIColor {
        var color = GhosttyColorRgb()
        let result = ghostty_render_state_row_cells_get(rowCells, dataKind, &color)
        switch result {
        case GHOSTTY_SUCCESS:
            return uiColor(color)
        case GHOSTTY_INVALID_VALUE, GHOSTTY_NO_VALUE:
            return fallback
        default:
            throw TerminalIOSGhosttyError.cellGet(result)
        }
    }

    private static func trimmedPlainRow(_ row: String) -> String {
        var trimmed = row
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func uiColor(_ color: GhosttyColorRgb) -> UIColor {
        UIColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
