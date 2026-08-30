import SwiftUI

struct V013WeeklyCapacitySummaryView: View {
    let status: V013WeeklyUsageStatus

    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "当前使用结构下周/月等效容量",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
                .font(.headline)
                Spacer()
                Text("反推当前组合可用总量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summary

            DisclosureGroup(
                "估算依据与边界",
                isExpanded: $evidenceExpanded
            ) {
                evidence
                    .padding(.top, 6)
            }
            .font(.subheadline)
            .accessibilityHint("展开后显示样本、价格快照和折算边界")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前订阅每周与三十点四天等效估算")
        .accessibilityHint(status.reason)
    }

    @ViewBuilder
    private var summary: some View {
        if let value = status.estimate {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170), spacing: 10)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                metric(
                    title: "满额周 Token",
                    value: "约 \(tokens(Int64(value.fullWeekTokens.rounded())))",
                    note: "按官方每周已用比例反推"
                )
                metric(
                    title: "API 等价 / 周",
                    value: value.fullWeekAPIEquivalentUSD.map {
                        "$\(money($0))"
                    } ?? "暂不可估算",
                    note: "参考价格，不是现金账单"
                )
                let monthlyTokens = Int64(
                    (
                        value.fullWeekTokens
                            * V013WeeklyUsageEstimate.monthlyEquivalentFactor
                    ).rounded()
                )
                metric(
                    title: "30.4 天等效",
                    value: "约 \(tokens(monthlyTokens))",
                    note: value.fullWeekAPIEquivalentUSD.map {
                        "API 等价 $\(money($0 * V013WeeklyUsageEstimate.monthlyEquivalentFactor))"
                    } ?? "按当前周乘以 4.348125"
                )
            }
            Text(
                "官方已用 \(value.usedPercent)% / 剩余 \(100 - value.usedPercent)% · 重置 \(value.resetsAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.subheadline.weight(.medium).monospacedDigit())
            Text("估算随官方窗口变化；不是官方额度、订阅价格或账单。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if let capacity = status.supplemental
                .currentEquivalentCapacity {
                equivalentCapacitySummary(capacity)
            } else if let reference = status.supplemental
                .localStructureReference {
                localStructureReferenceSummary(reference)
            }
            if let observed = status.supplemental.observed {
                Label(
                    "现在已确认：本周本机观察",
                    systemImage: "checkmark.circle"
                )
                .font(.headline)
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 170), spacing: 10)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    metric(
                        title: "已确认 Token",
                        value: tokens(observed.tokens),
                        note: "(observed.requestCount) 个完成时账号匹配请求"
                    )
                    metric(
                        title: "API 等价",
                        value: observed.apiEquivalentUSD.map {
                            "$\(money($0))"
                        } ?? "暂不可估算",
                        note: "当前价卡参考，不是账单"
                    )
                }
            } else {
                Label(
                    "当前周满额点估算：暂不可给出",
                    systemImage: "hourglass"
                )
                .font(.headline)
            }
            Text("账号级点估算未出现：\(status.reason)")
                .font(.body.weight(.medium))
            if let used = status.officialUsedPercent {
                Text(percentResolutionText(used))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let activity = status.supplemental.officialActivity {
                officialActivitySummary(activity)
            }
            if let history = status.supplemental
                .historicalEquivalentCapacity {
                equivalentCapacitySummary(history)
            } else {
                Text("历史参考：暂无时间边界对齐的同账号样本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(nextAction(for: status.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var evidence: some View {
        if let value = status.estimate {
            if let credits = value.fullWeekCredits {
                Text(
                    "满额周 credits 费率等价约 \(number(credits))；已购 credits 是另一项资源。"
                )
            }
            Text(
                "本窗口实测 \(tokens(value.observedWindowTokens)) Token"
                    + value.observedWindowAPIEquivalentUSD.map {
                        " · API 等价 $\(money($0))"
                    }.orEmpty
            )
            if let interval = intervalText(value) {
                Text(interval)
            }
            Text(
                "观察 \(value.observationCount) 次 · 百分点变化 \(value.percentageTransitionCount) · 可用区间 \(value.usableIntervalSampleCount) · 置信度\(value.confidence.rawValue)"
            )
            Text(
                "来源：官方每周百分比 + 完整本地请求账本 + 同一价格快照 \(value.pricingRevision.prefix(8)) · 刷新 \(value.refreshedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        } else {
            Text(
                "观察 \(status.observationCount) 次 · 百分点变化 \(status.percentageTransitionCount) · 可用区间 \(status.usableIntervalSampleCount)"
            )
            Text("“百分点变化”只代表官方整数读数上升；只有区间内 Token、账号和来源都匹配，才计入“可用区间”。")
            if let reference = status.supplemental
                .localStructureReference {
                Text(
                    "本机结构参考：\(reference.requestCount) 个请求 · \(tokens(reference.observedTokens)) Token · 完成时账号已确认 \(tokens(reference.identityBoundTokens))。"
                )
            }
            if let reference = status.supplemental
                .historicalEquivalentCapacity {
                Text(
                    "历史参考窗口重置：\(reference.resetsAt.formatted(date: .abbreviated, time: .shortened))"
                )
            }
        }
        Text(
            "30.4 天仅按当前周乘以 4.348125 折算，不是官方月额度、现金账单或官方承诺上限。"
        )
    }

    @ViewBuilder
    private func equivalentCapacitySummary(
        _ value: V013EquivalentCapacityEvidence
    ) -> some View {
        let isHistory = value.scope == .historicalWindow
        VStack(alignment: .leading, spacing: 7) {
            Text(isHistory ? "历史账号窗口参考" : "当前账号级容量区间")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                metric(
                    title: isHistory ? "历史周等效" : "周等效 Token",
                    value: capacityText(value),
                    note: capacitySourceText(value)
                )
                metric(
                    title: "30.4 天月等效",
                    value: monthlyCapacityText(value),
                    note: "周等效 × 4.348125，不是官方月额度"
                )
                metric(
                    title: "API / credits 等价",
                    value: "暂不可安全换算",
                    note: "官方账户总量未返回完整模型与缓存组合"
                )
            }
        }
    }

    @ViewBuilder
    private func localStructureReferenceSummary(
        _ value: V013LocalStructureCapacityReference
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("当前本机使用结构参考")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                metric(
                    title: "周等效参考",
                    value: "至少 \(tokens(Int64(value.lowerWeekTokens.rounded())))",
                    note: "本机 Token 对应官方整数百分点的保守折算"
                )
                metric(
                    title: "30.4 天参考",
                    value: "至少 \(tokens(Int64((value.lowerWeekTokens * V013WeeklyUsageEstimate.monthlyEquivalentFactor).rounded())))",
                    note: "周参考 × 4.348125，不是官方月额度"
                )
                metric(
                    title: "API 等价参考 / 周",
                    value: value.lowerWeekAPIEquivalentUSD.map {
                        "至少 $\(money($0))"
                    } ?? "暂不可安全换算",
                    note: "按本机模型与缓存结构；不是订阅账单"
                )
            }
            Text(
                "本机 \(value.displayedPercentFrom)%→\(value.displayedPercentThrough)% 区间；其他设备与未绑定活动会改变账号结果，因此不显示伪上界。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func officialActivitySummary(
        _ value: V013OfficialActivityEvidence
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("已使用证据")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let day = value.latestDailyBucket,
               let dayTokens = value.latestDailyBucketTokens {
                Text("官方最近日桶 \(day)：\(tokens(dayTokens)) Token")
            }
            Text(
                "当前周本机记录：\(tokens(value.localWindowTokens)) Token"
                    + " · 其中完成时账号已确认 \(tokens(value.localWindowIdentityBoundTokens))"
            )
            Text("官方未定义日桶时区与数据截止点；日桶不直接套当前周百分比。本机记录不含其他设备。")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(9)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func capacityText(
        _ value: V013EquivalentCapacityEvidence
    ) -> String {
        let lower = tokens(Int64(value.lowerWeekTokens.rounded()))
        if let upper = value.upperWeekTokens {
            return "\(lower)–\(tokens(Int64(upper.rounded())))"
        }
        return "至少 \(lower)"
    }

    private func monthlyCapacityText(
        _ value: V013EquivalentCapacityEvidence
    ) -> String {
        let factor = V013WeeklyUsageEstimate.monthlyEquivalentFactor
        let lower = tokens(Int64((value.lowerWeekTokens * factor).rounded()))
        if let upper = value.upperWeekTokens {
            return "\(lower)–\(tokens(Int64((upper * factor).rounded())))"
        }
        return "至少 \(lower)"
    }

    private func capacitySourceText(
        _ value: V013EquivalentCapacityEvidence
    ) -> String {
        switch value.source {
        case .officialAccountAlignedDelta:
            return "同账号、同窗口、同有效截止的官方 Token 差值"
        }
    }

    private func metric(
        title: String,
        value: String,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.8),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityElement(children: .combine)
    }

    private func nextAction(for reason: String) -> String {
        if reason.contains("已用为 0%") {
            return "本周发生用量后刷新；助手会自动计算。"
        }
        if reason.contains("未知")
            || reason.contains("过期")
            || reason.contains("尚未读取") {
            return "刷新官方资源后自动重试。"
        }
        return "当官方 Token 数据截止点与同窗口百分比边界可对齐时，自动升级为账号级区间。"
    }

    private func percentResolutionText(_ used: Int) -> String {
        if used == 0 {
            return "官方 App Server 会把上游百分比四舍五入为整数；0% 仍可能代表不足 0.5%，不能作除数。"
        }
        let lower = max(0, Double(used) - 0.5)
        let upper = min(100, Double(used) + 0.5)
        return "官方 \(used)% 是四舍五入整数，实际分辨率约为 \(number(lower))%–<\(number(upper))%。"
    }

    private func intervalText(
        _ value: V013WeeklyUsageEstimate
    ) -> String? {
        if let upper = value.resolutionUpperWeekTokens {
            return "按官方整数分辨率，点估算范围约 \(tokens(Int64(value.resolutionLowerWeekTokens.rounded())))–\(tokens(Int64(upper.rounded()))) Token / 周"
        }
        guard let lower = value.lowerWeekTokens,
              let upper = value.upperWeekTokens else { return nil }
        var text =
            "样本区间 \(tokens(Int64(lower.rounded())))–\(tokens(Int64(upper.rounded()))) Token / 周"
        if let lowerUSD = value.lowerWeekAPIEquivalentUSD,
           let upperUSD = value.upperWeekAPIEquivalentUSD {
            text += " · API $\(money(lowerUSD))–$\(money(upperUSD))"
        }
        return text
    }

    private func tokens(_ value: Int64) -> String {
        value.formatted()
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
}

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
                Text("生效价格快照 \(pricing.revision.prefix(8))")
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
                "输出 \(tokens(turn.outputTokens)) · 推理 \(tokens(turn.reasoningOutputTokens)) · 计费 Token 合计 \(tokens(turn.billableTokens))"
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
            if let active = turn.activeContextTokens {
                Text(
                    "活动上下文 \(tokens(active)) Token；此值来自 last_token_usage.total_tokens，不是计费 Token 合计"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if turn.reasoningOutputTokens > 0 {
                Text(
                    "输出中含推理 \(tokens(turn.reasoningOutputTokens))；未重复计费"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let text = costText(cost) {
                Text("请求发生时估算：\(text)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            } else {
                Text("请求发生时估算：无法估算")
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
            "完成请求，\(turn.model)，\(turn.calls.count) 次模型调用，计费 Token \(turn.billableTokens)"
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
