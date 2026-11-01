//  AISettings.swift — Settings ▸ AI: the switch, the provider, the model, and
//  where the key lives (AI assistant, ARCHITECTURE §7.14).
//
//  **Off by default, and a consent of its own.** Settings ▸ Agents lets
//  another program on this Mac drive the app; this sends a downscaled copy of
//  the photograph to a service on the internet. Two different things, two
//  switches. The key never touches `UserDefaults`, a sidecar or the log: it
//  is a Keychain item, read for the length of one request.

import Foundation
import Security

enum AISettings {
    static let enabledKey = Session.uiKey + "ai.enabled"
    static let providerKey = Session.uiKey + "ai.provider"
    static let anthropicModelKey = Session.uiKey + "ai.anthropicModel"
    static let openAIModelKey = Session.uiKey + "ai.openAIModel"
    static let openAIBaseURLKey = Session.uiKey + "ai.openAIBaseURL"

    /// The models the Anthropic picker offers. The first is the default.
    static let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-5-5"]
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    /// The long edge of the print sent when refining: enough to judge a
    /// grade. A recommendation sends the contact sheet instead (300 px tiles,
    /// about 1,500 px across), as the consent text on Settings ▸ AI says.
    static let sentLongEdge = 1024

    static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }
    static var provider: AIProviderKind {
        get { defaults.string(forKey: providerKey).flatMap(AIProviderKind.init(rawValue:)) ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: providerKey) }
    }
    static var anthropicModel: String {
        get { defaults.string(forKey: anthropicModelKey) ?? anthropicModels[0] }
        set { defaults.set(newValue, forKey: anthropicModelKey) }
    }
    static var openAIModel: String {
        get { defaults.string(forKey: openAIModelKey) ?? "" }
        set { defaults.set(newValue, forKey: openAIModelKey) }
    }
    static var openAIBaseURL: String {
        get { defaults.string(forKey: openAIBaseURLKey) ?? defaultOpenAIBaseURL }
        set { defaults.set(newValue, forKey: openAIBaseURLKey) }
    }

    /// The client the settings describe, with its key, or why there is none.
    static func client() throws -> AIClient {
        guard enabled else {
            throw AIError.notConfigured(en: "AI is off. Turn it on in Settings ▸ AI.", zh: "AI 功能未开启，请到 设置 ▸ AI 打开。")
        }
        let kind = provider
        let key = AIKeychain.read(kind) ?? ""
        switch kind {
        case .anthropic:
            return AIClient(kind: kind, model: anthropicModel, baseURL: "", apiKey: key)
        case .openAICompatible:
            return AIClient(kind: kind, model: openAIModel, baseURL: openAIBaseURL, apiKey: key)
        }
    }
}

/// One generic-password item per provider, in the login keychain.
enum AIKeychain {
    static let service = "SpektraLab AI"

    private static func query(_ kind: AIProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue]
    }

    static func read(_ kind: AIProviderKind) -> String? {
        var q = query(kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store `key`, or remove the item when it is empty.
    @discardableResult
    static func write(_ key: String, for kind: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query(kind) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = query(kind)
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func has(_ kind: AIProviderKind) -> Bool { read(kind)?.isEmpty == false }
}
