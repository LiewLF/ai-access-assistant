import SwiftUI

struct V012RelayPricingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var usageModel: V012UsageTruthModel
    let profile: CodexRelayProfile

    @State private var selectedModel: String
    @State private var currency: String
    @State private var inputPrice: String
    @State private var cachedPrice: String
    @State private var outputPrice: String
    @State private var sourceURL: String
    @State private var automaticUpdates: Bool
    @State private var localMessage: String?

    @ScaledMetric(relativeTo: .body) private var bodySize = 16
    @ScaledMetric(relativeTo: .callout) private var evidenceSize = 14

    init(
        usageModel: V012UsageTruthModel,
        profile: CodexRelayProfile
    ) {
        self.usageModel = usageModel
        self.profile = profile
        let snapshot = usageModel.pricingSnapshot(
            profileID: profile.id
        )
        let model = snapshot?.rates.first?.model
            ?? profile.defaultModel
        let rate = snapshot?.rate(for: model)
        _selectedModel = State(initialValue: model)
        _currency = State(initialValue: snapshot?.currency ?? "USD")
        _inputPrice = State(
            initialValue: rate.map {
                Self.editable($0.inputPerMillion)
            } ?? ""
        )
        _cachedPrice = State(
            initialValue: rate.map {
                Self.editable($0.cachedInputPerMillion)
            } ?? ""
        )
        _outputPrice = State(
            initialValue: rate.map {
                Self.editable($0.outputPerMillion)
            } ?? ""
        )
        _sourceURL = State(initialValue: snapshot?.sourceURL ?? "")
        _automaticUpdates = State(
            initialValue: snapshot?.automaticUpdates ?? false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(profile.name) 定价")
                .font(.title2.bold())
            Text("每百万 token 单价。检查只生成差异预览；你明确应用后，新请求才使用新快照，历史请求不变。")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)

            Form {
                Picker("模型", selection: $selectedModel) {
                    ForEach(modelChoices, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .onChange(of: selectedModel) { _, model in
                    loadRate(model)
                }
                TextField("币种", text: $currency)
                TextField("输入 / 1M", text: $inputPrice)
                TextField("缓存输入 / 1M", text: $cachedPrice)
                TextField("输出 / 1M", text: $outputPrice)
                TextField("定价来源 HTTPS 地址", text: $sourceURL)
                Toggle("每天自动检查 JSON（不自动应用）", isOn: $automaticUpdates)
            }
            .formStyle(.grouped)

            Text(
                "普通网页地址可保存为证据。自动同步要求公开 JSON：schemaVersion、currency、effectiveAt、models；不会携带中转密钥或 Cookie。"
            )
            .font(.system(size: evidenceSize))
            .foregroundStyle(.secondary)

            if let message = localMessage
                ?? usageModel.pricingMessageByProfile[profile.id] {
                Text(message)
                    .font(.system(size: evidenceSize))
                    .foregroundStyle(.secondary)
            }

            if let pending = usageModel
                .pendingPricingSnapshots[profile.id] {
                Text(
                    "待应用：revision \(pending.revision.prefix(8)) · 来源 \(pending.sourceURL ?? "未提供") · 检查 \(pending.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.system(size: evidenceSize, weight: .semibold))
                Button("应用此价格更新") {
                    _ = usageModel.applyPendingPricing(
                        profileID: profile.id
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Button("检查更新") {
                    Task {
                        _ = await usageModel.syncPricing(
                            profileID: profile.id
                        )
                    }
                }
                .disabled(
                    usageModel.syncingPricingProfileID != nil
                        || usageModel.pricingSnapshot(
                            profileID: profile.id
                        )?.sourceURL == nil
                )
                Spacer()
                Button("取消") { dismiss() }
                Button("保存定价") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620, height: 610)
    }

    private var modelChoices: [String] {
        Array(
            Set(profile.models + [profile.defaultModel, selectedModel])
        ).filter { !$0.isEmpty }.sorted()
    }

    private func loadRate(_ model: String) {
        guard let rate = usageModel.pricingSnapshot(
            profileID: profile.id
        )?.rate(for: model) else {
            inputPrice = ""
            cachedPrice = ""
            outputPrice = ""
            return
        }
        inputPrice = Self.editable(rate.inputPerMillion)
        cachedPrice = Self.editable(rate.cachedInputPerMillion)
        outputPrice = Self.editable(rate.outputPerMillion)
    }

    private func save() {
        guard let input = Double(inputPrice),
              let cached = Double(cachedPrice),
              let output = Double(outputPrice) else {
            localMessage = "请输入有效数字；未知价格不要填写 0"
            return
        }
        let saved = usageModel.savePricing(
            profile: profile,
            model: selectedModel,
            currency: currency,
            inputPerMillion: input,
            cachedInputPerMillion: cached,
            outputPerMillion: output,
            sourceURL: sourceURL,
            automaticUpdates: automaticUpdates
        )
        localMessage = usageModel.pricingMessageByProfile[profile.id]
        if saved { loadRate(selectedModel) }
    }

    private static func editable(_ value: Double) -> String {
        value.formatted(
            .number.grouping(.never)
                .precision(.fractionLength(0...8))
        )
    }
}
