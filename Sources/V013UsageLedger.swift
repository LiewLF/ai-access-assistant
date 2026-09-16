import Foundation

struct V013UsageLedgerRecord: Codable, Equatable, Identifiable {
    static let schemaVersion = 5

    let version: Int
    let id: String
    let completedAt: Date
    let recordedAt: Date
    let providerID: String
    let model: String
    let serviceTier: String?
    let accountScopeSHA256: String?
    let identityBoundAtCompletion: Bool
    /// Legacy records could only prove that an account snapshot followed a
    /// completion. Preserve that fact for explanation, never for arithmetic.
    let legacyPostCompletionAccountScopeSHA256: String?
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let modelProcessedTokens: Int64
    let originalCredits: Double?
    let originalAPIEquivalentUSD: Double?
    let originalRelayAmount: Double?
    let originalRelayCurrency: String?
    let officialPricing: V013OfficialPricingSnapshot?
    let relayPricing: V012RelayPricingSnapshot?
    let pricingEvidence: String
    /// Additive schema-5 field; older records remain readable without invented detail.
    var completedUsage: V012CompletedTurnUsage? = nil

    var isStructurallyValid: Bool {
        version == Self.schemaVersion
            && Self.isSHA256(id)
            && V012ModelTokenRate.safeText(
                providerID,
                maximumBytes: 512
            )
            && V012ModelTokenRate.safeText(model, maximumBytes: 128)
            && serviceTier.map {
                V012ModelTokenRate.safeText($0, maximumBytes: 80)
            } != false
            && accountScopeSHA256.map(Self.isSHA256) != false
            && legacyPostCompletionAccountScopeSHA256.map(Self.isSHA256) != false
            && (!identityBoundAtCompletion || accountScopeSHA256 != nil)
            && !(identityBoundAtCompletion
                && legacyPostCompletionAccountScopeSHA256 != nil)
            && !(accountScopeSHA256 != nil
                && legacyPostCompletionAccountScopeSHA256 != nil)
            && [
                inputTokens,
                cachedInputTokens,
                outputTokens,
                reasoningOutputTokens,
                modelProcessedTokens,
            ].allSatisfy { $0 >= 0 }
            && cacheWriteInputTokens.map { value in
                value >= 0
                    && cachedInputTokens + value <= inputTokens
            } != false
            && reasoningOutputTokens <= outputTokens
            && modelProcessedTokens == inputTokens + outputTokens
            && [
                originalCredits,
                originalAPIEquivalentUSD,
                originalRelayAmount,
            ].allSatisfy { $0.map(Self.safeAmount) != false }
            && originalRelayCurrency.map {
                !$0.isEmpty && $0.utf8.count <= 12
            } != false
            && officialPricing.map(\.isStructurallyValid) != false
            && relayPricing.map(\.isStructurallyValid) != false
            && V012ModelTokenRate.safeText(
                pricingEvidence,
                maximumBytes: 512
            )
            && completedUsage.map { usage in
                usage.id == id && usage.model == model && usage.providerID == providerID
                    && abs(usage.completedAt.timeIntervalSince(completedAt)) <= 1
                    && !usage.calls.isEmpty && usage.calls.count <= 512
                    && usage.calls.allSatisfy(\.isStructurallyValid)
                    && usage.inputTokens == inputTokens && usage.outputTokens == outputTokens
                    && usage.officialRequestPricing.map { evidence in
                        evidence.matches(usage) && (!identityBoundAtCompletion
                            || evidence.accountScopeSHA256 == accountScopeSHA256)
                    } != false
            } != false
    }

    func originalCostResult() -> V012CostResult {
        let official = officialPricing
        let relay = relayPricing
        return V012CostResult(
            credits: originalCredits,
            apiEquivalentUSD: originalAPIEquivalentUSD,
            relayAmount: originalRelayAmount,
            relayCurrency: originalRelayCurrency,
            pricingEvidence: pricingEvidence,
            pricingSourceURL: official?.subscriptionSourceURL
                ?? relay?.sourceURL,
            pricingCheckedAt: official?.checkedAt ?? relay?.checkedAt
        )
    }

    func repriced(
        officialPricing: V013OfficialPricingSnapshot,
        planType: String?,
        apiPricingPolicy: V013APIPricingPolicy = .recordedTier
    ) -> V012CostResult {
        V012UsageCostCalculator.calculate(
            calls: completedUsage?.calls ?? [asTokenUsage],
            model: completedUsage?.pricingModel ?? model,
            providerID: providerID,
            planType: planType,
            serviceTier: completedUsage?.pricingServiceTier ?? serviceTier,
            relayPricing: relayPricing,
            officialPricing: officialPricing,
            requestBoundariesKnown: completedUsage.map {
                $0.containsOnlyTurnTotals != true
            } ?? false,
            apiPricingPolicy: apiPricingPolicy
        )
    }

    private var asTokenUsage: V012UpstreamTokenUsage {
        V012UpstreamTokenUsage(
            observedAt: completedAt,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            activeContextTokens: nil,
            rateLimit: nil,
            creditBalance: nil
        )
    }

    private static func safeAmount(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1_000_000_000_000
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        }
    }
}

struct V013QuotaLedgerObservation: Codable, Equatable, Identifiable {
    let accountScopeSHA256: String
    let usedPercent: Int
    let windowMinutes: Int
    let resetsAt: Date
    let observedAt: Date
    let historyCoverageComplete: Bool
    let sourceReadsStable: Bool
    let officialLifetimeTokens: Int64?
    let officialUsageEffectiveThrough: Date?

    init(
        accountScopeSHA256: String,
        usedPercent: Int,
        windowMinutes: Int,
        resetsAt: Date,
        observedAt: Date,
        historyCoverageComplete: Bool,
        sourceReadsStable: Bool,
        officialLifetimeTokens: Int64? = nil,
        officialUsageEffectiveThrough: Date? = nil
    ) {
        self.accountScopeSHA256 = accountScopeSHA256
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.historyCoverageComplete = historyCoverageComplete
        self.sourceReadsStable = sourceReadsStable
        self.officialLifetimeTokens = officialLifetimeTokens
        self.officialUsageEffectiveThrough = officialUsageEffectiveThrough
    }

    var id: String {
        "\(accountScopeSHA256)|\(Int(resetsAt.timeIntervalSince1970))|\(Int(observedAt.timeIntervalSince1970))"
    }

    var isStructurallyValid: Bool {
        accountScopeSHA256.count == 64
            && accountScopeSHA256.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && (0...100).contains(usedPercent)
            && windowMinutes > 0
            && resetsAt > observedAt
            && officialLifetimeTokens.map { $0 >= 0 } != false
            && officialUsageEffectiveThrough.map { $0 <= observedAt } != false
    }

    static func current(
        snapshot: V011OfficialUsageSnapshot,
        window: V011OfficialUsageWindow,
        resetsAt: Date,
        historyCoverageComplete: Bool,
        sourceReadsStable: Bool
    ) -> Self? {
        guard let scope = snapshot.accountScopeSHA256 else {
            return nil
        }
        return Self(
            accountScopeSHA256: scope,
            usedPercent: window.usedPercent,
            windowMinutes: 10_080,
            resetsAt: resetsAt,
            observedAt: snapshot.observedAt,
            historyCoverageComplete: historyCoverageComplete,
            sourceReadsStable: sourceReadsStable,
            officialLifetimeTokens:
                snapshot.tokenUsage?.summary.lifetimeTokens,
            officialUsageEffectiveThrough: nil
        )
    }
}

struct V013UsageLedgerState: Codable, Equatable {
    static let schemaVersion = 5

    var schemaVersion: Int
    var records: [V013UsageLedgerRecord]
    var quotaObservations: [V013QuotaLedgerObservation]

    static let empty = Self(
        schemaVersion: schemaVersion,
        records: [],
        quotaObservations: []
    )

    mutating func record(_ observation: V013QuotaLedgerObservation) {
        guard let index = quotaObservations.firstIndex(where: { $0.id == observation.id }) else {
            quotaObservations.append(observation)
            return
        }
        // Revisiting a cached snapshot must not erase an earlier complete read.
        let existing = quotaObservations[index]
        if existing.historyCoverageComplete && existing.sourceReadsStable,
           !(observation.historyCoverageComplete && observation.sourceReadsStable) { return }
        quotaObservations[index] = observation
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && records.count <= 2_000
            && quotaObservations.count <= 400
            && records.allSatisfy(\.isStructurallyValid)
            && quotaObservations.allSatisfy(\.isStructurallyValid)
            && Set(records.map(\.id)).count == records.count
            && Set(quotaObservations.map(\.id)).count
                == quotaObservations.count
    }
}

private struct V013UsageLedgerEnvelope: Decodable {
    let schemaVersion: Int
}

private struct V013LegacyUsageLedgerState: Decodable {
    let schemaVersion: Int
    let records: [V013LegacyUsageLedgerRecord]
    let quotaObservations: [V013QuotaLedgerObservation]?
}

private struct V013LegacyUsageLedgerRecord: Decodable {
    let id: String
    let completedAt: Date
    let recordedAt: Date
    let providerID: String
    let model: String
    let serviceTier: String?
    let accountScopeSHA256: String?
    let identityBoundAtCompletion: Bool?
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let modelProcessedTokens: Int64?
    let billableTokens: Int64?
    let originalCredits: Double?
    let originalAPIEquivalentUSD: Double?
    let originalRelayAmount: Double?
    let originalRelayCurrency: String?
    let pricingEvidence: String

    func migrated(
        identityBound: Bool,
        legacyPostCompletionScope: String?
    ) -> V013UsageLedgerRecord {
        let migratedID = id.count == 64
            && id.allSatisfy({
                $0.isHexDigit && !$0.isUppercase
            })
            ? id
            : V011AgentLoopReceipt.sha256(Data(id.utf8))
        return V013UsageLedgerRecord(
            version: V013UsageLedgerRecord.schemaVersion,
            id: migratedID,
            completedAt: completedAt,
            recordedAt: recordedAt,
            providerID: providerID,
            model: model,
            serviceTier: serviceTier,
            accountScopeSHA256: identityBound ? accountScopeSHA256 : nil,
            identityBoundAtCompletion: identityBound,
            legacyPostCompletionAccountScopeSHA256:
                legacyPostCompletionScope,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            modelProcessedTokens:
                modelProcessedTokens ?? billableTokens
                    ?? (inputTokens + outputTokens),
            originalCredits: originalCredits,
            originalAPIEquivalentUSD: originalAPIEquivalentUSD,
            originalRelayAmount: originalRelayAmount,
            originalRelayCurrency: originalRelayCurrency,
            officialPricing: nil,
            relayPricing: nil,
            pricingEvidence: pricingEvidence
        )
    }
}

struct V013UsageLedgerStore {
    static let maximumBytes = 16 * 1024 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: V011ReceiptFileWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        writer = V011ReceiptFileWriter(fileManager: fileManager)
    }

    func load() throws -> V013UsageLedgerState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBytes else {
            throw V012PricingError.invalidValue
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(
            V013UsageLedgerEnvelope.self,
            from: data
        )
        let value: V013UsageLedgerState
        if envelope.schemaVersion == V013UsageLedgerState.schemaVersion {
            value = try decoder.decode(
                V013UsageLedgerState.self,
                from: data
            )
        } else if [1, 2, 3, 4].contains(envelope.schemaVersion) {
            let legacy = try decoder.decode(
                V013LegacyUsageLedgerState.self,
                from: data
            )
            let observations = legacy.quotaObservations ?? []
            let migratedRecords = legacy.records.map { record in
                let hadPostCompletionObservation =
                    record.identityBoundAtCompletion == true
                    && record.accountScopeSHA256 != nil
                let identityBound = hadPostCompletionObservation
                    && record.accountScopeSHA256.map { scope in
                        V013UsageIdentityEvidence.isTrustedCompletion(
                            completedAt: record.completedAt,
                            accountScope: scope,
                            observations: observations
                        )
                    } == true
                return record.migrated(
                    identityBound: identityBound,
                    legacyPostCompletionScope:
                        hadPostCompletionObservation && !identityBound
                        ? record.accountScopeSHA256 : nil
                )
            }
            let deduplicatedRecords = Dictionary(
                migratedRecords.map { ($0.id, $0) },
                uniquingKeysWith: { lhs, rhs in
                    lhs.recordedAt >= rhs.recordedAt ? lhs : rhs
                }
            ).values.sorted { $0.completedAt > $1.completedAt }
            value = V013UsageLedgerState(
                schemaVersion: V013UsageLedgerState.schemaVersion,
                records: deduplicatedRecords,
                quotaObservations: observations
            )
        } else {
            throw V012PricingError.invalidValue
        }
        guard value.isStructurallyValid else {
            throw V012PricingError.invalidValue
        }
        return value
    }

    func commit(_ value: V013UsageLedgerState) throws {
        guard value.isStructurallyValid else {
            throw V012PricingError.invalidValue
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else {
            throw V012PricingError.responseTooLarge
        }
        try writer.write(data, to: fileURL)
    }
}

enum V013UsageIdentityEvidence {
    static func isTrustedCompletion(
        completedAt: Date,
        accountScope: String,
        observations: [V013QuotaLedgerObservation]
    ) -> Bool {
        let matching = observations.filter {
            $0.accountScopeSHA256 == accountScope
                && $0.windowMinutes == 10_080
                && $0.historyCoverageComplete
                && $0.sourceReadsStable
                && completedAt >= $0.resetsAt.addingTimeInterval(-10_080 * 60)
                && completedAt <= $0.resetsAt
        }.sorted { $0.observedAt < $1.observedAt }
        for following in matching where
            following.observedAt >= completedAt
                && following.observedAt.timeIntervalSince(completedAt)
                    <= V011OfficialUsageSnapshot.freshnessLifetime
        {
            guard let preceding = matching.last(where: {
                abs($0.resetsAt.timeIntervalSince(following.resetsAt)) <= 60
                    && $0.observedAt <= completedAt
                    && completedAt.timeIntervalSince($0.observedAt)
                        <= V011OfficialUsageSnapshot.freshnessLifetime
            }) else { continue }
            let sawOtherAccount = observations.contains {
                $0.accountScopeSHA256 != accountScope
                    && $0.observedAt >= preceding.observedAt
                    && $0.observedAt <= following.observedAt
            }
            if !sawOtherAccount { return true }
        }
        return false
    }
}

struct V013WeeklyUsageEstimate: Equatable {
    enum Confidence: String { case low = "低", medium = "中", high = "高" }

    static let monthlyEquivalentFactor = 4.348125

    let usedPercent: Int
    let resetsAt: Date
    let observedWindowTokens: Int64
    let observedWindowCredits: Double?
    let observedWindowAPIEquivalentUSD: Double?
    let pointWeekTokens: Double
    let lowerWeekTokens: Double
    let upperWeekTokens: Double
    let pointWeekCredits: Double?
    let lowerWeekCredits: Double?
    let upperWeekCredits: Double?
    let pointWeekAPIEquivalentUSD: Double?
    let lowerWeekAPIEquivalentUSD: Double?
    let upperWeekAPIEquivalentUSD: Double?
    let observationCount: Int
    let percentageTransitionCount: Int
    let usableIntervalSampleCount: Int
    let confidence: Confidence
    let apiIntervalSampleCount: Int
    let creditsIntervalSampleCount: Int
    let refreshedAt: Date
    let pricingSnapshotID: String
}

struct V013WeeklyUsageStatus: Equatable {
    let estimate: V013WeeklyUsageEstimate?
    let reason: String
    let observationCount: Int
    let percentageTransitionCount: Int
    let usableIntervalSampleCount: Int
    let officialUsedPercent: Int?
    let supplemental: V013SupplementalUsageEvidence

    static let notRead = Self(
        estimate: nil,
        reason: "尚未读取官方每周窗口与完整本地账本",
        observationCount: 0,
        percentageTransitionCount: 0,
        usableIntervalSampleCount: 0,
        officialUsedPercent: nil,
        supplemental: .empty
    )
}

enum V013WeeklyUsageEstimator {
    static func evaluate(
        ledger: V013UsageLedgerState,
        officialSnapshot: V011OfficialUsageSnapshot?,
        planType: String?,
        pricing: V013OfficialPricingSnapshot = .current,
        now: Date,
        turns: [V012CompletedTurnUsage] = [],
        historyCoverageComplete: Bool = false,
        sourceReadsStable: Bool = false,
        cpaSnapshots: [V013CPARawUsageSnapshot] = [],
        apiPricingPolicy: V013APIPricingPolicy = .recordedTier
    ) -> V013WeeklyUsageStatus {
        guard let snapshot = officialSnapshot,
              snapshot.isFresh(at: now) else {
            return unavailable(
                "官方每周窗口未知或已过期",
                usedPercent: nil,
                supplemental: .empty
            )
        }
        let weeklyWindows = snapshot.windows.filter {
            $0.durationMinutes == 10_080
        }
        guard weeklyWindows.count == 1,
              let window = weeklyWindows.first,
              let resetsAt = window.resetsAt,
              resetsAt > snapshot.observedAt else {
            return unavailable(
                "官方每周窗口缺失、歧义或重置时间无效",
                usedPercent: nil,
                supplemental: .empty
            )
        }
        let observations = ledger.quotaObservations.filter {
            $0.accountScopeSHA256 == snapshot.accountScopeSHA256
                && $0.windowMinutes == 10_080
                && abs($0.resetsAt.timeIntervalSince(resetsAt)) <= 60
        }.sorted { $0.observedAt < $1.observedAt }
        var supplemental = V013UsageEvidenceBuilder.build(
            ledger: ledger,
            snapshot: snapshot,
            window: window,
            observations: observations,
            turns: turns,
            historyCoverageComplete: historyCoverageComplete,
            sourceReadsStable: sourceReadsStable,
            planType: planType,
            pricing: pricing,
            apiPricingPolicy: apiPricingPolicy
        )
        // Choose one independent source; empty or incomplete captures must not
        // displace a complete native interval. Never add captured and native totals.
        if let selected = V013CPAEvidenceSelection.evaluate(
            snapshots: cpaSnapshots, officialSnapshot: snapshot,
            window: window, pricing: pricing, now: now, nativeEvaluation: supplemental.cpaQuota
        ) {
            supplemental = V013SupplementalUsageEvidence(
                observed: supplemental.observed,
                officialActivity: supplemental.officialActivity,
                currentEquivalentCapacity: supplemental.currentEquivalentCapacity,
                cpaQuota: selected,
                historicalEquivalentCapacity: supplemental.historicalEquivalentCapacity,
                percentageTransitionCount: selected.percentageTransitionCount,
                usableIntervalCount: selected.usableIntervalCount
            )
        }
        guard let cpa = supplemental.cpaQuota.estimate else {
            return unavailable(
                supplemental.cpaQuota.reason,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        let estimate = V013WeeklyUsageEstimate(
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            observedWindowTokens: cpa.observedTokens,
            observedWindowCredits: cpa.observedCredits,
            observedWindowAPIEquivalentUSD:
                cpa.observedAPIEquivalentUSD,
            pointWeekTokens: cpa.pointFullWindowTokens,
            lowerWeekTokens: cpa.lowerFullWindowTokens,
            upperWeekTokens: cpa.upperFullWindowTokens,
            pointWeekCredits: cpa.pointFullWindowCredits,
            lowerWeekCredits: cpa.lowerFullWindowCredits,
            upperWeekCredits: cpa.upperFullWindowCredits,
            pointWeekAPIEquivalentUSD:
                cpa.pointFullWindowAPIEquivalentUSD,
            lowerWeekAPIEquivalentUSD:
                cpa.lowerFullWindowAPIEquivalentUSD,
            upperWeekAPIEquivalentUSD:
                cpa.upperFullWindowAPIEquivalentUSD,
            observationCount:
                supplemental.cpaQuota.observationCount,
            percentageTransitionCount:
                supplemental.percentageTransitionCount,
            usableIntervalSampleCount:
                supplemental.usableIntervalCount,
            confidence: cpa.confidence,
            apiIntervalSampleCount: cpa.apiIntervalSampleCount,
            creditsIntervalSampleCount: cpa.creditsIntervalSampleCount,
            refreshedAt: snapshot.observedAt,
            pricingSnapshotID: pricing.id
        )
        return V013WeeklyUsageStatus(
            estimate: estimate,
            reason: supplemental.cpaQuota.reason,
            observationCount:
                supplemental.cpaQuota.observationCount,
            percentageTransitionCount:
                supplemental.percentageTransitionCount,
            usableIntervalSampleCount:
                supplemental.usableIntervalCount,
            officialUsedPercent: window.usedPercent,
            supplemental: supplemental
        )
    }

    private static func unavailable(
        _ reason: String,
        usedPercent: Int?,
        supplemental: V013SupplementalUsageEvidence
    ) -> V013WeeklyUsageStatus {
        return V013WeeklyUsageStatus(
            estimate: nil,
            reason: reason,
            observationCount: supplemental.cpaQuota.observationCount,
            percentageTransitionCount:
                supplemental.percentageTransitionCount,
            usableIntervalSampleCount:
                supplemental.usableIntervalCount,
            officialUsedPercent: usedPercent,
            supplemental: supplemental
        )
    }
}
