import SwiftUI

struct V012RecentUsageView: View {
    @ObservedObject var model: V012UsageTruthModel
    let planType: String?
    let profiles: [CodexRelayProfile]

    @State private var pricingExpanded = false
    @State private var requestsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Label("按需核对", systemImage: "tray.full")
                    .font(.headline)
                Text("需要更新估价或追查某次请求时再展开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $pricingExpanded) {
                officialPricingRow
                    .padding(.top, 7)
            } label: {
                disclosureLabel(
                    title: "价格快照与更新",
                    purpose: "决定是否应用新价格；历史请求保持原快照"
                )
            }
            .padding(11)
            .background(
                .secondary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10)
            )

            DisclosureGroup(isExpanded: $requestsExpanded) {
                recentRequests
                    .padding(.top, 7)
            } label: {
                disclosureLabel(
                    title: "最近完成请求（\(model.turns.count)）",
                    purpose: "核对 Token、时延与请求发生时费用"
                )
            }
            .padding(11)
            .background(
                .secondary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("价格快照与最近完成请求明细")
    }

    private func disclosureLabel(
        title: String,
        purpose: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var officialPricingRow: some View {
        let pricing = model.officialPricingSnapshot
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    "生效价格快照 \(pricing.effectiveAt.formatted(date: .abbreviated, time: .shortened))"
                )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                if model.isCheckingOfficialPricing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("检查官方 API 价格") {
                        Task { await model.checkOfficialPricing() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(
                "credits rate card 核验：\(pricing.effectiveCreditsCheckedAt.formatted(date: .abbreviated, time: .omitted))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "API 模型页核验：\(pricing.effectiveAPICheckedAt.formatted(date: .abbreviated, time: .omitted)) · Speed 核验：\(pricing.effectiveSpeedCheckedAt.formatted(date: .abbreviated, time: .omitted))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(model.officialPricingMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let source = URL(string: pricing.apiSourceURL) {
                    Link("查看官方 API 价格", destination: source)
                }
                if model.pendingOfficialPricingSnapshot != nil {
                    Button("应用官方价格更新") {
                        _ = model.applyPendingOfficialPricing()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.caption)
            Text("检查只生成 diff；不会静默替换生效价格。已记录请求继续使用原快照。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.8),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("官方价格快照与手动更新")
    }

    @ViewBuilder
    private var recentRequests: some View {
        if model.turns.isEmpty {
            Text(model.status)
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(model.turns.prefix(5))) { turn in
                requestRow(
                    turn,
                    cost: model.cost(
                        for: turn,
                        planType: planType,
                        profiles: profiles
                    ),
                    currentCost: model.currentRepricedCost(
                        for: turn,
                        planType: planType,
                        profiles: profiles
                    )
                )
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func requestRow(
        _ turn: V012CompletedTurnUsage,
        cost: V012CostResult,
        currentCost: V012CostResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    turn.completedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                Text("\(turn.calls.count) 次模型调用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "\(turn.model) · tier \(turn.serviceTier ?? "未知") · 首字 \(duration(turn.timeToFirstTokenMilliseconds)) · 完成 \(duration(turn.durationMilliseconds))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "输入 \(tokens(turn.inputTokens)) · 未缓存 \(optionalTokens(turn.uncachedInputTokens)) · 缓存读取 \(tokens(turn.cachedInputTokens))"
            )
            .font(.body)
            .foregroundStyle(.primary)
            Text(
                "输出 \(tokens(turn.outputTokens)) · 其中推理 \(tokens(turn.reasoningOutputTokens)) · 模型处理 Token \(tokens(turn.modelProcessedTokens))"
            )
            .font(.body)
            .foregroundStyle(.primary)
            if let cacheWrite = turn.cacheWriteInputTokens {
                Text("缓存写入 \(tokens(cacheWrite))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("缓存写入：官方字段未返回；未缓存输入与费用保持未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let evidence = turn.officialRequestPricing, evidence.matches(turn) {
                Text("官方任务用量确认：\(evidence.model) · \(evidence.serviceTier)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let active = turn.activeContextTokens {
                Text(
                    "活动上下文 \(tokens(active)) Token；此值来自 last_token_usage.total_tokens，不是模型处理量"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if turn.reasoningOutputTokens > 0 {
                Text(
                    "输出中含推理 \(tokens(turn.reasoningOutputTokens))；未重复相加"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let text = costText(cost) {
                Text("请求发生时按分项价率估算：\(text)；不是账单")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            } else {
                Text("请求发生时按分项价率估算：无法估算；不是账单")
                    .font(.body.weight(.semibold))
            }
            if let currentCost, let text = costText(currentCost) {
                Text("按当前价格回算：\(text)")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            Text(
                "证据：Codex token_count + task_complete · \(cost.pricingEvidence)"
                    + cost.pricingCheckedAt.map {
                        " · 核验 \($0.formatted(date: .abbreviated, time: .omitted))"
                    }.orEmpty
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if let source = cost.pricingSourceURL,
               let url = URL(string: source) {
                Link("查看价格来源", destination: url)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "完成请求，\(turn.model)，\(turn.calls.count) 次模型调用，模型处理 Token \(turn.modelProcessedTokens)"
        )
    }

    private func costText(_ value: V012CostResult) -> String? {
        var parts: [String] = []
        if let credits = value.credits {
            parts.append("credits 费率等价 \(number(credits))")
        }
        if let usd = value.apiEquivalentUSD {
            parts.append("API 等价 $\(money(usd))")
        }
        if let amount = value.relayAmount,
           let currency = value.relayCurrency {
            parts.append("中转预计 \(currency) \(money(amount))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tokens(_ value: Int64) -> String {
        value.formatted()
    }

    private func duration(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "未知" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 {
            return String(format: "%.1f 秒", seconds)
        }
        return String(
            format: "%d分%.0f秒",
            Int(seconds) / 60,
            seconds.truncatingRemainder(dividingBy: 60)
        )
    }

    private func number(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(0...2))
        )
    }

    private func money(_ value: Double) -> String {
        value.formatted(
            .number.precision(
                .fractionLength(value < 1 ? 4 : 2)
            )
        )
    }

    private func optionalTokens(_ value: Int64?) -> String {
        value.map { tokens($0) } ?? "未知"
    }

}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
