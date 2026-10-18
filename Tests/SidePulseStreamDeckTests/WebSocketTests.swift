import Network
import Synchronization
import XCTest
import SidePulseCore
@testable import SidePulseStreamDeck

/// A stand-in for Stream Deck's WebSocket server on loopback.
private final class FakeStreamDeck: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-streamdeck")
    private var connection: NWConnection?
    var onMessage: (String) -> Void = { _ in }

    init() throws {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() -> UInt16? {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { return nil }
        return listener.port?.rawValue
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.onMessage(String(decoding: data, as: UTF8.self)) }
            self.receive(on: connection)
        }
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        listener.cancel()
    }
}

final class WebSocketTests: XCTestCase {
    func testRegistersReceivesEventsSendsCommandsAndReportsClose() throws {
        let server = try FakeStreamDeck()
        let messages = Mutex<[String]>([])
        let registered = expectation(description: "registered")
        let commanded = expectation(description: "command arrived")
        server.onMessage = { text in
            let count = messages.withLock { $0.append(text); return $0.count }
            if count == 1 { registered.fulfill() } else if count == 2 { commanded.fulfill() }
        }
        let port = try XCTUnwrap(server.start())

        let socket = StreamDeckSocket(port: Int(port), queue: DispatchQueue(label: "plugin"))
        let received = expectation(description: "event received")
        let closed = expectation(description: "closed")
        socket.onEvent = { event in
            XCTAssertEqual(event.event, "willAppear")
            XCTAssertEqual(event.context, "ctx")
            received.fulfill()
            socket.send(StreamDeckCommand.showAlert(context: "ctx"))
        }
        socket.onClose = { closed.fulfill() }
        socket.connect(register: StreamDeckCommand.register(event: "registerPlugin", uuid: "plugin-uuid"))

        wait(for: [registered], timeout: 5)
        server.send(#"{"event":"willAppear","action":"a","context":"ctx","payload":{"settings":{}}}"#)
        wait(for: [received, commanded], timeout: 5)
        XCTAssertEqual(messages.withLock { $0 }, [#"{"event":"registerPlugin","uuid":"plugin-uuid"}"#,
                                                  #"{"event":"showAlert","context":"ctx"}"#])

        server.disconnect()
        wait(for: [closed], timeout: 5)
    }
}
