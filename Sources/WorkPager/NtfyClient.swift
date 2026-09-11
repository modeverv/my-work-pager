import Foundation
import WorkPagerCore

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class NtfyClient {
    private let delegate = NoRedirect()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    func send(server: String, topic: String) async -> String {
        do {
            let request = try NtfyRequest.make(server: server, topic: topic)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "失敗: 応答形式エラー" }
            return (200..<300).contains(http.statusCode) ? "成功 (HTTP \(http.statusCode))" : "失敗: HTTP \(http.statusCode)"
        } catch {
            // URLSession errors can include the secret endpoint; never display their full description.
            if let e = error as? URLError { return "失敗: ネットワークエラー (\(e.code.rawValue))" }
            return "失敗: サーバーURLまたはtopicを確認してください"
        }
    }
}
