import Foundation

public enum NtfyRequest {
    public static func make(server: String, topic: String) throws -> URLRequest {
        guard var url = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !topic.isEmpty, topic.count <= 200, topic.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "WorkPager", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTPSサーバーURLと英数字・ハイフン・下線のtopicを指定してください。"])
        }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + topic
        if !url.path.hasPrefix("/") { url.path = "/" + url.path }
        guard let endpoint = url.url else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Work Pager", forHTTPHeaderField: "Title")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("仕事PCを確認".utf8)
        return request
    }
}
