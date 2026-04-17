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
            let resolvedMode = forcedMode ?? LiveRunLayoutMode.forWidth(geometry.size.width, breakpoint: modeBreakpoint)

            Group {
                if resolvedMode == .wide {
                    wideLayout(totalWidth: geometry.size.width)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("liveRun.layout.wide")
                } else {
                    narrowLayout
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("liveRun.layout.narrow")
                }
            }
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier(
                        resolvedMode == .wide ? "liveRun.layout.wide" : "liveRun.layout.narrow"
                    )
            }
            .onAppear {
                updateMode(resolvedMode)
            }
            .onChange(of: geometry.size.width) { _, width in
                updateMode(forcedMode ?? .forWidth(width, breakpoint: modeBreakpoint))
            }
            .onChange(of: hasSelection) { _, _ in
                syncInspectorSheetPresentation()
            }
        }
        .accessibilityIdentifier("liveRun.layout.container")
    }

    private var forcedMode: LiveRunLayoutMode? {
        guard UITestSupport.isEnabled else { return nil }
        guard let raw = ProcessInfo.processInfo.environment["SMITHERS_GUI_UITEST_FORCE_LIVERUN_LAYOUT"]?.lowercased() else {
            return nil
        }

        switch raw {
        case "wide":
            return .wide
        case "narrow":
            return .narrow
        default:
            return nil
        }
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
        ZStack(alignment: .center) {
            treePane()

            if inspectorSheetPresented && mode == .narrow && hasSelection {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            inspectorSheetPresented = false
                        }
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("liveRun.layout.inspectorSheet.dimmer")

                inspectorPane()
                    .frame(maxWidth: 480, maxHeight: 600)
                    .background(Theme.surface1)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                    .padding(24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .accessibilityIdentifier("liveRun.layout.inspectorSheet")
            }
        }
        .animation(.easeOut(duration: 0.15), value: inspectorSheetPresented)
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
        defer { syncInspectorSheetPresentation() }
        guard mode != newMode else { return }
        mode = newMode
        onModeChange?(newMode)
    }

    private func syncInspectorSheetPresentation() {
        if mode == .narrow {
            inspectorSheetPresented = hasSelection
        } else {
            inspectorSheetPresented = false
        }
    }
}
