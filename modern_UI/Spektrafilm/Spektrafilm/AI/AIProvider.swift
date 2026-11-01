//  AIProvider.swift — one request to a vision model, and the JSON it answers
//  with (AI assistant, ARCHITECTURE §7.14).
//
//  Two providers, one shape: a system prompt, a user turn of text and JPEGs,
//  and an object back that matches a schema. The Anthropic Messages API is
//  spoken natively (structured output through `output_config.format`, the
//  server-side refusal fallback on the models that take it); anything that
//  speaks OpenAI's `/chat/completions` — OpenAI itself, OpenRouter, a local
//  Ollama — is the other, asked for a JSON object and checked here.
//
//  Nothing in this file logs a request or a key. The key comes from the
//  Keychain (`AIKeychain`) for the length of one request.

import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openAICompatible
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAICompatible: L("OpenAI-compatible", zh: "OpenAI 兼容")
        }
    }
}

/// What a model is asked: a system prompt, a user turn, the schema of the
/// object it must answer with.
struct AIRequest: Sendable {
    enum Part: Sendable {
        case text(String)
        case jpeg(Data)
    }
    var system: String
    var parts: [Part]
    /// A JSON Schema with `additionalProperties: false` on every object and no
    /// numeric or length constraints — the subset structured output takes.
    var schema: JSONValue
    var maxTokens = 16000
}

/// Raised off the main actor, so each case carries what it needs and the
/// words are chosen where they are shown (`localized`).
enum AIError: Error, CustomStringConvertible, Equatable {
    case notConfigured(en: String, zh: String)
    case http(Int, String)
    case refused(String)
    case truncated
    case badReply(String)

    var description: String {
        switch self {
        case .notConfigured(let en, _): en
        case .http(let status, let message): "The provider answered \(status): \(message)"
        case .refused(let why): "The model declined: \(why)"
        case .truncated: "The model's answer was cut off."
        case .badReply(let why): "The model's answer could not be read: \(why)"
        }
    }

    @MainActor var localized: String {
        switch self {
        case .notConfigured(let en, let zh): L(en, zh: zh)
        case .http(let status, let message):
            status == 401 || status == 403
                ? L("The provider refused the API key (\(status)). Check it in Settings ▸ AI.",
                    zh: "服务商拒绝了 API Key（\(status)），请到 设置 ▸ AI 检查。")
                : L("The provider answered \(status): \(message)", zh: "服务商返回 \(status)：\(message)")
        case .refused(let why): L("The model declined: \(why)", zh: "模型拒绝了这次请求：\(why)")
        case .truncated: L("The model's answer was cut off.", zh: "模型的回答被截断了。")
        case .badReply(let why): L("The model's answer could not be read: \(why)", zh: "无法读取模型的回答：\(why)")
        }
    }
}

struct AIHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

protocol AITransport: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse
}

/// The shipping transport: ephemeral, no cache, no cookies. Three minutes,
/// because a model thinking over a contact sheet is not a five-second read.
struct URLSessionAITransport: AITransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 240
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return AIHTTPResponse(status: http.statusCode, body: data)
    }
}

/// A configured provider: who, which model, where, with which key.
struct AIClient: Sendable {
    var kind: AIProviderKind
    var model: String
    /// The OpenAI-compatible base, e.g. `https://api.openai.com/v1`. Ignored
    /// for Anthropic.
    var baseURL: String
    var apiKey: String
    var transport: AITransport = URLSessionAITransport()

    static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The Claude models that take `fallbacks: "default"` on the Claude API
    /// (claude-api skill, 2026-10): a policy decline is re-run on a fallback
    /// model inside the same call instead of coming back empty.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// The object the model answered with.
    func complete(_ r: AIRequest) async throws -> JSONValue {
        guard !apiKey.isEmpty || kind == .openAICompatible else {
            throw AIError.notConfigured(en: "No API key. Add one in Settings ▸ AI.", zh: "还没有 API Key，请到 设置 ▸ AI 填写。")
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIError.notConfigured(en: "No model is set. Choose one in Settings ▸ AI.", zh: "还没有设置模型，请到 设置 ▸ AI 选择。")
        }
        switch kind {
        case .anthropic: return try await anthropic(r)
        case .openAICompatible: return try await openAI(r)
        }
    }

    // MARK: Anthropic Messages API

    func anthropicBody(_ r: AIRequest) -> JSONValue {
        let content: [JSONValue] = r.parts.map {
            switch $0 {
            case .text(let t): ["type": "text", "text": .string(t)]
            case .jpeg(let d):
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                             "data": .string(d.base64EncodedString())]]
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(r.maxTokens)),
            "system": .string(r.system),
            "messages": [["role": "user", "content": .array(content)]],
            "output_config": ["format": ["type": "json_schema", "schema": r.schema]],
        ]
        if Self.fallbackModels.contains(model) { body["fallbacks"] = "default" }
        return .object(body)
    }

    func anthropicHeaders() -> [String: String] {
        var h = ["content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if Self.fallbackModels.contains(model) { h["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        return h
    }

    private func anthropic(_ r: AIRequest) async throws -> JSONValue {
        let body = Data(anthropicBody(r).text().utf8)
        let reply = try await transport.post(Self.anthropicEndpoint, headers: anthropicHeaders(), body: body)
        return try Self.readAnthropic(reply)
    }

    static func readAnthropic(_ reply: AIHTTPResponse) throws -> JSONValue {
        let json = try? JSONValue.parse(String(decoding: reply.body, as: UTF8.self))
        guard reply.status == 200 else {
            throw AIError.http(reply.status, json?["error"]?["message"]?.string ?? String(decoding: reply.body.prefix(300), as: UTF8.self))
        }
        guard let json else { throw AIError.badReply("not JSON") }
        switch json["stop_reason"]?.string {
        case "refusal":
            throw AIError.refused(json["stop_details"]?["explanation"]?.string
                                  ?? json["stop_details"]?["category"]?.string ?? "refusal")
        case "max_tokens": throw AIError.truncated
        default: break
        }
        // Thinking and fallback blocks are not the answer; the text is.
        guard case .array(let blocks)? = json["content"] else { throw AIError.badReply("no content") }
        let text = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
        return try extractObject(text)
    }

    // MARK: OpenAI-compatible

    func openAIEndpoint() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw AIError.notConfigured(en: "The base URL is not a web address.", zh: "Base URL 不是有效的网址。")
        }
        return url
    }

    func openAIBody(_ r: AIRequest) -> JSONValue {
        var content: [JSONValue] = r.parts.map {
            switch $0 {
            case .text(let t): ["type": "text", "text": .string(t)]
            case .jpeg(let d):
                ["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64," + d.base64EncodedString())]]
            }
        }
        // `json_object` is the mode every compatible server takes; the schema
        // itself travels in the prompt and is checked on the way back.
        content.append(["type": "text", "text": .string("Answer with one JSON object matching this schema, and nothing else:\n" + r.schema.text())])
        return [
            "model": .string(model),
            "messages": [["role": "system", "content": .string(r.system)],
                         ["role": "user", "content": .array(content)]],
            "response_format": ["type": "json_object"],
        ]
    }

    private func openAI(_ r: AIRequest) async throws -> JSONValue {
        var headers = ["content-type": "application/json"]
        if !apiKey.isEmpty { headers["authorization"] = "Bearer \(apiKey)" }
        let reply = try await transport.post(try openAIEndpoint(), headers: headers,
                                             body: Data(openAIBody(r).text().utf8))
        return try Self.readOpenAI(reply)
    }

    static func readOpenAI(_ reply: AIHTTPResponse) throws -> JSONValue {
        let json = try? JSONValue.parse(String(decoding: reply.body, as: UTF8.self))
        guard reply.status == 200 else {
            throw AIError.http(reply.status, json?["error"]?["message"]?.string ?? String(decoding: reply.body.prefix(300), as: UTF8.self))
        }
        guard case .array(let choices)? = json?["choices"], let first = choices.first else {
            throw AIError.badReply("no choices")
        }
        if first["finish_reason"]?.string == "length" { throw AIError.truncated }
        if let refusal = first["message"]?["refusal"]?.string, !refusal.isEmpty { throw AIError.refused(refusal) }
        guard let text = first["message"]?["content"]?.string else { throw AIError.badReply("no message") }
        return try extractObject(text)
    }

    // MARK: the answer

    /// The one JSON object in `text`, tolerating a Markdown fence or a
    /// sentence around it (the compatible servers do not all honour
    /// `json_object`).
    static func extractObject(_ text: String) throws -> JSONValue {
        if let v = try? JSONValue.parse(text), v.object != nil { return v }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let v = try? JSONValue.parse(String(text[start...end])), v.object != nil
        else { throw AIError.badReply(String(text.prefix(200))) }
        return v
    }
}
