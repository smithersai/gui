import SwiftUI

enum LiveRunLayoutMode: String, Equatable {
    case wide
    case narrow

    static func forWidth(_ width: CGFloat, breakpoint: CGFloat) -> LiveRunLayoutMode {
        width >= breakpoint ? .wide : .narrow
    }
}

struct LiveRunLayout<TreePane: View, InspectorPane: View>: View {
    let hasSelection: Bool
    @Binding var inspectorSheetPresented: Bool
    var modeBreakpoint: CGFloat = 800
    var minPaneWidth: CGFloat = 320
    var dividerWidth: CGFloat = 6
    var onModeChange: ((LiveRunLayoutMode) -> Void)?

    @ViewBuilder private var treePane: () -> TreePane
    @ViewBuilder private var inspectorPane: () -> InspectorPane

    @AppStorage("liverun.layout.inspectorFraction") private var inspectorFraction: Double = 0.46

    @State private var mode: LiveRunLayoutMode = .wide
    @State private var dragStartFraction: Double?

    init(
        hasSelection: Bool,
        inspectorSheetPresented: Binding<Bool>,
        modeBreakpoint: CGFloat = 800,
        minPaneWidth: CGFloat = 320,
        dividerWidth: CGFloat = 6,
        onModeChange: ((LiveRunLayoutMode) -> Void)? = nil,
        @ViewBuilder treePane: @escaping () -> TreePane,
        @ViewBuilder inspectorPane: @escaping () -> InspectorPane
    ) {
        self.hasSelection = hasSelection
        _inspectorSheetPresented = inspectorSheetPresented
        self.modeBreakpoint = modeBreakpoint
        self.minPaneWidth = minPaneWidth
        self.dividerWidth = dividerWidth
        self.onModeChange = onModeChange
        self.treePane = treePane
        self.inspectorPane = inspectorPane
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedMode = LiveRunLayoutMode.forWidth(geometry.size.width, breakpoint: modeBreakpoint)

            Group {
                if resolvedMode == .wide {
                    wideLayout(totalWidth: geometry.size.width)
                        .accessibilityIdentifier("liveRun.layout.wide")
                } else {
                    narrowLayout
                        .accessibilityIdentifier("liveRun.layout.narrow")
                }
            }
            .onAppear {
                updateMode(resolvedMode)
            }
            .onChange(of: geometry.size.width) { _, width in
                updateMode(.forWidth(width, breakpoint: modeBreakpoint))
            }
            .onChange(of: hasSelection) { _, _ in
                syncInspectorSheetPresentation()
            }
        }
        .accessibilityIdentifier("liveRun.layout.container")
    }

    private func wideLayout(totalWidth: CGFloat) -> some View {
        let widths = paneWidths(totalWidth: totalWidth)

        return HStack(spacing: 0) {
            treePane()
                .frame(width: widths.tree)

            divider(totalWidth: totalWidth)

            inspectorPane()
                .frame(width: widths.inspector)
        }
        .animation(.easeInOut(duration: 0.15), value: mode)
    }

    private var narrowLayout: some View {
        treePane()
            .sheet(
                isPresented: Binding(
                    get: { inspectorSheetPresented && mode == .narrow && hasSelection },
                    set: { inspectorSheetPresented = $0 }
                )
            ) {
                inspectorPane()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .accessibilityIdentifier("liveRun.layout.inspectorSheet")
            }
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: dividerWidth)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                resizeDivider(translationX: value.translation.width, totalWidth: totalWidth)
                            }
                            .onEnded { _ in
                                dragStartFraction = nil
                            }
                    )
            }
            .accessibilityIdentifier("liveRun.layout.divider")
    }

    private func paneWidths(totalWidth: CGFloat) -> (tree: CGFloat, inspector: CGFloat) {
        let safeTotal = max(totalWidth, (minPaneWidth * 2) + dividerWidth)
        let minimumFraction = Double(minPaneWidth / safeTotal)
        let maximumFraction = Double((safeTotal - minPaneWidth - dividerWidth) / safeTotal)
        let clampedFraction = min(max(inspectorFraction, minimumFraction), maximumFraction)
        let inspector = CGFloat(clampedFraction) * safeTotal
        let tree = max(minPaneWidth, safeTotal - inspector - dividerWidth)
        return (tree: tree, inspector: inspector)
    }

    private func resizeDivider(translationX: CGFloat, totalWidth: CGFloat) {
        let safeTotal = max(totalWidth, (minPaneWidth * 2) + dividerWidth)
        let minimumInspector = minPaneWidth
        let maximumInspector = safeTotal - minPaneWidth - dividerWidth

        let startFraction = dragStartFraction ?? inspectorFraction
        if dragStartFraction == nil {
            dragStartFraction = startFraction
        }

        let startInspectorWidth = CGFloat(startFraction) * safeTotal
        let candidateInspectorWidth = startInspectorWidth - translationX
        let clampedInspectorWidth = min(max(candidateInspectorWidth, minimumInspector), maximumInspector)

        inspectorFraction = Double(clampedInspectorWidth / safeTotal)
    }

    private func updateMode(_ newMode: LiveRunLayoutMode) {
        guard mode != newMode else { return }
        mode = newMode
        onModeChange?(newMode)
        syncInspectorSheetPresentation()
    }

    private func syncInspectorSheetPresentation() {
        if mode == .narrow {
            inspectorSheetPresented = hasSelection
        } else {
            inspectorSheetPresented = false
        }
    }
}
