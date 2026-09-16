import Foundation

/// Converts identity-bound CPA request rows into the shared interval engine.
/// CPA timestamps remain request observations; this adapter never invents a
/// completed-turn boundary or combines rows into one pricing request.
enum V013CPAEvidenceAdapter {
    static func evaluate(
        raw: V013CPARawUsageSnapshot,
        officialSnapshot: V011OfficialUsageSnapshot,
        window: V011OfficialUsageWindow,
        pricing: V013OfficialPricingSnapshot = .current,
        now: Date? = nil
    ) -> V013CPAQuotaEvaluation {
        guard !raw.expectedOfficialAccountScopeSHA256.isEmpty,
              officialSnapshot.accountScopeSHA256
                == raw.expectedOfficialAccountScopeSHA256 else {
            return unavailable("CPA 凭据与官方账号身份范围不一致，调用级配额样本不可绑定")
        }

        let weeklyWindows = officialSnapshot.windows.filter {
            $0.durationMinutes == 10_080 && $0.resetsAt != nil
        }
        guard weeklyWindows.count == 1,
              let officialWindow = weeklyWindows.first,
              window.durationMinutes == officialWindow.durationMinutes,
              window.usedPercent == officialWindow.usedPercent,
              let resetsAt = officialWindow.resetsAt,
              let requestedReset = window.resetsAt,
              abs(requestedReset.timeIntervalSince(resetsAt)) <= 60 else {
            return unavailable("官方周窗口不唯一或与请求窗口不一致，调用级配额样本暂不可用")
        }

        let windowStart = resetsAt.addingTimeInterval(-10_080 * 60)
        // Fresh account metadata binds the window; later request headers carry
        // their own quota observation. Do not hide new rows until another RPC.
        let observedThrough = min(now ?? officialSnapshot.observedAt, resetsAt)
        guard observedThrough >= windowStart else {
            return unavailable("官方周窗口观察时间无效，调用级配额样本暂不可用")
        }

        let orderedRecords = raw.records.enumerated().sorted { left, right in
            switch (left.element.rowID, right.element.rowID) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            default:
                return left.offset < right.offset
            }
        }.map(\.element)
        let recordRowIDs = Set(orderedRecords.compactMap(\.rowID))
        let unrepresentedIssues = raw.issues.filter {
            $0.rowID.map { !recordRowIDs.contains($0) } ?? true
        }
        guard !orderedRecords.contains(where: { $0.rowID == nil }),
              !unrepresentedIssues.contains(where: { $0.rowID == nil }) else {
            return unavailable("CPA 原始记录缺少稳定行序，无法在不可定位缺口后恢复区间")
        }

        let unlocatableRecordIDs = orderedRecords.compactMap { record -> Int64? in
            record.observedAt == nil ? record.rowID : nil
        }
        let unrepresentedIssueIDs = unrepresentedIssues.compactMap(\.rowID)
        let unlocatableCutoff = (unlocatableRecordIDs + unrepresentedIssueIDs).max()
        let retainedRecords = orderedRecords.filter {
            guard let cutoff = unlocatableCutoff, let rowID = $0.rowID else {
                return true
            }
            return rowID > cutoff
        }

        var calls: [V013CPAIntervalCall] = []
        var ordinal = 0
        var foreignWeeklyCallCount = 0
        var sawLocatableGap = false
        for record in retainedRecords {
            guard let observedAt = record.observedAt,
                  observedAt >= windowStart,
                  observedAt <= observedThrough else { continue }
            defer { ordinal += 1 }

            let primary = rateLimit(
                percent: record.usedPercent,
                resetsAt: record.resetAt,
                windowMinutes: record.windowMinutes,
                observedAt: observedAt
            )
            let secondary = rateLimit(
                percent: record.secondaryUsedPercent,
                resetsAt: record.secondaryResetAt,
                windowMinutes: record.secondaryWindowMinutes,
                observedAt: observedAt
            )
            let weeklyCandidates = [primary, secondary].compactMap { $0 }
                .filter(\.isWeekly)
            let weekly = V012RateLimitObservation.weekly(
                fromPrimary: primary,
                secondary: secondary
            )
            let quotaFieldsMalformed = hasMalformedQuotaFields(record)
                || weeklyCandidates.count > 1
            let usageIsValid = isValidUsage(record)
                && !quotaFieldsMalformed
            let binding: V013CPAIntervalBinding
            if record.expectedOfficialAccountScopeSHA256
                != raw.expectedOfficialAccountScopeSHA256 {
                binding = .otherAccount
            } else if usageIsValid {
                binding = .matchingAccount
            } else {
                binding = .unbound
                sawLocatableGap = true
            }

            if usageIsValid, let weekly,
               abs(weekly.resetsAt.timeIntervalSince(resetsAt)) > 60 {
                foreignWeeklyCallCount += 1
                continue
            }

            let usage = usageIsValid ? upstreamUsage(record, observedAt: observedAt) : nil
            let cost = usage.flatMap { usage -> V012CostResult? in
                let model = pricingModel(record)
                let tier = pricingTier(record)
                return V012UsageCostCalculator.calculate(
                    calls: [usage],
                    model: model ?? "",
                    providerID: "openai",
                    planType: officialSnapshot.planType,
                    serviceTier: tier,
                    relayPricing: nil,
                    officialPricing: pricing,
                    requestBoundariesKnown: true
                )
            }
            let milestone = usageIsValid && weekly.map({
                abs($0.resetsAt.timeIntervalSince(resetsAt)) <= 60
            }) == true ? weekly?.usedPercent : nil
            calls.append(
                V013CPAIntervalCall(
                    ordinal: ordinal,
                    observedAt: observedAt,
                    tokens: usageIsValid ? (record.totalTokens ?? 0) : 0,
                    credits: cost?.credits,
                    apiEquivalentUSD: cost?.apiEquivalentUSD,
                    milestonePercent: milestone,
                    binding: binding,
                    weeklyBoundaryAligned: !quotaFieldsMalformed
                )
            )
        }

        let notices = [
            unlocatableCutoff.map {
                "已在最后一个不可定位 CPA 缺口（行 \($0)）后重新积累区间"
            },
            sawLocatableGap ? "可定位的失败或损坏请求仅隔离其所在区间" : nil,
        ].compactMap { $0 }
        return V013CPAIntervalEngine.evaluate(
            calls: calls,
            resetsAt: resetsAt,
            foreignWeeklyCallCount: foreignWeeklyCallCount,
            legacyNotice: notices.isEmpty ? nil : notices.joined(separator: "；")
        )
    }

    private static func unavailable(_ reason: String) -> V013CPAQuotaEvaluation {
        V013CPAQuotaEvaluation(
            estimate: nil,
            partialCapacity: nil,
            reason: reason,
            observationCount: 0,
            percentageTransitionCount: 0,
            usableIntervalCount: 0
        )
    }

    private static func isValidUsage(_ record: V013CPARawUsageRecord) -> Bool {
        guard record.provider == "codex", record.quotaScope == "main",
              record.failed == false,
              record.statusCode.map({ $0 == 0 || (200..<400).contains($0) }) == true,
              record.requestedAtEpochSeconds.map({ $0 > 0 }) == true,
              let requestedAt = record.requestedAt,
              let observedAt = record.observedAt,
              observedAt >= requestedAt else { return false }
        return record.hasConsistentTokenCounts
    }

    private static func hasMalformedQuotaFields(
        _ record: V013CPARawUsageRecord
    ) -> Bool {
        (record.usedPercent != nil && rateLimit(
            percent: record.usedPercent,
            resetsAt: record.resetAt,
            windowMinutes: record.windowMinutes,
            observedAt: record.observedAt ?? .distantPast
        ) == nil) || (record.secondaryUsedPercent != nil && rateLimit(
            percent: record.secondaryUsedPercent,
            resetsAt: record.secondaryResetAt,
            windowMinutes: record.secondaryWindowMinutes,
            observedAt: record.observedAt ?? .distantPast
        ) == nil)
    }

    private static func rateLimit(
        percent: Double?,
        resetsAt: Date?,
        windowMinutes: Int64?,
        observedAt: Date
    ) -> V012RateLimitObservation? {
        guard let percent, percent.isFinite, (0...100).contains(percent),
              let resetsAt, resetsAt.timeIntervalSince1970 > 0,
              let windowMinutes, let minutes = Int(exactly: windowMinutes),
              minutes > 0 else { return nil }
        return V012RateLimitObservation(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private static func upstreamUsage(
        _ record: V013CPARawUsageRecord,
        observedAt: Date
    ) -> V012UpstreamTokenUsage {
        V012UpstreamTokenUsage(
            observedAt: observedAt,
            inputTokens: record.inputTokens ?? 0,
            cachedInputTokens: record.cacheReadTokens ?? 0,
            cacheWriteInputTokens: record.cacheWriteTokens,
            outputTokens: record.outputTokens ?? 0,
            reasoningOutputTokens: record.reasoningTokens ?? 0,
            activeContextTokens: nil,
            rateLimit: nil,
            creditBalance: nil
        )
    }

    private static func pricingModel(_ record: V013CPARawUsageRecord) -> String? {
        nonempty(record.responseModel) ?? nonempty(record.model)
    }

    private static func pricingTier(_ record: V013CPARawUsageRecord) -> String? {
        if V013OfficialPricingSnapshot.normalizedTier(record.serviceTier) == "fast" {
            return "fast"
        }
        if let response = V013OfficialPricingSnapshot.normalizedTier(
            record.responseServiceTier
        ) {
            return response
        }
        let requested = record.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard requested == "default" || requested == "standard" else {
            return nil
        }
        return V013OfficialPricingSnapshot.normalizedTier(requested)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
