// SwiftUI mini-app for the Zig↔Swift FFI PoC.
//
// Shows a counter driven by the Zig session's background thread. Tapping
// "Tick" calls `ffi_tick`, which increments the counter in Zig; the Zig
// loop thread then invokes our callback. The callback dispatches to main,
// where @Observable publishes the new value and SwiftUI re-renders.

import SwiftUI
import FFIPoC

@Observable
final class CounterViewModel: @unchecked Sendable {
    var value: UInt64 = 0
    var updates: Int = 0

    // Raw FFI pointer (thread-safe: only we hold it; Zig internally locks).
    nonisolated(unsafe) private var session: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var sub: UInt64 = 0
    nonisolated(unsafe) private var box: Unmanaged<CounterBox>?

    init() {
        session = ffi_new_session()
        guard let s = session else { return }
        let b = CounterBox(owner: self)
        let retained = Unmanaged.passRetained(b)
        self.box = retained
        sub = ffi_subscribe(s, counterTrampoline, UnsafeMutableRawPointer(retained.toOpaque()))
    }

    deinit {
        if let s = session {
            ffi_close_session(s)
        }
        box?.release()
    }

    @MainActor
    func tick() {
        guard let s = session else { return }
        _ = ffi_tick(s)
    }

    // Called on MAIN by the trampoline after it bounces off Zig's thread.
    @MainActor
    func receive(_ v: UInt64) {
        value = v
        updates &+= 1
    }
}

final class CounterBox {
    weak var owner: CounterViewModel?
    init(owner: CounterViewModel) { self.owner = owner }
}

// Zig callback trampoline. Runs on the Zig loop thread. Marshals to main.
//
// We use `DispatchQueue.main.async` rather than `@MainActor` so the Zig
// contract (callback returns promptly, doesn't block the loop) is preserved.
@_cdecl("counterTrampoline")
func counterTrampoline(counter: UInt64, userData: UnsafeMutableRawPointer?) {
    guard let ud = userData else { return }
    let box = Unmanaged<CounterBox>.fromOpaque(ud).takeUnretainedValue()
    DispatchQueue.main.async { [weak owner = box.owner] in
        owner?.receive(counter)
    }
}

struct ContentView: View {
    @State private var vm = CounterViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Counter: \(vm.value)")
                .font(.largeTitle)
            Text("Updates received: \(vm.updates)")
                .font(.subheadline)
            Button("Tick") { vm.tick() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

@main
struct IOSHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
