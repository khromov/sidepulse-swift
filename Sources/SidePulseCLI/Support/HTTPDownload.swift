import Foundation
import SidePulseCore

/// Synchronous GET that cancels as soon as the body passes `limit` instead of buffering whatever
/// the server sends.
final class HTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct StatusError: Error, LocalizedError {
        var status: Int
        var errorDescription: String? { "HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))" }
    }

    private let limit: Int
    private let lock = NSLock()
    private var received = Data()
    private var failure: Error?
    private let finished = DispatchSemaphore(value: 0)

    private init(limit: Int) { self.limit = limit }

    static func fetch(_ url: URL, limit: Int) throws -> Data {
        let download = HTTPDownload(limit: limit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("sidepulse-cli/\(SidePulseConstants.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: request).resume()
        download.finished.wait()
        return try download.lock.withLock {
            if let failure = download.failure { throw failure }
            return download.received
        }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(StatusError(status: http.statusCode))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            received.append(data)
            return received.count > limit
        }
        if tooLarge {
            fail(FirmwareError("Firmware download exceeds the size limit."))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { fail(error) }
        finished.signal()
    }
}
