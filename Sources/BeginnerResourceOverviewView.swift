import SwiftUI

struct V011UnifiedResourceOverviewCard: View {
    @ObservedObject var accessModel: V011AccessModel
    @ObservedObject var historyModel: V011HistoryModel
    @ObservedObject var usageModel: V012UsageTruthModel
    let onFailureAction: (V013FailurePrimaryAction) -> Void

    @State private var pricingProfile: CodexRelayProfile?
    @State private var officialDetailsExpanded = false
    @State private var relayDetailsExpanded = false

    var body: some View {
        let items = accessModel.unifiedResourceOverview(
            maximumSavedRelays: 4
        )
        let officialItem = items.first { $0.kind == .official }
        let relayItems = items.filter { $0.kind == .savedRelay }
        let shownRelays = relayItems.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        "本周官方资源",
                        systemImage: "gauge.open.with.lines.needle.33percent"
                    )
                    .font(.title2.weight(.semibold))
                    Text("先判断套餐、剩余和满额价值，再看证据与明细。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if accessModel.isRefreshingOfficialUsage {
                    ProgressView().controlSize(.small)
                    Text("正在读取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(
                        accessModel.officialUsageSnapshot == nil
                            ? "读取官方资源" : "刷新官方资源"
                    ) {
                        accessModel.refreshOfficialUsage(
                            threadID: latestOfficialThreadID
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(!accessModel.canRefreshOfficialUsage)
                }
            }

            if let officialItem {
                officialSummary(officialItem)
            }

            if let failure = accessModel.officialUsageFailurePresentation {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        failure.conclusion,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    Text(failure.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BeginnerFailureEvidenceDisclosure(
                        presentation: failure
                    )
                    Button(failure.primaryAction.title) {
                        onFailureAction(failure.primaryAction)
                    }
                    .buttonStyle(.bordered)
                }
            } else if let error = accessModel.officialUsageErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            V013WeeklyCapacitySummaryView(
                status: usageModel.weeklyUsageStatus
            )

            if let officialItem {
                officialDetails(officialItem)
            }

            if !relayItems.isEmpty {
                DisclosureGroup(isExpanded: $relayDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(relayItems) { item in
                            resourceRow(item)
                        }
                        if accessModel.savedProfiles.count > shownRelays {
                            Text(
                                "另有 \(accessModel.savedProfiles.count - shownRelays) 条已保存中转；请到“接入与切换”查看。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 7)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已保存中转（\(accessModel.savedProfiles.count)）")
                            .font(.subheadline.weight(.semibold))
                        Text("切换线路或核对中转余额、定价时展开")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(
                    .secondary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }

            V012RecentUsageView(
                model: usageModel,
                planType: accessModel.officialUsageSnapshot?.planType,
                profiles: accessModel.savedProfiles
            )

            Text(
                "窗口百分比不是精确剩余 token；token 与 credits 金额均为活动或估算，不是账单。未知余额不会被推测。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本周官方资源与按需明细")
        .accessibilityHint(
            "先显示官方套餐、每周剩余、重置时间与满额估算；证据、中转和请求明细可展开。"
        )
        .task {
            if historyModel.rows.isEmpty {
                historyModel.loadFirstPage(provider: nil)
            }
            refreshCompletedUsage()
            await usageModel.syncPricingIfDue()
        }
        .onChange(of: historyModel.rows) { _, _ in
            refreshCompletedUsage()
        }
        .onChange(of: accessModel.officialUsageSnapshot) { _, _ in
            refreshCompletedUsage()
        }
        .sheet(item: $pricingProfile) { profile in
            V012RelayPricingEditorView(
                usageModel: usageModel,
                profile: profile
            )
        }
    }

    private func officialSummary(
        _ item: V011UnifiedResourceItem
    ) -> some View {
        let presentation = accessModel
            .officialUsageCardPresentation
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name)
                    .font(.headline)
                if item.isCurrent {
                    Text("当前")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(item.availability)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let freshness = presentation.freshnessText {
                Label(
                    freshness,
                    systemImage: presentation.isFresh
                        ? "clock.badge.checkmark" : "clock.badge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    presentation.isFresh ? Color.secondary : Color.orange
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170), spacing: 10)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                summaryMetric(
                    title: "当前官方套餐",
                    value: presentation.planText,
                    note: presentation.isFresh
                        ? "决定使用哪类官方资源"
                        : "过期值仅供回看，请刷新"
                )
                summaryMetric(
                    title: "本周已用 / 剩余",
                    value: presentation.weeklyUsageText,
                    note: presentation.isFresh
                        ? "官方窗口百分比"
                        : "过期值不是当前额度"
                )
                summaryMetric(
                    title: "重置时间",
                    value: presentation.resetText,
                    note: presentation.isFresh
                        ? "决定何时安排大任务"
                        : "过期时间不是当前承诺"
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("官方套餐、每周用量与重置时间")
    }

    private func summaryMetric(
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
        .accessibilityElement(children: .combine)
    }

    private func officialDetails(
        _ item: V011UnifiedResourceItem
    ) -> some View {
        DisclosureGroup(isExpanded: $officialDetailsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.balance)
                Text(item.planAllowance)
                Text(item.accountActivity)
                Text(item.spendControl)
                if let thread = accessModel.officialUsageSnapshot?
                    .tokenUsage?.threadUsage {
                    officialThreadUsage(thread)
                }
                Text(item.modelCompatibility)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.contextCompatibility)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("证据：\(item.evidenceSource)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    item.refreshedAt.map {
                        "刷新：\($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "刷新：未知"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.top, 7)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("已购 credits、用量控制与官方证据")
                    .font(.subheadline.weight(.semibold))
                Text("购买额外资源或排查读数时展开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityHint("展开后显示已购 credits、用量控制、模型、来源和刷新时间")
    }

    private func resourceRow(
        _ item: V011UnifiedResourceItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(item.name).font(.title3.weight(.semibold))
                if item.isCurrent {
                    Text("当前")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(item.availability)
                    .font(.caption.weight(.medium))
            }
            Text(item.balance).foregroundStyle(.primary)
            Text(item.planAllowance).foregroundStyle(.primary)
            Text(item.accountActivity).foregroundStyle(.primary)
            Text(item.spendControl).foregroundStyle(.primary)
            if item.kind == .official,
               let thread = accessModel.officialUsageSnapshot?
                .tokenUsage?.threadUsage {
                officialThreadUsage(thread)
            }
            Text(item.modelCompatibility)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.contextCompatibility)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("证据：\(item.evidenceSource)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                item.refreshedAt.map {
                    "刷新：\($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "刷新：未知"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let profile = relayProfile(for: item) {
                relayPricingStatus(profile)
                Button(
                    usageModel.pricingSnapshot(
                        profileID: profile.id
                    ) == nil ? "设置中转定价" : "更新中转定价"
                ) {
                    pricingProfile = profile
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.body)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    @ViewBuilder
    private func officialThreadUsage(
        _ value: V011OfficialThreadUsage
    ) -> some View {
        let input = value.groups.compactMap(\.inputTokens).reduce(0, +)
        let cached = value.groups.compactMap(\.cachedInputTokens).reduce(0, +)
        let output = value.groups.compactMap(\.outputTokens).reduce(0, +)
        Text(
            "最近任务官方汇总：输入 \(input.formatted()) · 缓存 \(cached.formatted()) · 输出 \(output.formatted())"
        )
        .foregroundStyle(.primary)
        let credits = Double(value.estimatedUsageCreditsMicros)
            / 1_000_000
        let usd = value.estimatedUsageUSDMicros.map {
            Double($0) / 1_000_000
        }
        Text(
            "官方估算：\(credits.formatted(.number.precision(.fractionLength(0...4)))) credits"
                + (usd.map {
                    " · $\($0.formatted(.number.precision(.fractionLength(0...4))))"
                } ?? "")
        )
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func relayPricingStatus(
        _ profile: CodexRelayProfile
    ) -> some View {
        if let pricing = usageModel.pricingSnapshot(
            profileID: profile.id
        ) {
            Text(
                "中转定价：\(pricing.rates.count) 个模型 · \(pricing.currency) · \(pricing.automaticUpdates ? "每日检查、手动应用" : "手动检查")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "定价证据：\(pricing.sourceKind == .remoteManifest ? "远程 JSON" : "用户保存") · \(pricing.checkedAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("中转定价：未知；录入后可计算每次请求费用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relayProfile(
        for item: V011UnifiedResourceItem
    ) -> CodexRelayProfile? {
        guard item.kind == .savedRelay else { return nil }
        return accessModel.savedProfiles.first {
            item.id == "relay:\($0.id)"
        }
    }

    private var latestOfficialThreadID: String? {
        historyModel.recentRows.first {
            $0.currentProvider.caseInsensitiveCompare("openai")
                == .orderedSame
        }?.id
    }

    private func refreshCompletedUsage() {
        usageModel.refresh(
            rows: historyModel.recentRows,
            historyHasMore: historyModel.hasMore,
            officialSnapshot: accessModel.officialUsageSnapshot,
            profiles: accessModel.savedProfiles
        )
    }
}
