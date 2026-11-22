import Foundation
import LynxCore
import Security

/// The user's own Anthropic API key, in the Keychain (service `xyz.etherlynx.reminders`). Only this device has it:
/// it is never synced or sent anywhere but api.anthropic.com.
enum ClaudeKeyStore {
    private static let account = "claude-api-key"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: LynxPaths.appId, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        delete()
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool { SecItemDelete(base as CFDictionary) == errSecSuccess }
}

enum ClaudeError: LocalizedError {
    case badKey
    case noCredit
    case busy
    case refused
    case unreadable
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badKey: "Anthropic didn't accept this key."
        case .noCredit: "Your Anthropic account is out of credit."
        case .busy: "Claude is busy right now."
        case .refused: "Claude declined to read this."
        case .unreadable: "Claude's answer couldn't be read."
        case .http(let code, let message): message.isEmpty ? "Anthropic answered \(code)." : message
        }
    }
}

/// Calls the Claude API (Messages) with the user's key. Swift has no official Anthropic SDK, so this is plain HTTP.
struct ClaudeClient {
    let apiKey: String
    private static let base = URL(string: "https://api.anthropic.com/v1/")!

    private func request(_ path: String, method: String = "GET", body: Data? = nil, beta: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: Self.base)!.absoluteURL)
        r.httpMethod = method
        r.timeoutInterval = 45
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { r.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = body
        return r
    }

    private func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            switch code {
            case 401, 403: throw ClaudeError.badKey
            case 400 where message.localizedCaseInsensitiveContains("credit balance"): throw ClaudeError.noCredit
            case 429, 529: throw ClaudeError.busy
            default: throw ClaudeError.http(code, message)
            }
        }
        return json
    }

    /// The models this key can use that can read quick add, newest first. Listing models is free, so this also
    /// checks the key.
    func models() async throws -> [QuickAddAI.ModelOption] {
        let json = try await send(request("models?limit=1000"))
        return QuickAddAI.modelOptions(json["data"] as? [[String: Any]] ?? [])
    }

    /// Reads one quick-add line. Structured outputs keep the answer to `QuickAddAI.schema`; low effort keeps it quick.
    /// On models that take them, server-side fallbacks let another model answer if a safety classifier declines.
    func readQuickAdd(_ text: String, model: String, lists: [LynxList], now: Date, timeZone: TimeZone = .current) async throws -> QuickAddResult {
        let fallbacks = QuickAddAI.usesServerFallbacks(model)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": QuickAddAI.systemPrompt,
            "messages": [["role": "user", "content": QuickAddAI.userMessage(text, lists: lists, now: now, timeZone: timeZone)]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": QuickAddAI.schema]],
        ]
        if fallbacks { body["fallbacks"] = "default" }
        let json = try await send(request("messages", method: "POST", body: try JSONSerialization.data(withJSONObject: body),
                                          beta: fallbacks ? "server-side-fallback-2026-07-01" : nil))
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let answer = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard let data = answer.data(using: .utf8),
              let fields = try? JSONDecoder().decode(QuickAddAI.Fields.self, from: data) else { throw ClaudeError.unreadable }
        return QuickAddAI.result(from: fields, original: text, lists: lists, now: now, timeZone: timeZone)
    }
}
