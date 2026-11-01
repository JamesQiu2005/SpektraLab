//  AISettingsPage.swift — Settings ▸ AI (ARCHITECTURE §7.14).
//
//  The switch and what it consents to, the provider and its model, and the
//  key. The key field is write-only: it saves to the Keychain and is shown
//  back only as "saved", never as text, so a screenshot of this page cannot
//  carry it.

import SwiftUI

struct AISettingsPage: View {
    @AppStorage(AISettings.enabledKey) private var enabled = false
    @AppStorage(AISettings.providerKey) private var providerRaw = AIProviderKind.anthropic.rawValue
    @AppStorage(AISettings.anthropicModelKey) private var anthropicModel = AISettings.anthropicModels[0]
    @AppStorage(AISettings.openAIModelKey) private var openAIModel = ""
    @AppStorage(AISettings.openAIBaseURLKey) private var openAIBaseURL = AISettings.defaultOpenAIBaseURL
    @State private var keyDraft = ""
    @State private var keySaved: [AIProviderKind: Bool] = [:]
    @State private var testResult: String?
    @State private var testing = false

    private var provider: AIProviderKind { AIProviderKind(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        SettingsGroup(L("AI Assistant", zh: "AI 助手")) {
            SettingsRows {
                VStack(alignment: .leading, spacing: 4) {
                    ToggleRow(label: L("Use AI to choose films and refine prints", zh: "使用 AI 选片和精修"), isOn: $enabled)
                    caption(L("Only when you press Recommend or Refine in the AI tab, small copies of the photograph are sent to the provider below — a contact sheet of proofs about 1,500 px across when choosing a film, the print at \(AISettings.sentLongEdge) px when refining — with its exposure data and the edit's numbers. Nothing is sent otherwise. Usage is billed to your own API account.",
                              zh: "只有在 AI 标签页点击“推荐胶片”或“开始精修”时，才会把照片的小尺寸副本发送给下面的服务商：选片时是约 1500 px 宽的小样联系表，精修时是 \(AISettings.sentLongEdge) px 的成片，同时附带拍摄参数和调整数值。其他时候不发送任何内容。费用计入你自己的 API 账户。"))
                }
            }
        }
        SettingsGroup(L("Provider", zh: "服务商")) {
            SettingsRows {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("Provider", zh: "服务商"), selection: $providerRaw) {
                        ForEach(AIProviderKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    switch provider {
                    case .anthropic:
                        Picker(L("Model", zh: "模型"), selection: $anthropicModel) {
                            ForEach(AISettings.anthropicModels, id: \.self) { Text($0).tag($0) }
                        }
                        caption(L("Opus 5.5 judges best; Sonnet 5.5 is faster and cheaper.",
                                  zh: "Opus 5.5 判断最好；Sonnet 5.5 更快、更便宜。"))
                    case .openAICompatible:
                        TextField("Base URL", text: $openAIBaseURL).textFieldStyle(.roundedBorder)
                        TextField(L("Model (must accept images)", zh: "模型（需支持图片输入）"), text: $openAIModel)
                            .textFieldStyle(.roundedBorder)
                        caption(L("Any server with OpenAI's /chat/completions: OpenAI, OpenRouter, a local Ollama (http://localhost:11434/v1, no key).",
                                  zh: "任何支持 OpenAI /chat/completions 的服务：OpenAI、OpenRouter、本地 Ollama（http://localhost:11434/v1，无需 Key）。"))
                    }
                }
            }
        }
        SettingsGroup("API Key") {
            SettingsRows {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SecureField(saved ? L("Saved in the Keychain — type to replace", zh: "已保存在钥匙串中——输入以替换")
                                          : L("Paste the key", zh: "粘贴 Key"), text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                        action(L("Save", zh: "保存")) {
                            AIKeychain.write(keyDraft, for: provider)
                            keyDraft = ""
                            refreshSaved()
                        }
                        .disabled(keyDraft.isEmpty)
                        if saved {
                            action(L("Remove", zh: "删除")) {
                                AIKeychain.write("", for: provider)
                                refreshSaved()
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        action(testing ? L("Testing…", zh: "测试中……") : L("Test connection", zh: "测试连接")) { test() }
                            .disabled(testing || !enabled)
                        if let testResult { caption(testResult) }
                    }
                    caption(L("Stored in your login Keychain, one per provider. Never written to settings, sidecars or logs.",
                              zh: "按服务商分别保存在登录钥匙串中，不会写入设置、sidecar 或日志。"))
                }
            }
        }
        .onAppear(perform: refreshSaved)
        .onChange(of: providerRaw) { keyDraft = ""; testResult = nil; refreshSaved() }
    }

    private var saved: Bool { keySaved[provider] ?? false }

    private func refreshSaved() {
        for kind in AIProviderKind.allCases { keySaved[kind] = AIKeychain.has(kind) }
    }

    /// One tiny text-only request: proves the key, the model and the address.
    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let client = try AISettings.client()
                let reply = try await client.complete(AIRequest(
                    system: "Answer with the JSON object asked for.",
                    parts: [.text("Return {\"ok\": true}.")],
                    schema: ["type": "object", "additionalProperties": false, "required": ["ok"],
                             "properties": ["ok": ["type": "boolean"]]],
                    maxTokens: 2000))
                testResult = reply["ok"]?.bool == true ? L("Connected.", zh: "连接成功。")
                                                         : L("Connected, but the answer was unexpected.", zh: "已连接，但回答不符合预期。")
            } catch let e as AIError {
                testResult = e.localized
            } catch {
                testResult = "\(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func action(_ title: String, _ act: @escaping () -> Void) -> some View {
        Button(title, action: act)
            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
