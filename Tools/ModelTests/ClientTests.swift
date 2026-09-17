import Foundation

enum AppError: LocalizedError { case message(String); var errorDescription: String? { switch self { case .message(let s): return s } } }
@main struct Tests {
    static func main() async throws {
        let base = "http://127.0.0.1:18091/v1"
        for url in ["https://example.com", "http://example.com", "http://127.0.0.1:18000/v1?key=x", "http://user:pass@localhost"] {
            do { _ = try LocalTranslation(address: url, apiKey: "", model: "").endpoint("models"); fatalError("Invalid endpoint accepted") }
            catch { }
        }
        let c = LocalTranslation(address: base, apiKey: "test-secret", model: "good")
        let models = try await c.models()
        precondition(models == ["good"])
        let result = try await c.translate("Testing")
        precondition(result == "测试")
        for mode in ["unauthorized", "http200error", "truncated", "empty", "redirect"] {
            do {
                _ = try await LocalTranslation(address: base, apiKey: "test-secret", model: mode).translate("Testing")
                fatalError("Bad response accepted: \(mode)")
            } catch { precondition(!error.localizedDescription.contains("test-secret")) }
        }
        print("PASS: loopback validation, model parsing, translation, auth rejection, HTTP 200 error, truncated/empty output, redirect rejection, credential redaction")
    }
}
