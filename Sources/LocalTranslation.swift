import Foundation

// Only loopback endpoints are allowed: meeting text stays on this Mac.
struct LocalTranslation {
    let address: String
    let apiKey: String
    let model: String

    static func configuredKey() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = root["auth"] as? [String: Any] else { return "" }
        return auth["api_key"] as? String ?? ""
    }

    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "http", let host = components.host,
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(components.path) else {
            throw AppError.message("请填写本机地址，例如 http://127.0.0.1:18000/v1。仅支持本机 oMLX 服务。")
        }
        components.path = "/v1/" + path
        guard let url = components.url else { throw AppError.message("oMLX 地址无效。") }
        return url
    }

    func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(path))
        request.timeoutInterval = 45
        let key = apiKey.isEmpty ? Self.configuredKey() : apiKey
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Do not send a local credential through system proxies or redirects.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AppError.message("oMLX 响应无效。") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.message("oMLX 验证失败，请检查 API Key。") }
        if !(200..<300).contains(http.statusCode) || json["error"] != nil {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "服务请求失败"
            let safe = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[隐藏]")
            throw AppError.message("oMLX（HTTP \(http.statusCode)）：\(safe.prefix(400))")
        }
        return json
    }

    func models() async throws -> [String] {
        let json = try await request("models")
        guard let rows = json["data"] as? [[String: Any]] else { throw AppError.message("oMLX 模型列表格式无效。") }
        return Array(Set(rows.compactMap { $0["id"] as? String })).sorted()
    }

    func translate(_ english: String) async throws -> String {
        guard !model.isEmpty else { throw AppError.message("请先刷新并选择 oMLX 模型。") }
        let json = try await request("chat/completions", body: [
            "model": model,
            "messages": [
                ["role": "system", "content": "Translate this English meeting transcript into natural Simplified Chinese. Preserve numbers, negation and technical meaning. Preserve relative dates precisely: next week means 下周, this week means 本周. Output only the Chinese translation, without explanation or reasoning."],
                ["role": "user", "content": english]
            ],
            "temperature": 0, "max_tokens": 1024, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false]
        ])
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("模型返回空白、不完整或不支持的翻译结果，请重试或选择其他模型。")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
