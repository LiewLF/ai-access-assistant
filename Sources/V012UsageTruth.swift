import Combine
import Foundation

struct V012RolloutUsageReader: Sendable {
    private struct Settings {
        var model = "unknown"
        var providerID = "unknown"
        var serviceTier: String?
    }

    private struct Builder {
        let rawTurnID: String
        let startedAt: Date
        var settings: Settings
        var calls: [V012UpstreamTokenUsage] = []
        var cumulativeUsage: [String: Int64]?
    }

    let maximumTurns: Int
    let maximumCallsPerTurn: Int
    let lineReader: RolloutSessionReader

    init(
        maximumTurns: Int = 2_000,
        maximumCallsPerTurn: Int = 512,
        lineReader: RolloutSessionReader = RolloutSessionReader()
    ) {
        self.maximumTurns = maximumTurns
        self.maximumCallsPerTurn = maximumCallsPerTurn
        self.lineReader = lineReader
    }

    func read(
        at url: URL,
        fallbackProviderID: String
    ) throws -> V012UsageReadResult {
        try lineReader.validate(url)
        let before = try identity(url)
        var settings = Settings(providerID: fallbackProviderID)
        var contextByTurn: [String: Settings] = [:]
        var active: Builder?
        var turns: [V012CompletedTurnUsage] = []
        var overflowed = false
        try lineReader.forEachLine(at: url) { data in
            guard let object = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any] else {
                return
            }
            if type == "turn_context" {
                guard let turnID = safeText(payload["turn_id"]),
                      let model = safeText(payload["model"]) else {
                    return
                }
                var value = settings
                value.model = model
                value.serviceTier = safeText(payload["service_tier"])
                    ?? settings.serviceTier
                contextByTurn[turnID] = value
                if active?.rawTurnID == turnID {
                    active?.settings = value
                }
                return
            }
            guard type == "event_msg",
                  let event = payload["type"] as? String else {
                return
            }
            switch event {
            case "thread_settings_applied":
                if let raw = payload["thread_settings"]
                    as? [String: Any] {
                    settings.model = safeText(raw["model"])
                        ?? settings.model
                    settings.providerID = safeText(
                        raw["model_provider_id"]
                    ) ?? settings.providerID
                    settings.serviceTier = safeText(
                        raw["service_tier"]
                    )
                }
            case "task_started":
                guard let turnID = safeText(payload["turn_id"]),
                      let seconds = number(payload["started_at"])
                        ?? parseDate(object["timestamp"])?.timeIntervalSince1970,
                      seconds > 0 else { return }
                active = Builder(
                    rawTurnID: turnID,
                    startedAt: Date(timeIntervalSince1970: seconds),
                    settings: contextByTurn[turnID] ?? settings
                )
            case "token_count":
                guard var value = active else { return }
                let info = payload["info"] as? [String: Any]
                let cumulative = (info?["total_token_usage"] as? [String: Any])?
                    .compactMapValues(integer)
                if let cumulative, cumulative == value.cumulativeUsage {
                    // Rate-limit notifications may repeat the last usage snapshot.
                    return
                }
                guard value.calls.count < maximumCallsPerTurn else {
                    throw V012RolloutUsageError.malformedUsage
                }
                guard let call = try parseCall(
                    payload,
                    object: object
                ) else { return }
                value.calls.append(call)
                value.cumulativeUsage = cumulative
                active = value
            case "task_complete":
                guard let value = active,
                      let turnID = safeText(payload["turn_id"]),
                      turnID == value.rawTurnID,
                      !value.calls.isEmpty,
                      let completed = number(payload["completed_at"])
                        ?? parseDate(object["timestamp"])?.timeIntervalSince1970,
                      completed >= value.startedAt
                        .timeIntervalSince1970 else { return }
                let duration = optionalNonnegativeInteger(
                    payload["duration_ms"]
                )
                let firstToken = optionalNonnegativeInteger(
                    payload["time_to_first_token_ms"]
                )
                turns.append(
                    V012CompletedTurnUsage(
                        id: V011AgentLoopReceipt.sha256(
                            Data(turnID.utf8)
                        ),
                        startedAt: value.startedAt,
                        completedAt: Date(
                            timeIntervalSince1970: completed
                        ),
                        durationMilliseconds: duration,
                        timeToFirstTokenMilliseconds: firstToken,
                        model: value.settings.model,
                        providerID: value.settings.providerID,
                        serviceTier: value.settings.serviceTier,
                        calls: value.calls
                    )
                )
                if turns.count > maximumTurns {
                    overflowed = true
                    turns.removeFirst(turns.count - maximumTurns)
                }
                active = nil
            default:
                break
            }
        }
        let after = try identity(url)
        return V012UsageReadResult(
            turns: turns.sorted { $0.completedAt > $1.completedAt },
            sourceChangedDuringRead: before != after,
            overflowed: overflowed
        )
    }

    private func parseCall(
        _ payload: [String: Any],
        object: [String: Any]
    ) throws -> V012UpstreamTokenUsage? {
        guard let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"]
                as? [String: Any],
              let observedAt = parseDate(object["timestamp"])
        else { return nil }
        let value = V012UpstreamTokenUsage(
            observedAt: observedAt,
            inputTokens: try requiredInteger(
                usage["input_tokens"]
            ),
            cachedInputTokens: try requiredInteger(
                usage["cached_input_tokens"]
            ),
            cacheWriteInputTokens: optionalNonnegativeInteger(
                usage["cache_write_input_tokens"]
            ),
            outputTokens: try requiredInteger(
                usage["output_tokens"]
            ),
            reasoningOutputTokens: try requiredInteger(
                usage["reasoning_output_tokens"]
            ),
            activeContextTokens: optionalNonnegativeInteger(
                usage["total_tokens"]
            ),
            rateLimit: parseRateLimit(
                payload["rate_limits"],
                observedAt: observedAt
            ),
            creditBalance: ((payload["rate_limits"]
                as? [String: Any])?["credits"]
                as? [String: Any])?["balance"] as? String
        )
        guard value.isStructurallyValid else {
            throw V012RolloutUsageError.malformedUsage
        }
        return value
    }

    private func parseRateLimit(
        _ raw: Any?,
        observedAt: Date
    ) -> V012RateLimitObservation? {
        guard let object = raw as? [String: Any] else { return nil }
        let primary = parseRateLimitGroup(
            object["primary"],
            observedAt: observedAt
        )
        let secondary = parseRateLimitGroup(
            object["secondary"],
            observedAt: observedAt
        )
        return V012RateLimitObservation.weekly(
            fromPrimary: primary,
            secondary: secondary
        )
    }

    private func parseRateLimitGroup(
        _ raw: Any?,
        observedAt: Date
    ) -> V012RateLimitObservation? {
        guard let group = raw as? [String: Any],
              let used = number(group["used_percent"]),
              let minutes = integer(group["window_minutes"]),
              let reset = number(group["resets_at"]),
              used >= 0,
              used <= 100,
              minutes > 0,
              reset > 0 else { return nil }
        let resetsAt = Date(timeIntervalSince1970: reset)
        guard resetsAt > observedAt else { return nil }
        return V012RateLimitObservation(
            usedPercent: used,
            windowMinutes: Int(minutes),
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private func identity(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        return "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }

    private func requiredInteger(_ value: Any?) throws -> Int64 {
        guard let result = integer(value), result >= 0 else {
            throw V012RolloutUsageError.malformedUsage
        }
        return result
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded() == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private func optionalNonnegativeInteger(
        _ value: Any?
    ) -> Int64? {
        guard let result = integer(value), result >= 0 else {
            return nil
        }
        return result
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func safeText(_ value: Any?) -> String? {
        guard let text = value as? String,
              V012ModelTokenRate.safeText(
                  text,
                  maximumBytes: 512
              ) else { return nil }
        return text
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: text)
            ?? ISO8601DateFormatter().date(from: text)
    }
}

@MainActor
final class V012UsageTruthModel: ObservableObject {
    @Published private var evidenceTurns: [V012CompletedTurnUsage] = []
    var turns: [V012CompletedTurnUsage] { Array(evidenceTurns.prefix(80)) }
    var weeklyUsageStatus: V013WeeklyUsageStatus { usagePresentation?.strict ?? .notRead }
    @Published private(set) var usagePresentation: V013UsagePresentation?
    @Published private(set) var pricingSnapshots: [String: V012RelayPricingSnapshot] = [:]
    @Published private(set) var pendingPricingSnapshots: [String: V012RelayPricingSnapshot] = [:]
    @Published private(set) var officialPricingSnapshot:
        V013OfficialPricingSnapshot = .current
    @Published private(set) var pendingOfficialPricingSnapshot:
        V013OfficialPricingSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var syncingPricingProfileID: String?
    @Published private(set) var isCheckingOfficialPricing = false
    @Published private(set) var status = "尚未读取最近完成请求"
    @Published private(set) var pricingMessageByProfile: [String: String] = [:]
    @Published private(set) var officialPricingMessage = "官方价格尚未检查更新"
    @Published private(set) var lastUsageFilesRead = 0
    private let pricingStore: V012RelayPricingStore
    private let officialPricingStore: V013OfficialPricingStore
    private let usageLedgerStore: V013UsageLedgerStore
    private let cpaEvidenceStore: V013CPACollectionEvidenceStore
    private let usageScanner: V012UsageScanCoordinator
    private let pricingFetcher: V012PricingManifestFetcher
    private let officialPricingChecker: V013OfficialPricingChecker
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var usageLedger: V013UsageLedgerState = .empty
    private var lastPricingCheckByProfile: [String: Date] = [:]
    private var latestOfficialUsageSnapshot: V011OfficialUsageSnapshot?
    private var latestHistoryCoverageComplete = false
    private var latestSourceReadsStable = false
    private var stagedAgentLoopTurns:
        [String: V012CompletedTurnUsage] = [:]

    init(
        controlRoot: URL? = nil,
        usageReader: V012RolloutUsageReader = V012RolloutUsageReader(),
        usageScanner: V012UsageScanCoordinator? = nil,
        pricingFetcher: V012PricingManifestFetcher =
            V012PricingManifestFetcher(),
        officialPricingChecker: V013OfficialPricingChecker =
            V013OfficialPricingChecker(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let root = controlRoot ?? Self.liveControlRoot()
        self.pricingStore = V012RelayPricingStore(
            fileURL: root
                .appendingPathComponent("V012", isDirectory: true)
                .appendingPathComponent("relay-pricing.json")
        )
        self.officialPricingStore = V013OfficialPricingStore(
            fileURL: root
                .appendingPathComponent("V013", isDirectory: true)
                .appendingPathComponent("official-pricing.json")
        )
        self.usageLedgerStore = V013UsageLedgerStore(
            fileURL: root
                .appendingPathComponent("V013", isDirectory: true)
                .appendingPathComponent("usage-ledger.json")
        )
        self.cpaEvidenceStore = V013CPACollectionEvidenceStore(root: root
            .appendingPathComponent("V013/CPA/captures", isDirectory: true))
        self.usageScanner = usageScanner ?? V012UsageScanCoordinator(
            usageReader: { url, providerID in
                try usageReader.read(
                    at: url,
                    fallbackProviderID: providerID
                )
            }
        )
        self.pricingFetcher = pricingFetcher
        self.officialPricingChecker = officialPricingChecker
        self.now = now
        do {
            pricingSnapshots = try pricingStore.load()
        } catch {
            pricingSnapshots = [:]
            status = "已保存定价无法安全读取；请求用量仍可查看"
        }
        do {
            officialPricingSnapshot = try officialPricingStore.load()
                ?? .current
        } catch {
            officialPricingSnapshot = .current
            officialPricingMessage =
                "已保存官方价格无法安全读取；使用内置官方快照"
        }
        do {
            usageLedger = try usageLedgerStore.load()
        } catch {
            usageLedger = .empty
            status = "本地请求账本无法安全读取；仅显示当前会话证据"
        }
    }

    func refresh(
        rows: [V011SessionRow],
        historyCoverage: V013UsageHistoryCoverage,
                 officialSnapshot: V011OfficialUsageSnapshot?, profiles: [CodexRelayProfile]) {
        latestOfficialUsageSnapshot = officialSnapshot
        latestHistoryCoverageComplete = false
        latestSourceReadsStable = false
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if historyCoverage == .loading {
            usagePresentation = .init(strict: .notRead,
                local: usagePresentation?.local, apiReference: nil)
            isRefreshing = true
            status = "正在读取本周本机历史"
            return
        }
        let orderedRows = rows.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
        let weeklyWindow = officialSnapshot?.windows.first {
            $0.durationMinutes == 10_080 && $0.resetsAt != nil
        }
        let windowStart = weeklyWindow?.resetsAt?.addingTimeInterval(
            -10_080 * 60
        )
        var selected = Array(orderedRows.prefix(16))
        if let windowStart {
            selected.append(contentsOf: orderedRows.filter {
                ($0.updatedAt ?? .distantPast) >= windowStart
            })
        }
        selected = Array(
            Dictionary(
                selected.map { ($0.id, $0) },
                uniquingKeysWith: { lhs, _ in lhs }
            ).values
        ).sorted { lhs, rhs in
            (lhs.updatedAt ?? .distantPast)
                > (rhs.updatedAt ?? .distantPast)
        }
        let sources = selected.map {
                V012UsageScanSource(
                    url: URL(fileURLWithPath: $0.rolloutPath),
                    providerID: $0.currentProvider
                )
            }
        isRefreshing = true
        let scanner = usageScanner
        refreshTask = Task { [weak self] in
            do {
                let result = try await scanner.scan(sources)
                guard let self,
                      !Task.isCancelled,
                      generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                self.lastUsageFilesRead = result.readSourceCount
                var ledgerReadFailure: String?
                do { self.usageLedger = try self.usageLedgerStore.load() }
                catch { ledgerReadFailure = "本地账本无法安全读取；原文件已保留，本次未写入。恢复可读账本后可刷新重试" }
                let combined = Dictionary(
                    result.turns.map { ($0.id, $0) }
                        + self.stagedAgentLoopTurns.map { ($0.key, $0.value) }
                        + self.usageLedger.records.compactMap(\.completedUsage)
                            .map { ($0.id, $0) },
                    uniquingKeysWith: V012OfficialUsageCollection.retainingEvidence
                ).values.sorted { $0.completedAt > $1.completedAt }
                let allTurns = Array(
                    combined.prefix(V012UsageScanCoordinator.maximumTurns)
                ).map { V012OfficialUsageCollection.enrich($0, snapshot: officialSnapshot) }
                self.evidenceTurns = allTurns
                let effectiveCoverage = result.overflowed
                    || combined.count
                        > V012UsageScanCoordinator.maximumTurns
                    ? V013UsageHistoryCoverage.overflow
                    : historyCoverage
                self.latestHistoryCoverageComplete =
                    effectiveCoverage.isComplete
                self.latestSourceReadsStable =
                    result.changedSourceCount == 0
                let ledgerFailure = ledgerReadFailure ?? self.mergeUsageLedger(
                    turns: allTurns,
                    officialSnapshot: officialSnapshot,
                    profiles: profiles,
                    historyCoverageComplete:
                        effectiveCoverage.isComplete,
                    sourceReadsStable: result.changedSourceCount == 0
                )
                let presentation = V013UsagePresentation.observedUsage(
                    ledger: self.usageLedger,
                    pricing: self.officialPricingSnapshot,
                    now: self.now()
                )
                self.usagePresentation = presentation
                let base = effectiveCoverage == .overflow
                    ? "本周完成请求超过读取上限；当前仅显示已读部分"
                    : effectiveCoverage == .incomplete
                    ? "本周历史尚未读全；当前仅显示已读的 \(allTurns.count) 个完成请求"
                    : effectiveCoverage == .unknown
                    ? "历史覆盖范围尚未确认；已读取 \(allTurns.count) 个完成请求"
                    : result.changedSourceCount == 0
                    ? "已读取 \(allTurns.count) 个完成请求"
                    : "已读取 \(allTurns.count) 个完成请求；正在写入的会话只显示完整请求"
                self.status = ledgerFailure.map { "\(base)；\($0)" } ?? base

            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                self.status = (error as? LocalizedError)?.errorDescription ?? "最近请求用量读取失败"
                self.usagePresentation = .readFailure(previous: self.usagePresentation)
            }
        }
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if isRefreshing {
            status = "本机用量更新已暂停；已读取的信息保留"
        }
        isRefreshing = false
    }

    func historyReadFailed(officialSnapshot: V011OfficialUsageSnapshot?) {
        cancelRefresh()
        latestOfficialUsageSnapshot = officialSnapshot
        latestHistoryCoverageComplete = false
        latestSourceReadsStable = false
        usagePresentation = .readFailure(previous: usagePresentation)
        status = usagePresentation?.local == nil
            ? "本周历史读取失败；暂无已读取的本机用量，请刷新重试"
            : "本周历史读取失败；保留上次已读取的本机用量，请刷新重试"
    }

    func stageAgentLoopUsage(_ turn: V012CompletedTurnUsage) {
        guard !turn.id.isEmpty,
              turn.completedAt >= turn.startedAt,
              !turn.calls.isEmpty,
              turn.calls.allSatisfy(\.isStructurallyValid) else { return }
        stagedAgentLoopTurns[turn.id] = turn
    }

    func pricingSnapshot(
        profileID: String
    ) -> V012RelayPricingSnapshot? {
        pricingSnapshots[profileID]
    }

    private func mergeUsageLedger(
        turns: [V012CompletedTurnUsage],
        officialSnapshot: V011OfficialUsageSnapshot?,
        profiles: [CodexRelayProfile],
        historyCoverageComplete: Bool,
        sourceReadsStable: Bool
    ) -> String? {
        var candidate = usageLedger
        let observedNow = now()
        let currentObservation: V013QuotaLedgerObservation? =
            officialSnapshot.flatMap { snapshot
                -> V013QuotaLedgerObservation? in
            guard snapshot.isFresh(at: observedNow),
                  let weekly = snapshot.windows.first(where: {
                      $0.durationMinutes == 10_080
                  }),
                  let resetsAt = weekly.resetsAt,
                  resetsAt > snapshot.observedAt else { return nil }
            return V013QuotaLedgerObservation.current(
                snapshot: snapshot,
                window: weekly,
                resetsAt: resetsAt,
                historyCoverageComplete: historyCoverageComplete,
                sourceReadsStable: sourceReadsStable
            )
        }
        let identityObservations = candidate.quotaObservations
            + (currentObservation.map { [$0] } ?? [])
        for turn in turns {
            let existingIndex = candidate.records.firstIndex {
                $0.id == turn.id
            }
            let isOfficial = turn.providerID.caseInsensitiveCompare(
                "openai"
            ) == .orderedSame
            let profile = profiles.first {
                $0.v011ProviderID == turn.providerID
                    || $0.id == turn.providerID
            }
            let relayPricing = profile.flatMap {
                pricingSnapshots[$0.id]
            }
            let cost = V012UsageCostCalculator.calculate(
                calls: turn.calls,
                model: turn.pricingModel,
                providerID: turn.providerID,
                planType: officialSnapshot?.planType,
                serviceTier: turn.pricingServiceTier,
                relayPricing: relayPricing,
                officialPricing: officialPricingSnapshot,
                requestBoundariesKnown: turn.containsOnlyTurnTotals != true
            )
            let accountScope = isOfficial
                ? officialSnapshot?.accountScopeSHA256 : nil
            let identityBound = isOfficial
                && turn.officialRequestPricing.map { $0.accountScopeSHA256 == accountScope } != false
                && accountScope.map { scope in
                    V013UsageIdentityEvidence.isTrustedCompletion(
                        completedAt: turn.completedAt,
                        accountScope: scope,
                        observations: identityObservations
                    )
                } == true
            let canBindExisting = existingIndex.map { index in
                !candidate.records[index].identityBoundAtCompletion
                    && identityBound
            } ?? false
            if let existingIndex, !canBindExisting {
                V012OfficialUsageCollection.hydrate(&candidate.records[existingIndex], from: turn)
                continue
            }
            var record = V013UsageLedgerRecord(
                    version: V013UsageLedgerRecord.schemaVersion,
                    id: turn.id,
                    completedAt: turn.completedAt,
                    recordedAt: observedNow,
                    providerID: turn.providerID,
                    model: turn.model,
                    serviceTier: turn.serviceTier,
                    accountScopeSHA256: identityBound ? accountScope : nil,
                    identityBoundAtCompletion: identityBound,
                    legacyPostCompletionAccountScopeSHA256: nil,
                    inputTokens: turn.inputTokens,
                    cachedInputTokens: turn.cachedInputTokens,
                    cacheWriteInputTokens:
                        turn.cacheWriteInputTokens,
                    outputTokens: turn.outputTokens,
                    reasoningOutputTokens:
                        turn.reasoningOutputTokens,
                    modelProcessedTokens: turn.modelProcessedTokens,
                    originalCredits: cost.credits,
                    originalAPIEquivalentUSD:
                        cost.apiEquivalentUSD,
                    originalRelayAmount: cost.relayAmount,
                    originalRelayCurrency: cost.relayCurrency,
                    officialPricing: isOfficial
                        && (cost.apiEquivalentUSD != nil
                            || cost.credits != nil)
                        ? officialPricingSnapshot : nil,
                    relayPricing: isOfficial ? nil : relayPricing,
                    pricingEvidence: cost.pricingEvidence
                )
            record.completedUsage = turn
            if let existingIndex {
                candidate.records[existingIndex] = record
            } else {
                candidate.records.append(record)
            }
        }
        candidate.records = Array(
            candidate.records.sorted {
                $0.completedAt > $1.completedAt
            }.prefix(2_000)
        )
        if let observation = currentObservation {
            candidate.record(observation)
        }
        candidate.quotaObservations = Array(
            candidate.quotaObservations.sorted {
                $0.observedAt < $1.observedAt
            }.suffix(400)
        )
        guard candidate != usageLedger else { return nil }
        do {
            try usageLedgerStore.commit(candidate)
            usageLedger = candidate
            return nil
        } catch {
            return "本地账本本次未更新"
        }
    }

    @discardableResult
    func savePricing(
        profile: CodexRelayProfile,
        model: String,
        currency: String,
        inputPerMillion: Double,
        cachedInputPerMillion: Double,
        outputPerMillion: Double,
        sourceURL: String?,
        automaticUpdates: Bool
    ) -> Bool {
        do {
            var candidate = try pricingStore.loadForUpdate()
            let rate = V012ModelTokenRate(
                model: model,
                inputPerMillion: inputPerMillion,
                cachedInputPerMillion: cachedInputPerMillion,
                cacheWriteInputPerMillion: nil,
                outputPerMillion: outputPerMillion
            )
            let snapshot: V012RelayPricingSnapshot
            if let existing = candidate[profile.id] {
                snapshot = try existing.replacing(
                    rate: rate,
                    currency: currency,
                    sourceURL: sourceURL,
                    automaticUpdates: automaticUpdates,
                    now: now()
                )
            } else {
                snapshot = try V012RelayPricingSnapshot.manual(
                    profileID: profile.id,
                    currency: currency,
                    rates: [rate],
                    sourceURL: sourceURL,
                    automaticUpdates: automaticUpdates,
                    now: now()
                )
            }
            candidate[profile.id] = snapshot
            try pricingStore.commit(candidate)
            pricingSnapshots = candidate
            pricingMessageByProfile[profile.id] =
                automaticUpdates
                    ? "定价已保存；每天只检查 JSON，更新须由你应用"
                    : "定价已保存；新请求按此不可变快照计算"
            return true
        } catch {
            pricingMessageByProfile[profile.id] =
                (error as? LocalizedError)?.errorDescription
                ?? "定价未保存"
            return false
        }
    }

    func syncPricing(profileID: String) async -> Bool {
        guard syncingPricingProfileID == nil,
              let current = pricingSnapshots[profileID],
              let sourceURL = current.sourceURL else {
            pricingMessageByProfile[profileID] =
                "请先保存不含凭据的 HTTPS JSON 价目表地址"
            return false
        }
        syncingPricingProfileID = profileID
        defer { syncingPricingProfileID = nil }
        do {
            let fetched = try await pricingFetcher.fetch(
                profileID: profileID,
                sourceURL: sourceURL,
                automaticUpdates: current.automaticUpdates
            )
            lastPricingCheckByProfile[profileID] = fetched.checkedAt
            let pricingUnchanged = fetched.hasSamePricing(as: current)
            if pricingUnchanged {
                var candidate = try pricingStore.loadForUpdate()
                candidate[profileID] = fetched
                try pricingStore.commit(candidate)
                pricingSnapshots = candidate
                pendingPricingSnapshots.removeValue(forKey: profileID)
            } else {
                pendingPricingSnapshots[profileID] = fetched
            }
            pricingMessageByProfile[profileID] =
                pricingUnchanged
                    ? "检查完成：定价未变化；已记录检查时间 \(fetched.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                    : pricingDiff(current: current, pending: fetched)
            return true
        } catch {
            pricingMessageByProfile[profileID] =
                (error as? LocalizedError)?.errorDescription
                ?? "定价同步失败；现有价格保持不变"
            return false
        }
    }

    func syncPricingIfDue() async {
        let due = pricingSnapshots.values.filter {
            $0.automaticUpdates
                && now().timeIntervalSince(
                    lastPricingCheckByProfile[$0.profileID]
                        ?? $0.checkedAt
                ) >= 24 * 60 * 60
        }.sorted { $0.profileID < $1.profileID }
        for snapshot in due {
            guard await syncPricing(profileID: snapshot.profileID) else {
                break
            }
        }
    }

    @discardableResult
    func applyPendingPricing(profileID: String) -> Bool {
        guard let pending = pendingPricingSnapshots[profileID] else {
            pricingMessageByProfile[profileID] = "没有待应用价格更新"
            return false
        }
        do {
            var candidate = try pricingStore.loadForUpdate()
            candidate[profileID] = pending
            try pricingStore.commit(candidate)
            pricingSnapshots = candidate
            pendingPricingSnapshots.removeValue(forKey: profileID)
            pricingMessageByProfile[profileID] =
                "已由用户应用价格快照；生效 \(pending.effectiveAt.formatted(date: .abbreviated, time: .shortened))，检查 \(pending.checkedAt.formatted(date: .abbreviated, time: .shortened))；历史请求仍保留原快照"
            return true
        } catch {
            pricingMessageByProfile[profileID] =
                (error as? LocalizedError)?.errorDescription
                ?? "价格更新未应用；原快照保持不变"
            return false
        }
    }

    private func pricingDiff(
        current: V012RelayPricingSnapshot,
        pending: V012RelayPricingSnapshot
    ) -> String {
        var changedModels = 0
        let models = Set(
            current.rates.map { $0.model.lowercased() }
                + pending.rates.map { $0.model.lowercased() }
        )
        for model in models {
            if current.rate(for: model) != pending.rate(for: model) {
                changedModels += 1
            }
        }
        let currency = current.currency == pending.currency
            ? "币种不变" : "币种 \(current.currency)→\(pending.currency)"
        return "发现更新：\(changedModels) 个模型价格变化，\(currency)；检查 \(pending.checkedAt.formatted(date: .abbreviated, time: .shortened))。尚未应用"
    }

    func checkOfficialPricing() async {
        guard !isCheckingOfficialPricing else { return }
        isCheckingOfficialPricing = true
        defer { isCheckingOfficialPricing = false }
        do {
            let candidate = try await officialPricingChecker.check(
                current: officialPricingSnapshot
            )
            if candidate.hasSamePricing(as: officialPricingSnapshot) {
                try officialPricingStore.commit(candidate)
                officialPricingSnapshot = candidate
                pendingOfficialPricingSnapshot = nil
                officialPricingMessage =
                    "检查完成：API 模型页与 Speed 未变化 · \(candidate.effectiveAPICheckedAt.formatted(date: .abbreviated, time: .shortened))；credits rate card 核验时间未更新"
            } else {
                pendingOfficialPricingSnapshot = candidate
                officialPricingMessage = officialPricingDiff(
                    current: officialPricingSnapshot,
                    pending: candidate
                )
            }
        } catch {
            officialPricingMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "官方价格检查失败；生效快照保持不变"
        }
    }

    @discardableResult
    func applyPendingOfficialPricing() -> Bool {
        guard let pending = pendingOfficialPricingSnapshot else {
            officialPricingMessage = "没有待应用官方价格更新"
            return false
        }
        do {
            try officialPricingStore.commit(pending)
            officialPricingSnapshot = pending
            pendingOfficialPricingSnapshot = nil
            let presentation = V013UsagePresentation.observedUsage(
                ledger: usageLedger, pricing: pending, now: now()
            )
            usagePresentation = presentation
            officialPricingMessage =
                "已由用户应用官方 API 价格快照；生效 \(pending.effectiveAt.formatted(date: .abbreviated, time: .shortened))，检查 \(pending.checkedAt.formatted(date: .abbreviated, time: .shortened))；历史请求原快照不变"
            return true
        } catch {
            officialPricingMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "官方价格更新未应用；原快照保持不变"
            return false
        }
    }

    private func officialPricingDiff(
        current: V013OfficialPricingSnapshot,
        pending: V013OfficialPricingSnapshot
    ) -> String {
        let changes = pending.rates.filter { new in
            current.rates.first(where: { $0.id == new.id }) != new
        }.count
        return "发现官方 API 价格变化：\(changes) 个模型/tier 条目；API 模型页与 Speed 检查 \(pending.effectiveAPICheckedAt.formatted(date: .abbreviated, time: .shortened))；credits rate card 核验时间未更新。尚未应用"
    }

    func cost(
        for turn: V012CompletedTurnUsage,
        planType: String?,
        profiles: [CodexRelayProfile]
    ) -> V012CostResult {
        if let recorded = usageLedger.records.first(where: {
            $0.id == turn.id
        }) {
            return recorded.originalCostResult()
        }
        let profile = profiles.first {
            $0.v011ProviderID == turn.providerID
                || $0.id == turn.providerID
        }
        return V012UsageCostCalculator.calculate(
            calls: turn.calls,
            model: turn.pricingModel,
            providerID: turn.providerID,
            planType: planType,
            serviceTier: turn.pricingServiceTier,
            relayPricing: profile.flatMap {
                pricingSnapshots[$0.id]
            },
            officialPricing: officialPricingSnapshot,
            requestBoundariesKnown: turn.containsOnlyTurnTotals != true
        )
    }

    func currentRepricedCost(
        for turn: V012CompletedTurnUsage,
        planType: String?,
        profiles: [CodexRelayProfile]
    ) -> V012CostResult? {
        guard let recorded = usageLedger.records.first(where: {
            $0.id == turn.id
        }) else { return nil }
        let profile = profiles.first {
            $0.v011ProviderID == turn.providerID
                || $0.id == turn.providerID
        }
        let currentRelayPricing = profile.flatMap {
            pricingSnapshots[$0.id]
        }
        let current = V012UsageCostCalculator.calculate(
            calls: turn.calls,
            model: turn.pricingModel,
            providerID: turn.providerID,
            planType: planType,
            serviceTier: turn.pricingServiceTier,
            relayPricing: currentRelayPricing,
            officialPricing: officialPricingSnapshot,
            requestBoundariesKnown: turn.containsOnlyTurnTotals != true
        )
        let pricingUnchanged: Bool
        if turn.providerID.caseInsensitiveCompare("openai")
            == .orderedSame {
            pricingUnchanged = recorded.officialPricing?.hasSamePricing(
                as: officialPricingSnapshot
            ) == true
        } else {
            switch (recorded.relayPricing, currentRelayPricing) {
            case (nil, nil):
                pricingUnchanged = true
            case let (recorded?, current?):
                pricingUnchanged = recorded.hasSamePricing(as: current)
            default:
                pricingUnchanged = false
            }
        }
        guard !pricingUnchanged else { return nil }
        return current
    }

    private static func liveControlRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent(
                "AI接入助手",
                isDirectory: true
            )
            .appendingPathComponent(
                "ControlPlane",
                isDirectory: true
            )
    }
}
