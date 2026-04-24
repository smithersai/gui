#if os(iOS) && canImport(GhosttyVt)
import SwiftUI
import UIKit

fileprivate struct TerminalIOSGridSignature: Equatable {
    let cols: UInt16
    let rows: UInt16
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
}

fileprivate struct TerminalIOSGridMetrics {
    static let fontSize: CGFloat = 14
    static let baseFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    let contentInsets: UIEdgeInsets
    let contentRect: CGRect
    let font: UIFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let cols: Int
    let rows: Int

    init(bounds: CGRect, bottomInset: CGFloat) {
        font = Self.baseFont
        cellWidth = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
        cellHeight = ceil(font.lineHeight)
        contentInsets = UIEdgeInsets(top: 8, left: 8, bottom: bottomInset + 8, right: 8)
        contentRect = bounds.inset(by: contentInsets)

        if contentRect.width <= 0 || contentRect.height <= 0 {
            cols = 0
            rows = 0
        } else {
            cols = max(Int(floor(contentRect.width / cellWidth)), 1)
            rows = max(Int(floor(contentRect.height / cellHeight)), 1)
        }
    }

    var signature: TerminalIOSGridSignature {
        TerminalIOSGridSignature(
            cols: UInt16(clamping: cols),
            rows: UInt16(clamping: rows),
            cellWidthPx: UInt32(max(1, Int(ceil(cellWidth)))),
            cellHeightPx: UInt32(max(1, Int(ceil(cellHeight))))
        )
    }

    func rectForCell(column: Int, row: Int, span: Int = 1) -> CGRect {
        CGRect(
            x: contentRect.minX + CGFloat(column) * cellWidth,
            y: contentRect.minY + CGFloat(row) * cellHeight,
            width: CGFloat(max(1, span)) * cellWidth,
            height: cellHeight
        )
    }
}

fileprivate struct TerminalIOSFontKey: Hashable {
    let bold: Bool
    let italic: Bool
}

fileprivate final class TerminalIOSGhosttyHostView: UIView, UIKeyInput {
    var bottomInset: CGFloat = 56 {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    var inputHandler: ((Data) -> Void)?
    var scrollHandler: ((Int) -> Void)?

    var snapshot: TerminalIOSRenderSnapshot? {
        didSet {
            accessibilityMirror.text = snapshot?.plainText ?? ""
            accessibilityMirror.accessibilityValue = snapshot?.plainText ?? ""
            setNeedsDisplay()
        }
    }

    private let accessibilityMirror = UITextView()
    private var panRowOffset: Int = 0
    private var fontCache: [TerminalIOSFontKey: UIFont] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true

        accessibilityMirror.backgroundColor = .clear
        accessibilityMirror.textColor = .clear
        accessibilityMirror.tintColor = .clear
        accessibilityMirror.isEditable = false
        accessibilityMirror.isSelectable = false
        accessibilityMirror.isScrollEnabled = false
        accessibilityMirror.isUserInteractionEnabled = false
        accessibilityMirror.font = TerminalIOSGridMetrics.baseFont
        accessibilityMirror.accessibilityIdentifier = "terminal.ios.text"
        addSubview(accessibilityMirror)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        accessibilityMirror.frame = bounds
    }

    var hasText: Bool { false }

    func insertText(_ text: String) {
        inputHandler?(Data(text.utf8))
    }

    func deleteBackward() {
        inputHandler?(Data([0x7F]))
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
        ]
    }

    fileprivate var gridMetrics: TerminalIOSGridMetrics {
        TerminalIOSGridMetrics(bounds: bounds, bottomInset: bottomInset)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let metrics = gridMetrics
        let snapshot = snapshot
        let defaultBackground = snapshot?.defaultBackground ?? .black

        context.setFillColor(defaultBackground.cgColor)
        context.fill(bounds)

        guard let snapshot else { return }

        let visibleRows = min(snapshot.rows, metrics.rows, snapshot.cells.count)
        let visibleCols = min(snapshot.cols, metrics.cols)
        let cursorRect = cursorRect(in: snapshot, metrics: metrics)

        for row in 0..<visibleRows {
            for col in 0..<visibleCols {
                let cell = snapshot.cells[row][col]
                let cellRect = metrics.rectForCell(column: col, row: row, span: cell.span)
                context.setFillColor(cell.backgroundColor.cgColor)
                context.fill(cellRect)
            }
        }

        if let cursorRect, let cursor = snapshot.cursor {
            context.setFillColor(cursor.color.cgColor)
            context.fill(cursorRect)
        }

        for row in 0..<visibleRows {
            for col in 0..<visibleCols {
                let cell = snapshot.cells[row][col]
                guard !cell.isSpacer, !cell.invisible, !cell.text.isEmpty else { continue }

                let cellRect = metrics.rectForCell(column: col, row: row, span: cell.span)
                var foregroundColor = cell.foregroundColor
                if let cursorRect, cursorRect.intersects(cellRect) {
                    foregroundColor = snapshot.defaultBackground
                }
                if cell.faint {
                    foregroundColor = foregroundColor.withAlphaComponent(0.65)
                }

                let font = resolvedFont(for: cell, baseFont: metrics.font)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: foregroundColor,
                ]
                if cell.underline {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if cell.strikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }

                let attributed = NSAttributedString(string: cell.text, attributes: attributes)
                let textBounds = attributed.boundingRect(
                    with: CGSize(width: cellRect.width, height: cellRect.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                let origin = CGPoint(
                    x: cellRect.minX,
                    y: cellRect.minY + floor((cellRect.height - textBounds.height) / 2)
                )
                attributed.draw(at: origin)
            }
        }
    }

    private func cursorRect(
        in snapshot: TerminalIOSRenderSnapshot,
        metrics: TerminalIOSGridMetrics
    ) -> CGRect? {
        guard let cursor = snapshot.cursor,
              cursor.row >= 0,
              cursor.row < metrics.rows,
              cursor.column >= 0,
              cursor.column < metrics.cols else {
            return nil
        }
        return metrics.rectForCell(column: cursor.column, row: cursor.row, span: cursor.span)
    }

    private func resolvedFont(for cell: TerminalIOSCellSnapshot, baseFont: UIFont) -> UIFont {
        let key = TerminalIOSFontKey(bold: cell.bold, italic: cell.italic)
        if let cached = fontCache[key] {
            return cached
        }

        var font = UIFont.monospacedSystemFont(
            ofSize: baseFont.pointSize,
            weight: cell.bold ? .bold : .regular
        )
        if cell.italic,
           let descriptor = font.fontDescriptor.withSymbolicTraits([.traitItalic]) {
            font = UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        fontCache[key] = font
        return font
    }

    @objc private func handleTap() {
        _ = becomeFirstResponder()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let metrics = gridMetrics
        guard metrics.cellHeight > 0 else { return }

        switch gesture.state {
        case .began:
            panRowOffset = 0
        case .changed:
            let translationY = gesture.translation(in: self).y
            let rowOffset = Int(translationY / metrics.cellHeight)
            let delta = rowOffset - panRowOffset
            if delta != 0 {
                scrollHandler?(-delta)
                panRowOffset = rowOffset
            }
        default:
            panRowOffset = 0
        }
    }

    @objc private func handleArrowKey(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        let bytes: [UInt8]
        switch input {
        case UIKeyCommand.inputUpArrow:
            bytes = [0x1B, 0x5B, 0x41]
        case UIKeyCommand.inputDownArrow:
            bytes = [0x1B, 0x5B, 0x42]
        case UIKeyCommand.inputRightArrow:
            bytes = [0x1B, 0x5B, 0x43]
        case UIKeyCommand.inputLeftArrow:
            bytes = [0x1B, 0x5B, 0x44]
        default:
            return
        }
        inputHandler?(Data(bytes))
    }

    @objc private func handleTab() {
        inputHandler?(Data([0x09]))
    }

    @objc private func handleEscape() {
        inputHandler?(Data([0x1B]))
    }
}

@MainActor
private struct TerminalIOSGhosttyView: UIViewRepresentable {
    @ObservedObject var model: TerminalSurfaceModel
    var availableSize: CGSize
    var bottomInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> TerminalIOSGhosttyHostView {
        let view = TerminalIOSGhosttyHostView()
        view.bottomInset = bottomInset
        view.inputHandler = { [weak model = context.coordinator.model] data in
            model?.sendInput(data)
        }
        view.scrollHandler = { [weak coordinator = context.coordinator, weak view] deltaRows in
            guard let view else { return }
            coordinator?.scroll(deltaRows: deltaRows, in: view)
        }
        return view
    }

    func updateUIView(_ uiView: TerminalIOSGhosttyHostView, context: Context) {
        context.coordinator.model = model
        _ = availableSize
        uiView.bottomInset = bottomInset
        uiView.inputHandler = { [weak model] data in
            model?.sendInput(data)
        }
        uiView.scrollHandler = { [weak coordinator = context.coordinator, weak uiView] deltaRows in
            guard let uiView else { return }
            coordinator?.scroll(deltaRows: deltaRows, in: uiView)
        }
        context.coordinator.render(into: uiView)
    }

    @MainActor
    final class Coordinator {
        weak var model: TerminalSurfaceModel?

        private var ghostty: TerminalIOSGhostty?
        private var lastGridSignature: TerminalIOSGridSignature?
        private var lastBuffer: Data = Data()

        init(model: TerminalSurfaceModel) {
            self.model = model
        }

        func render(into hostView: TerminalIOSGhosttyHostView) {
            guard let model else { return }
            let signature = hostView.gridMetrics.signature
            guard signature.cols > 0, signature.rows > 0 else {
                hostView.snapshot = nil
                return
            }

            do {
                try ensureGhostty(for: signature)
                try feed(model.recentBytes)
                hostView.snapshot = try ghostty?.snapshot()
            } catch {
                hostView.snapshot = nil
            }
        }

        func scroll(deltaRows: Int, in hostView: TerminalIOSGhosttyHostView) {
            guard let ghostty, deltaRows != 0 else { return }
            ghostty.scrollViewport(deltaRows: deltaRows)
            hostView.snapshot = try? ghostty.snapshot()
        }

        private func ensureGhostty(for signature: TerminalIOSGridSignature) throws {
            if ghostty == nil {
                try createGhostty(for: signature)
                model?.resize(cols: signature.cols, rows: signature.rows)
                return
            }

            guard signature != lastGridSignature else { return }
            try ghostty?.resize(
                cols: signature.cols,
                rows: signature.rows,
                cellWidthPx: signature.cellWidthPx,
                cellHeightPx: signature.cellHeightPx
            )
            lastGridSignature = signature
            model?.resize(cols: signature.cols, rows: signature.rows)
        }

        private func createGhostty(for signature: TerminalIOSGridSignature) throws {
            let ghostty = try TerminalIOSGhostty(
                cols: signature.cols,
                rows: signature.rows,
                cellWidthPx: signature.cellWidthPx,
                cellHeightPx: signature.cellHeightPx
            )
            ghostty.titleHandler = { [weak self] title in
                self?.model?.setTitle(title)
            }
            ghostty.workingDirectoryHandler = { [weak self] path in
                self?.model?.setWorkingDirectory(path)
            }
            ghostty.bellHandler = { [weak self] in
                self?.model?.ringBell()
            }
            self.ghostty = ghostty
            self.lastGridSignature = signature
            self.lastBuffer = Data()
        }

        private func feed(_ buffer: Data) throws {
            guard let ghostty else { return }
            guard buffer != lastBuffer else { return }

            if !lastBuffer.isEmpty, buffer.starts(with: lastBuffer) {
                let suffix = buffer.dropFirst(lastBuffer.count)
                ghostty.write(Data(suffix))
            } else {
                try ghostty.replaceStream(with: buffer)
            }
            lastBuffer = buffer
        }
    }
}
#endif
