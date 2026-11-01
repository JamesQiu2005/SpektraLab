//  AISection.swift — the Parameters rail's AI tab (ARCHITECTURE §7.14).
//
//  Two sections in the rail's own idiom. **Choose a film**: one sentence of
//  intent, a button, and the films a model ranked from proofs of this frame,
//  each with what it saw and an Apply that does what picking the film and
//  pressing Process does. **Refine**: the same sentence, a button, and what
//  each round changed and why, with one Undo for all of it.
//
//  The assistant outlives the tab (`AIAssistant.for`), so switching to
//  Post-Dev to look at what a round did does not throw its answer away.

import AppKit
import SwiftUI

extension AIAssistant {
    private static let registry = NSMapTable<Session, AIAssistant>.weakToStrongObjects()

    /// The one assistant for `session`, made on first use.
    static func `for`(_ session: Session) -> AIAssistant {
        if let a = registry.object(forKey: session) { return a }
        let a = AIAssistant(session: session)
        registry.setObject(a, forKey: session)
        return a
    }
}

struct AISection: View {
    @Bindable var session: Session
    @Bindable var assistant: AIAssistant
    @AppStorage(AISettings.enabledKey) private var enabled = false

    init(session: Session) {
        self.session = session
        self.assistant = AIAssistant.for(session)
    }

    private var hasFrame: Bool { session.selection != nil && session.pair == nil }

    var body: some View {
        if !enabled {
            PanelSection(L("AI Assistant", zh: "AI 助手"), key: "ai.off") {
                RailRows {
                    caption(L("Off. Turn it on in Settings ▸ AI, with a Claude or OpenAI-compatible API key. Small copies of the photograph are sent to that service only when you press a button here.",
                              zh: "未开启。请在 设置 ▸ AI 中打开，并填写 Claude 或 OpenAI 兼容的 API Key。只有在这里点按钮时，才会把照片的小尺寸副本发送给该服务。"))
                }
            }
        } else {
            VStack(spacing: 0) {
                chooser
                SectionDivider(above: "ai.choose")
                refiner
            }
        }
    }

    // MARK: choose a film

    private var chooser: some View {
        PanelSection(L("Choose a Film", zh: "AI 选片"), key: "ai.choose") {
            RailRows {
                intentField
                Toggle(L("Include black and white", zh: "包含黑白胶片"), isOn: $assistant.includeMonochrome)
                    .toggleStyle(.checkbox).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 8) {
                    pill(L("Recommend", zh: "推荐胶片"),
                         help: L("Print this frame on every colour film, then ask the model which suit it.",
                                 zh: "用每款彩色胶片各冲印一张小样，再请模型判断哪款适合这张照片。"),
                         enabled: hasFrame && !assistant.busy) { assistant.recommendFilm() }
                    if assistant.busy { pill(L("Stop", zh: "停止"), help: "", enabled: true) { assistant.cancel() } }
                }
                status
                if let rec = assistant.recommendation, rec.url == session.selection {
                    if !rec.summary.isEmpty { Text(rec.summary).font(Theme.Font.caption).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true) }
                    ForEach(rec.picks) { pick in pickRow(pick) }
                    caption(L("\(rec.compared) films compared on one neutral print.", zh: "在同一中性冲印下比较了 \(rec.compared) 款胶片。"))
                }
            }
        }
    }

    private func pickRow(_ pick: AIAssistant.Pick) -> some View {
        let current = session.params.filmStock == pick.candidate.film
            && (pick.candidate.paper == nil ? session.params.scanFilm
                : (!session.params.scanFilm && session.params.printStock == pick.candidate.paper))
        return HStack(alignment: .top, spacing: 8) {
            Image(decorative: pick.thumbnail, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .background(Theme.plot)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(pick.score)").font(Theme.Font.value).foregroundStyle(Theme.accent)
                    Text(session.catalog.stock(pick.candidate.film)?.name ?? pick.candidate.film)
                        .font(Theme.Font.label).foregroundStyle(Theme.text).lineLimit(1)
                }
                Text(pick.candidate.paper.map { session.catalog.stock($0)?.name ?? $0 } ?? L("scanned", zh: "扫描"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
                Text(pick.reason).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if current {
                    caption(L("In use", zh: "当前使用"))
                } else {
                    pill(L("Apply", zh: "应用"), help: L("Choose this film and paper, then Process.", zh: "选用这款胶片和相纸并冲印。"),
                         enabled: !assistant.busy && !session.batchExporting) { assistant.apply(pick) }
                }
            }
        }
    }

    // MARK: refine

    private var refiner: some View {
        PanelSection(L("Refine", zh: "AI 精修"), key: "ai.refine") {
            RailRows {
                caption(L("The model looks at the print and moves this frame's own controls — exposure, the enlarger's filters, Scene Placement and Post-Dev — up to \(AIAssistant.maxRounds) rounds. The film and paper stay.",
                          zh: "模型查看成片后调整这张照片自己的参数：曝光、放大机滤色、场景置位和显影后调色，最多 \(AIAssistant.maxRounds) 轮。胶片和相纸不变。"))
                HStack(spacing: 8) {
                    pill(L("Refine", zh: "开始精修"),
                         help: L("Uses the intent above.", zh: "使用上面填写的意图。"),
                         enabled: hasFrame && !assistant.busy) { assistant.refine() }
                    pill(L("Undo AI changes", zh: "撤销 AI 修改"),
                         help: L("Put the edit back as it was before the first AI change on this frame, as one step.",
                                 zh: "把这张照片恢复到第一次 AI 修改之前的状态（一步撤销）。"),
                         enabled: assistant.canUndo && !assistant.busy) { assistant.undoAI() }
                }
                ForEach(assistant.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Round \(step.round)", zh: "第 \(step.round) 轮"))
                            .font(Theme.Font.label).foregroundStyle(Theme.text)
                        // A local model on the compatible path may leave it out.
                        Text(step.rationale.isEmpty ? L("(No explanation given.)", zh: "（模型没有给出说明。）") : step.rationale)
                            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if !step.changed.isEmpty {
                            Text(step.changed.joined(separator: " · "))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let r = step.refused {
                            Text(L("Not applied: \(r)", zh: "未应用：\(r)")).font(Theme.Font.caption)
                                .foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: pieces

    private var intentField: some View {
        TextField(L("Intent (optional): warm and soft, cinematic night…", zh: "意图（可选）：温暖柔和、电影感夜景……"),
                  text: $assistant.intent, axis: .vertical)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .font(Theme.Font.caption)
    }

    @ViewBuilder private var status: some View {
        switch assistant.phase {
        case .idle:
            if let e = assistant.error {
                Text(e).font(Theme.Font.caption).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
            } else if session.pair != nil {
                caption(L("Not available on a half-frame pair yet.", zh: "暂不支持半格拼接。"))
            }
        case .proofing(let done, let total):
            progress(L("Printing proofs \(done)/\(total)…", zh: "正在冲印小样 \(done)/\(total)……"))
        case .asking:
            progress(L("Asking the model…", zh: "正在请模型判断……"))
        case .refining(let round, let total):
            progress(round == 0 ? L("Processing…", zh: "正在冲印……")
                     : L("Round \(round) of \(total)…", zh: "第 \(round)/\(total) 轮……"))
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            caption(text)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The rail's one button shape (`ClipboardSection.pill`).
    private func pill(_ title: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.value)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }
}
