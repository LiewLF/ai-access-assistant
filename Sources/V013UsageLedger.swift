import Foundation

struct V013UsageLedgerRecord: Codable, Equatable, Identifiable {
    static let schemaVersion = 1

    let version: Int
    let id: String
    let completedAt: Date
    let recordedAt: Date
    let providerID: String
    let model: String
    let serviceTier: String?
    let accountScopeSHA256: String?
    let identityBoundAtCompletion: Bool
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let billableTokens: Int64
    let originalCredits: Double?
    let originalAPIEquivalentUSD: Double?
    let originalRelayAmount: Double?
    let originalRelayCurrency: String?
    let officialPricing: V013OfficialPricingSnapshot?
    let relayPricing: V012RelayPricingSnapshot?
    let pricingEvidence: String

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
            && (!identityBoundAtCompletion || accountScopeSHA256 != nil)
            && [
                inputTokens,
                cachedInputTokens,
                outputTokens,
                reasoningOutputTokens,
                billableTokens,
            ].allSatisfy { $0 >= 0 }
            && cacheWriteInputTokens.map { value in
                value >= 0
                    && cachedInputTokens + value <= inputTokens
            } != false
            && reasoningOutputTokens <= outputTokens
            && billableTokens == inputTokens + outputTokens
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
    }

    func originalCostResult() -> V012CostResult {
        let official = officialPricing
        let relay = relayPricing
        return V012CostResult(
            credits: originalCredits,
            apiEquivalentUSD: originalAPIEquivalentUSD,
            relayAmount: originalRelayAmount,
            relayCurrency: originalRelayCurrency,
            pricingRevision: official?.revision ?? relay?.revision,
            pricingEvidence: pricingEvidence,
            pricingSourceURL: official?.subscriptionSourceURL
                ?? relay?.sourceURL,
            pricingCheckedAt: official?.checkedAt ?? relay?.checkedAt
        )
    }

    func repriced(
        officialPricing: V013OfficialPricingSnapshot,
        planType: String?
    ) -> V012CostResult {
        V012UsageCostCalculator.calculate(
            calls: [asTokenUsage],
            model: model,
            providerID: providerID,
            planType: planType,
            serviceTier: serviceTier,
            relayPricing: relayPricing,
            officialPricing: officialPricing
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
    ) -> Self {
        Self(
            accountScopeSHA256: snapshot.accountScopeSHA256,
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
    static let schemaVersion = 1

    var schemaVersion: Int
    var records: [V013UsageLedgerRecord]
    var quotaObservations: [V013QuotaLedgerObservation]

    static let empty = Self(
        schemaVersion: schemaVersion,
        records: [],
        quotaObservations: []
    )

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

struct V013UsageLedgerStore {
    static let maximumBytes = 2 * 1024 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: FableAtomicConfigWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        writer: FableAtomicConfigWriter = FableAtomicConfigWriter()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.writer = writer
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
        let value = try decoder.decode(
            V013UsageLedgerState.self,
            from: Data(contentsOf: fileURL)
        )
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
        try writer.write(
            data,
            to: fileURL,
            expectedCurrentHash:
                SessionSyncFileSafety.hashIfPresent(fileURL)
        )
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
    let fullWeekTokens: Double
    let fullWeekCredits: Double?
    let fullWeekAPIEquivalentUSD: Double?
    let lowerWeekTokens: Double?
    let upperWeekTokens: Double?
    let lowerWeekAPIEquivalentUSD: Double?
    let upperWeekAPIEquivalentUSD: Double?
    let resolutionLowerWeekTokens: Double
    let resolutionUpperWeekTokens: Double?
    let observationCount: Int
    let percentageTransitionCount: Int
    let usableIntervalSampleCount: Int
    let confidence: Confidence
    let refreshedAt: Date
    let pricingRevision: String
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
        now: Date
    ) -> V013WeeklyUsageStatus {
        guard let snapshot = officialSnapshot,
              snapshot.isFresh(at: now),
              let window = snapshot.windows.first(where: {
                  $0.durationMinutes == 10_080
              }),
              let resetsAt = window.resetsAt else {
            return unavailable(
                "官方每周窗口未知或已过期",
                observations: [],
                usedPercent: nil,
                supplemental: .empty
            )
        }
        let observations = ledger.quotaObservations.filter {
            $0.accountScopeSHA256 == snapshot.accountScopeSHA256
                && $0.windowMinutes == 10_080
                && abs($0.resetsAt.timeIntervalSince(resetsAt)) <= 60
        }.sorted { $0.observedAt < $1.observedAt }
        let supplemental = V013UsageEvidenceBuilder.build(
            ledger: ledger,
            snapshot: snapshot,
            window: window,
            observations: observations,
            planType: planType,
            pricing: pricing
        )
        guard window.usedPercent > 0 else {
            return unavailable(
                "官方每周已用为 0%，暂不反推满额",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        guard let first = observations.first,
              let latest = observations.last,
              latest.usedPercent == window.usedPercent else {
            return unavailable(
                "官方百分比与本地观察尚未对齐",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        let windowStart = resetsAt.addingTimeInterval(
            -Double(window.durationMinutes ?? 10_080) * 60
        )
        guard first.usedPercent == 0,
              first.observedAt <= windowStart.addingTimeInterval(15 * 60)
        else {
            return unavailable(
                "尚未从本周重置起完整观察，满额 Token 与金额保持未知",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        guard observations.allSatisfy({
            $0.historyCoverageComplete && $0.sourceReadsStable
        }) else {
            return unavailable(
                "本周历史页或正在写入的来源未完整覆盖",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        let currentRecords = ledger.records.filter {
            $0.providerID.caseInsensitiveCompare("openai") == .orderedSame
                && $0.completedAt >= first.observedAt
                && $0.completedAt <= snapshot.observedAt
                && $0.accountScopeSHA256 == snapshot.accountScopeSHA256
        }
        guard !currentRecords.isEmpty else {
            return unavailable(
                "完整窗口内尚无可计量完成请求",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        guard currentRecords.allSatisfy(\.identityBoundAtCompletion) else {
            return unavailable(
                "部分历史请求无法证明与当前账号在完成时匹配",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        let observedTokens = currentRecords.reduce(Int64(0)) {
            $0 + $1.billableTokens
        }
        guard observedTokens > 0 else {
            return unavailable(
                "完整窗口内计费 Token 为 0",
                observations: observations,
                usedPercent: window.usedPercent,
                supplemental: supplemental
            )
        }
        let currentCosts = currentRecords.map {
            $0.repriced(
                officialPricing: pricing,
                planType: planType
            )
        }
        let credits = completeSum(currentCosts.map(\.credits))
        let apiUSD = completeSum(
            currentCosts.map(\.apiEquivalentUSD)
        )
        let fraction = Double(window.usedPercent) / 100
        let resolutionLowerPercent = max(
            0,
            Double(window.usedPercent) - 0.5
        )
        let resolutionUpperPercent = min(
            100,
            Double(window.usedPercent) + 0.5
        )
        let segmentTokens = segmentValues(
            observations: observations,
            records: currentRecords,
            value: { Double($0.billableTokens) }
        )
        let segmentUSD = segmentValues(
            observations: observations,
            records: currentRecords,
            value: {
                $0.repriced(
                    officialPricing: pricing,
                    planType: planType
                ).apiEquivalentUSD
            }
        )
        let confidence: V013WeeklyUsageEstimate.Confidence
        if supplemental.usableIntervalCount >= 3
            && observations.count >= 4 {
            confidence = .high
        } else if supplemental.usableIntervalCount >= 2 {
            confidence = .medium
        } else {
            confidence = .low
        }
        let estimate = V013WeeklyUsageEstimate(
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            observedWindowTokens: observedTokens,
            observedWindowCredits: credits,
            observedWindowAPIEquivalentUSD: apiUSD,
            fullWeekTokens: Double(observedTokens) / fraction,
            fullWeekCredits: credits.map { $0 / fraction },
            fullWeekAPIEquivalentUSD: apiUSD.map { $0 / fraction },
            lowerWeekTokens: bounds(segmentTokens)?.lower,
            upperWeekTokens: bounds(segmentTokens)?.upper,
            lowerWeekAPIEquivalentUSD: bounds(segmentUSD)?.lower,
            upperWeekAPIEquivalentUSD: bounds(segmentUSD)?.upper,
            resolutionLowerWeekTokens:
                Double(observedTokens)
                    / (resolutionUpperPercent / 100),
            resolutionUpperWeekTokens:
                resolutionLowerPercent > 0
                    ? Double(observedTokens)
                        / (resolutionLowerPercent / 100)
                    : nil,
            observationCount: observations.count,
            percentageTransitionCount:
                supplemental.percentageTransitionCount,
            usableIntervalSampleCount:
                supplemental.usableIntervalCount,
            confidence: confidence,
            refreshedAt: snapshot.observedAt,
            pricingRevision: pricing.revision
        )
        return V013WeeklyUsageStatus(
            estimate: estimate,
            reason: "本周窗口、账号与本地账本完整匹配",
            observationCount: observations.count,
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
        observations: [V013QuotaLedgerObservation],
        usedPercent: Int?,
        supplemental: V013SupplementalUsageEvidence
    ) -> V013WeeklyUsageStatus {
        return V013WeeklyUsageStatus(
            estimate: nil,
            reason: reason,
            observationCount: observations.count,
            percentageTransitionCount:
                supplemental.percentageTransitionCount,
            usableIntervalSampleCount:
                supplemental.usableIntervalCount,
            officialUsedPercent: usedPercent,
            supplemental: supplemental
        )
    }

    private static func segmentValues(
        observations: [V013QuotaLedgerObservation],
        records: [V013UsageLedgerRecord],
        value: (V013UsageLedgerRecord) -> Double?
    ) -> [Double] {
        var values: [Double] = []
        for pair in zip(observations, observations.dropFirst()) {
            let delta = pair.1.usedPercent - pair.0.usedPercent
            guard delta > 0 else { continue }
            let segment = records.filter {
                $0.completedAt > pair.0.observedAt
                    && $0.completedAt <= pair.1.observedAt
            }
            let costs = segment.compactMap(value)
            guard costs.count == segment.count, !costs.isEmpty else {
                continue
            }
            values.append(costs.reduce(0, +) * 100 / Double(delta))
        }
        return values
    }

    private static func completeSum(
        _ values: [Double?]
    ) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    private static func bounds(
        _ values: [Double]
    ) -> (lower: Double, upper: Double)? {
        guard values.count >= 2,
              let lower = values.min(),
              let upper = values.max() else { return nil }
        return (lower, upper)
    }
}
