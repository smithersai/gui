import SwiftUI

final class FrameScrubDebouncer {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var pendingFrameNo: Int?
    private var callback: ((Int) -> Void)?

    init(intervalMs: Int = 50, queue: DispatchQueue = .main) {
        self.interval = max(0.001, Double(intervalMs) / 1000)
        self.queue = queue
    }

    deinit {
        cancel()
    }

    func schedule(frameNo: Int, action: @escaping (Int) -> Void) {
        var shouldStart = false
        lock.lock()
        pendingFrameNo = frameNo
        callback = action
        if timer == nil {
            shouldStart = true
        }
        lock.unlock()

        if shouldStart {
            startTimer()
        }
    }

    func cancel() {
        lock.lock()
        pendingFrameNo = nil
        callback = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.flushTick()
        }

        lock.lock()
        self.timer = timer
        lock.unlock()

        timer.resume()
    }

    private func flushTick() {
        var frameNo: Int?
        var callback: ((Int) -> Void)?

        lock.lock()
        frameNo = pendingFrameNo
        pendingFrameNo = nil
        callback = self.callback
        if frameNo == nil {
            let timer = self.timer
            self.timer = nil
            self.callback = nil
            lock.unlock()
            timer?.cancel()
            return
        }
        lock.unlock()

        if let frameNo, let callback {
            callback(frameNo)
        }
    }
}

struct FrameScrubberView: View {
    @ObservedObject var store: LiveRunDevToolsStore

    var onRequestRewind: ((Int) -> Void)?

    @State private var sliderFrameNo: Double = 0
    @State private var isEditing = false
    @State private var debouncer: FrameScrubDebouncer

    init(
        store: LiveRunDevToolsStore,
        debounceMs: Int = 50,
        debouncer: FrameScrubDebouncer? = nil,
        onRequestRewind: ((Int) -> Void)? = nil
    ) {
        self.store = store
        self.onRequestRewind = onRequestRewind
        _debouncer = State(initialValue: debouncer ?? FrameScrubDebouncer(intervalMs: debounceMs))
    }

    private var sliderRange: ClosedRange<Double> {
        0...Double(max(store.latestFrameNo, 1))
    }

    private var scrubberDisabled: Bool {
        store.latestFrameNo <= 1
    }

    private var historicalFrameNo: Int? {
        store.mode.historicalFrameNo
    }

    private var historicalBannerText: String? {
        guard let frameNo = historicalFrameNo else { return nil }
        return "Viewing frame \(frameNo) of \(store.latestFrameNo) (historical)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("frame \(Int(sliderFrameNo)) / \(store.latestFrameNo)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("scrubber.label")

                Spacer()

                if store.isRewindEligible, let frameNo = historicalFrameNo {
                    Button("Rewind") {
                        requestRewind(frameNo)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Theme.danger.opacity(0.12))
                    .cornerRadius(6)
                    .accessibilityIdentifier("scrubber.rewind")
                }
            }

            sliderControl

            if let text = historicalBannerText {
                HStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warning)

                    Spacer()

                    Button("Return to live") {
                        store.returnToLive()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("scrubber.returnLive")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.warning.opacity(0.10))
                .cornerRadius(6)
                .accessibilityIdentifier("scrubber.historical.banner")
            }

            if let error = store.rewindError ?? store.scrubError {
                errorBanner(error)
            }

            if UITestSupport.isEnabled {
                Button("Scrub historical frame") {
                    let target = max(0, store.latestFrameNo - 1)
                    queueScrub(frameNo: target)
                }
                .buttonStyle(.plain)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityIdentifier("scrubber.test.scrubHistorical")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frame scrubber")
        .accessibilityValue("frame \(Int(sliderFrameNo)) of \(store.latestFrameNo)")
        .accessibilityIdentifier("scrubber.container")
        .onAppear {
            sliderFrameNo = Double(store.displayedFrameNo)
        }
        .onChange(of: store.displayedFrameNo) { _, newValue in
            guard !isEditing else { return }
            sliderFrameNo = Double(newValue)
        }
        .onDisappear {
            debouncer.cancel()
        }
    }

    private var sliderControl: some View {
        VStack(spacing: 5) {
            Slider(
                value: $sliderFrameNo,
                in: sliderRange,
                step: 1,
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing {
                        queueScrub(frameNo: Int(sliderFrameNo))
                    }
                }
            )
            .disabled(scrubberDisabled)
            .tint(Theme.accent)
            .accessibilityIdentifier("scrubber.slider")
            .onChange(of: sliderFrameNo) { _, newValue in
                // XCUI slider adjustments on macOS do not always toggle `onEditingChanged`.
                // Trigger scrubs whenever the value diverges from the rendered frame.
                let frameNo = Int(newValue)
                guard frameNo != store.displayedFrameNo else { return }
                queueScrub(frameNo: frameNo)
            }
            .onKeyPress(.leftArrow) {
                stepSlider(delta: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                stepSlider(delta: 1)
                return .handled
            }
            .onKeyPress(.home) {
                setSlider(frameNo: 0)
                return .handled
            }
            .onKeyPress(.end) {
                setSlider(frameNo: store.latestFrameNo)
                return .handled
            }

            TickMarksView(frames: notableFrames(), latestFrameNo: max(store.latestFrameNo, 1))
                .frame(height: 5)
        }
    }

    private func notableFrames() -> [Int] {
        let latest = store.latestFrameNo
        guard latest > 1 else { return [0, latest] }

        let quarter = latest / 4
        let half = latest / 2
        let threeQuarter = (latest * 3) / 4

        return Array(Set([0, quarter, half, threeQuarter, latest])).sorted()
    }

    private func stepSlider(delta: Int) {
        let next = min(max(0, Int(sliderFrameNo) + delta), store.latestFrameNo)
        setSlider(frameNo: next)
    }

    private func setSlider(frameNo: Int) {
        sliderFrameNo = Double(frameNo)
        queueScrub(frameNo: frameNo)
    }

    private func queueScrub(frameNo: Int) {
        guard !scrubberDisabled else { return }
        debouncer.schedule(frameNo: frameNo) { [store] resolvedFrame in
            Task {
                await store.scrubTo(frameNo: resolvedFrame)
            }
        }
    }

    private func requestRewind(_ frameNo: Int) {
        if let onRequestRewind {
            onRequestRewind(frameNo)
            return
        }
        Task {
            await store.rewind(to: frameNo, confirm: true)
        }
    }

    private func errorBanner(_ error: DevToolsClientError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.displayMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let hint = error.hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            if shouldShowRetry(for: error), let frameNo = historicalFrameNo {
                Button("Retry") {
                    requestRewind(frameNo)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("scrubber.error.retry")
            }

            Button("Dismiss") {
                store.clearHistoricalError()
                store.clearRewindError()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityIdentifier("scrubber.error.dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.12))
        .cornerRadius(6)
        .accessibilityIdentifier("scrubber.error.banner")
    }

    private func shouldShowRetry(for error: DevToolsClientError) -> Bool {
        switch error {
        case .network, .busy, .rateLimited:
            return store.rewindError != nil
        default:
            return false
        }
    }
}

private struct TickMarksView: View {
    let frames: [Int]
    let latestFrameNo: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(frames, id: \.self) { frame in
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1, height: 5)
                        .offset(x: markerX(frame: frame, width: geometry.size.width))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func markerX(frame: Int, width: CGFloat) -> CGFloat {
        guard latestFrameNo > 0 else { return 0 }
        return width * CGFloat(Double(frame) / Double(latestFrameNo))
    }
}
