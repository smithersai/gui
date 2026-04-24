#if os(iOS)
import XCTest
import Combine
@testable import SmithersiOS

@MainActor
final class TerminalSurfaceConnectionStateTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func test_model_tracks_transport_state_and_reconnect_action() async {
        let transport = FakeStateTransport()
        let model = TerminalSurfaceModel()
        let expectedStates: [TerminalSurfaceConnectionState] = [.connecting, .connected, .reconnecting, .disconnected]
        let stateExpectation = expectation(description: "connection states propagate")

        var observedStates: [TerminalSurfaceConnectionState] = []
        model.$connectionState
            .dropFirst()
            .removeDuplicates()
            .sink { state in
                observedStates.append(state)
                if observedStates == expectedStates {
                    stateExpectation.fulfill()
                }
            }
            .store(in: &cancellables)

        model.attach(transport)
        transport.emit(.reconnecting)
        transport.emit(.disconnected)

        await fulfillment(of: [stateExpectation], timeout: 1.0)
        XCTAssertEqual(model.connectionState, .disconnected)

        model.retryConnection()
        XCTAssertEqual(transport.reconnectCount, 1)
        model.detach()
    }
}

@MainActor
private final class FakeStateTransport: TerminalPTYTransport {
    @Published private(set) var connectionState: TerminalSurfaceConnectionState = .connected

    var connectionStatePublisher: AnyPublisher<TerminalSurfaceConnectionState, Never> {
        $connectionState
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private(set) var reconnectCount = 0

    func start(onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        _ = (onBytes, onClosed)
        connectionState = .connected
    }

    func write(_ bytes: Data) {
        _ = bytes
    }

    func resize(cols: UInt16, rows: UInt16) {
        _ = (cols, rows)
    }

    func reconnect() {
        reconnectCount += 1
    }

    func stop() {
        connectionState = .disconnected
    }

    func emit(_ state: TerminalSurfaceConnectionState) {
        connectionState = state
    }
}
#endif
