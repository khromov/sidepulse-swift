import Foundation
import SidePulseCore

/// Stream Deck's local WebSocket. Callbacks run on `queue`; the plugin quits when Stream Deck closes it.
public final class StreamDeckSocket: NSObject, StreamDeckOutput, URLSessionWebSocketDelegate, @unchecked Sendable {
    public var onEvent: (StreamDeckEvent) -> Void = { _ in }
    public var onClose: () -> Void = {}

    private let url: URL
    private let queue: DispatchQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    public init(port: Int, queue: DispatchQueue = .main) {
        url = URL(string: "ws://127.0.0.1:\(port)")!
        self.queue = queue
    }

    public func connect(register: JSONObject) {
        let configuration = URLSessionConfiguration.ephemeral
        // A system proxy must never see the loopback connection.
        configuration.connectionProxyDictionary = [:]
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        send(register)
        receive()
    }

    public func send(_ message: JSONObject) {
        guard let task, !closed else { return }
        task.send(.string(JSONValue.object(message).serialized())) { [weak self] error in
            if error != nil { self?.queue.async { self?.finish() } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(.string(let text)):
                    if let event = StreamDeckEvent.parse(text) { self.onEvent(event) }
                    self.receive()
                case .success(.data(let data)):
                    if let event = StreamDeckEvent.parse(String(decoding: data, as: UTF8.self)) { self.onEvent(event) }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        onClose()
    }
}
