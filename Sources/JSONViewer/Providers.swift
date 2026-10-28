import Foundation
import Observation
import Security

struct ProviderDef: Identifiable {
    let id: String, name: String, host: String, path: String, prefix: String, keyURL: String, models: [String]

    static let all = [
        ProviderDef(id: "openai", name: "OpenAI", host: "https://api.openai.com", path: "/v1", prefix: "sk-",
                    keyURL: "https://platform.openai.com/api-keys",
                    models: ["gpt-6-luna", "gpt-6.1-sol"]),
        ProviderDef(id: "anthropic", name: "Anthropic", host: "https://api.anthropic.com", path: "/v1", prefix: "sk-ant-",
                    keyURL: "https://console.anthropic.com/settings/keys",
                    models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"]),
        ProviderDef(id: "openrouter", name: "OpenRouter", host: "https://openrouter.ai", path: "/api/v1", prefix: "sk-or-",
                    keyURL: "https://openrouter.ai/keys",
                    models: ["anthropic/claude-sonnet-4.5", "openai/gpt-4o", "google/gemini-2.5-pro", "meta-llama/llama-3.3-70b-instruct"]),
    ]
    static func get(_ id: String) -> ProviderDef { all.first { $0.id == id } ?? all[0] }
}

struct ProviderConfig: Codable, Equatable {
    var name: String, host: String, path: String, model: String
    init(_ d: ProviderDef) { name = d.name; host = d.host; path = d.path; model = d.models[0] }
}

enum VerifyState: Equatable { case loading(String), ok(String), err(String) }

enum Appearance: String, CaseIterable { case auto, light, dark }
enum ViewMode: String, CaseIterable { case tree, text }

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var providers: [String: ProviderConfig] { didSet { save() } }
    var askProvider: String { didSet { d.set(askProvider, forKey: "askProvider") } }
    var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    var defaultView: ViewMode { didSet { d.set(defaultView.rawValue, forKey: "defaultView") } }
    var defaultDepth: Int { didSet { d.set(defaultDepth, forKey: "defaultDepth") } }
    static let fontSizes = 11...15
    var fontSize: Int { didSet { d.set(fontSize, forKey: "fontSize") } }
    /// Mirrors the Keychain so the UI can react; written through `setKey`.
    private(set) var keys: [String: String] = [:]
    var verify: [String: VerifyState] = [:]
    var settingsTab = "general"

    private init() {
        let saved = (d.data(forKey: "providers")).flatMap { try? JSONDecoder().decode([String: ProviderConfig].self, from: $0) } ?? [:]
        providers = Dictionary(uniqueKeysWithValues: ProviderDef.all.map { def in
            var cfg = saved[def.id] ?? ProviderConfig(def)
            if !def.models.contains(cfg.model) { cfg.model = def.models[0] } // saved model no longer offered
            return (def.id, cfg)
        })
        askProvider = d.string(forKey: "askProvider") ?? "openai"
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .auto
        defaultView = ViewMode(rawValue: d.string(forKey: "defaultView") ?? "") ?? .tree
        defaultDepth = d.object(forKey: "defaultDepth") as? Int ?? 2
        fontSize = (d.object(forKey: "fontSize") as? Int).map { min(max($0, 11), 15) } ?? 12
        for p in ProviderDef.all { keys[p.id] = Keychain.read(p.id) ?? "" }
    }

    private func save() { d.set(try? JSONEncoder().encode(providers), forKey: "providers") }

    func changeFontSize(by delta: Int) {
        fontSize = min(max(fontSize + delta, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
    }

    func key(_ id: String) -> String { keys[id] ?? "" }
    func hasKey(_ id: String) -> Bool { !key(id).trimmingCharacters(in: .whitespaces).isEmpty }

    func setKey(_ id: String, _ value: String) {
        keys[id] = value
        Keychain.write(id, value)
        verify[id] = nil
    }

    func reset(_ id: String) {
        providers[id] = ProviderConfig(ProviderDef.get(id))
        setKey(id, "")
    }

    // MARK: Network

    func verifyKey(_ id: String) {
        let def = ProviderDef.get(id), cfg = providers[id]!, key = key(id).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { verify[id] = .err("Enter an API key first."); return }
        if !key.hasPrefix(def.prefix) { verify[id] = .err("\(def.name) keys start with “\(def.prefix)”."); return }
        verify[id] = .loading("Contacting \(URL(string: cfg.host)?.host ?? cfg.host)…")
        Task { @MainActor in
            do {
                // OpenRouter's /models is public, so check the key itself there.
                var req = URLRequest(url: try url(cfg, id == "openrouter" ? "/key" : id == "anthropic" ? "/models?limit=1000" : "/models"))
                authorize(&req, id: id, key: key)
                let (data, resp) = try await URLSession.shared.data(for: req)
                try check(resp, data)
                let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
                    .compactMap { $0["id"] as? String } ?? []
                verify[id] = ids.isEmpty || ids.contains { $0 == cfg.model || $0.hasPrefix(cfg.model + "-") } // aliases list as dated IDs
                    ? .ok("Connected — \(cfg.model) is available.")
                    : .ok("Connected — key works, but \(cfg.model) wasn’t listed.")
            } catch {
                verify[id] = .err(error.localizedDescription)
            }
        }
    }

    /// Translates a question to jq. Only a schema summary of the document is sent.
    func askJQ(question: String, schema: String) async throws -> (jq: String, explanation: String) {
        let id = askProvider, cfg = providers[id]!, key = key(id).trimmingCharacters(in: .whitespaces)
        let system = """
        You translate questions about a JSON document into a single jq filter (jq 1.7).
        Reply with ONLY a JSON object: {"jq": "<filter>", "explanation": "<one sentence>"}. No markdown.
        """
        let user = "Document schema (paths, types, sample values):\n\(schema)\n\nQuestion: \(question)"
        var req: URLRequest
        var body: [String: Any]
        if id == "anthropic" {
            req = URLRequest(url: try url(cfg, "/messages"))
            // Thinking tokens count against max_tokens on current models, so leave headroom.
            body = ["model": cfg.model, "max_tokens": 8192, "system": system,
                    "messages": [["role": "user", "content": user]]]
            if !cfg.model.contains("haiku") { body["output_config"] = ["effort": "low"] }
        } else {
            req = URLRequest(url: try url(cfg, "/chat/completions"))
            body = ["model": cfg.model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        authorize(&req, id: id, key: key)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text: String?
        if id == "anthropic" {
            if obj["stop_reason"] as? String == "refusal" { throw APIError("The model declined this request.") }
            if obj["stop_reason"] as? String == "max_tokens" { throw APIError("The model ran out of tokens before answering.") }
            text = (obj["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let reply = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any],
              let jq = reply["jq"] as? String, !jq.isEmpty
        else { throw APIError("The model didn’t return a jq filter.") }
        return (jq, reply["explanation"] as? String ?? "")
    }

    private func url(_ cfg: ProviderConfig, _ endpoint: String) throws -> URL {
        let host = cfg.host.hasSuffix("/") ? String(cfg.host.dropLast()) : cfg.host
        guard let u = URL(string: host + cfg.path + endpoint) else { throw APIError("Invalid host or sub path.") }
        return u
    }

    private func authorize(_ req: inout URLRequest, id: String, key: String) {
        if id == "anthropic" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if id == "openrouter" {
            req.setValue("https://github.com/rohithb/json-viewer", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("JSON Viewer", forHTTPHeaderField: "X-Title")
        }
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? (obj?["error"] as? String)
        throw APIError(msg ?? "HTTP \(http.statusCode)")
    }
}

struct APIError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

enum Keychain {
    static let service = "com.rohithb.jsonviewer"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if value.isEmpty { SecItemDelete(q as CFDictionary); return }
        let data = Data(value.utf8)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        }
    }
}

/// Paths, types, array lengths and a few sample values — what Ask sends instead of the document.
func schemaSummary(_ v: JSON, limit: Int = 150) -> String {
    var lines: [String] = [], seen = Set<String>()
    func walk(_ v: JSON, _ path: String) {
        guard lines.count < limit else { return }
        let p = path.isEmpty ? "." : path
        switch v {
        case .object(let o):
            if seen.insert(p + "{}").inserted { lines.append("\(p): object (\(o.count) keys)") }
            for (k, x) in o { walk(x, path + jqPath([.key(k)])) }
        case .array(let a):
            if seen.insert(p + "[]").inserted { lines.append("\(p): array[\(a.count)]") }
            for x in a.prefix(3) { walk(x, path + "[]") }
        default:
            let type: String = switch v { case .string: "string"; case .number: "number"; case .bool: "boolean"; default: "null" }
            if seen.insert(p).inserted {
                let sample = v.primitiveText
                lines.append("\(p): \(type) e.g. \(sample.count > 40 ? String(sample.prefix(39)) + "…" : sample)")
            }
        }
    }
    walk(v, "")
    return lines.joined(separator: "\n")
}
