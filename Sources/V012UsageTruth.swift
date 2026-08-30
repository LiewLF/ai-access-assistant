import Combine
import Foundation

struct V012RateLimitObservation: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
    let observedAt: Date

    var isWeekly: Bool {
        windowMinutes >= 6 * 24 * 60
            && windowMinutes <= 8 * 24 * 60
    }
}

struct V012UpstreamTokenUsage: Equatable, Sendable {
    let observedAt: Date
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let activeContextTokens: Int64?
    let rateLimit: V012RateLimitObservation?
    let creditBalance: String?

    var uncachedInputTokens: Int64? {
        guard let cacheWriteInputTokens else { return nil }
        return max(
            0,
            inputTokens
                - cachedInputTokens
                - cacheWriteInputTokens
        )
    }

    var isStructurallyValid: Bool {
        [
            inputTokens,
            cachedInputTokens,
            outputTokens,
            reasoningOutputTokens,
        ].allSatisfy { $0 >= 0 }
            && cacheWriteInputTokens.map { value in
                value >= 0
                    && cachedInputTokens + value <= inputTokens
            } != false
            && activeContextTokens.map { $0 >= 0 } != false
            && reasoningOutputTokens <= outputTokens
            && creditBalance.map {
                V012ModelTokenRate.safeText(
                    $0,
                    maximumBytes: 80
                )
            } != false
    }
}

struct V012CompletedTurnUsage: Identifiable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let completedAt: Date
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let model: String
    let providerID: String
    let serviceTier: String?
    let calls: [V012UpstreamTokenUsage]

    var inputTokens: Int64 {
        calls.reduce(0) { $0 + $1.inputTokens }
    }

    var cachedInputTokens: Int64 {
        calls.reduce(0) { $0 + $1.cachedInputTokens }
    }

    var cacheWriteInputTokens: Int64? {
        guard calls.allSatisfy({ $0.cacheWriteInputTokens != nil }) else {
            return nil
        }
        return calls.reduce(0) {
            $0 + ($1.cacheWriteInputTokens ?? 0)
        }
    }

    var uncachedInputTokens: Int64? {
        guard calls.allSatisfy({ $0.uncachedInputTokens != nil }) else {
            return nil
        }
        return calls.reduce(0) {
            $0 + ($1.uncachedInputTokens ?? 0)
        }
    }

    var outputTokens: Int64 {
        calls.reduce(0) { $0 + $1.outputTokens }
    }

    var reasoningOutputTokens: Int64 {
        calls.reduce(0) { $0 + $1.reasoningOutputTokens }
    }

    var billableTokens: Int64 {
        inputTokens + outputTokens
    }

    var activeContextTokens: Int64? {
        calls.last?.activeContextTokens
    }
}

struct V012UsageReadResult: Equatable, Sendable {
    let turns: [V012CompletedTurnUsage]
    let sourceChangedDuringRead: Bool
}

enum V012RolloutUsageError: LocalizedError {
    case malformedUsage

    var errorDescription: String? {
        "请求用量记录格式无法安全识别"
    }
}

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
    }

    let maximumTurns: Int
    let maximumCallsPerTurn: Int
    let lineReader: RolloutSessionReader

    init(
        maximumTurns: Int = 50,
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
                      let seconds = number(payload["started_at"]),
                      seconds > 0 else { return }
                active = Builder(
                    rawTurnID: turnID,
                    startedAt: Date(timeIntervalSince1970: seconds),
                    settings: contextByTurn[turnID] ?? settings
                )
            case "token_count":
                guard var value = active else { return }
                guard value.calls.count < maximumCallsPerTurn else {
                    throw V012RolloutUsageError.malformedUsage
                }
                guard let call = try parseCall(
                    payload,
                    object: object
                ) else { return }
                value.calls.append(call)
                active = value
            case "task_complete":
                guard let value = active,
                      let turnID = safeText(payload["turn_id"]),
                      turnID == value.rawTurnID,
                      !value.calls.isEmpty,
                      let completed = number(payload["completed_at"]),
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
            sourceChangedDuringRead: before != after
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
        guard let object = raw as? [String: Any],
              let primary = object["primary"] as? [String: Any],
              let used = number(primary["used_percent"]),
              let minutes = integer(primary["window_minutes"]),
              let reset = number(primary["resets_at"]),
              used >= 0,
              used <= 100,
              minutes > 0,
              reset > 0 else { return nil }
        return V012RateLimitObservation(
            usedPercent: used,
            windowMinutes: Int(minutes),
            resetsAt: Date(timeIntervalSince1970: reset),
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
    @Published private(set) var turns: [V012CompletedTurnUsage] = []
    @Published private(set) var weeklyUsageStatus: V013WeeklyUsageStatus = .notRead
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
    private let usageScanner: V012UsageScanCoordinator
    private let pricingFetcher: V012PricingManifestFetcher
    private let officialPricingChecker: V013OfficialPricingChecker
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var usageLedger: V013UsageLedgerState = .empty
    private var lastPricingCheckByProfile: [String: Date] = [:]
    private var latestOfficialUsageSnapshot: V011OfficialUsageSnapshot?

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

    func refresh(rows: [V011SessionRow], historyHasMore: Bool,
                 officialSnapshot: V011OfficialUsageSnapshot?, profiles: [CodexRelayProfile]) {
        latestOfficialUsageSnapshot = officialSnapshot
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
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
        let historyCoverageComplete: Bool
        if !historyHasMore {
            historyCoverageComplete = true
        } else if let windowStart,
                  let oldest = orderedRows.last?.updatedAt {
            historyCoverageComplete = oldest <= windowStart
        } else {
            historyCoverageComplete = false
        }
        let sources = selected.map {
                V012UsageScanSource(
                    url: URL(fileURLWithPath: $0.rolloutPath),
                    providerID: $0.currentProvider
                )
            }
        guard !sources.isEmpty else {
            isRefreshing = false
            lastUsageFilesRead = 0
            status = "历史列表尚未读取；刷新后显示最近完成请求"
            return
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
                self.turns = result.turns
                let ledgerUpdated = self.mergeUsageLedger(
                    turns: result.turns,
                    officialSnapshot: officialSnapshot,
                    profiles: profiles,
                    historyCoverageComplete:
                        historyCoverageComplete,
                    sourceReadsStable: result.changedSourceCount == 0
                )
                self.weeklyUsageStatus = V013WeeklyUsageEstimator
                    .evaluate(
                        ledger: self.usageLedger,
                        officialSnapshot: officialSnapshot,
                        planType: officialSnapshot?.planType,
                        pricing: self.officialPricingSnapshot,
                        now: self.now()
                    )
                let base = result.changedSourceCount == 0
                    ? "已读取 \(result.turns.count) 个完成请求"
                    : "已读取 \(result.turns.count) 个完成请求；正在写入的会话只显示完整请求"
                self.status = ledgerUpdated
                    ? base
                    : "\(base)；本地账本本次未更新"
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                self.status = (error as? LocalizedError)?
                    .errorDescription
                    ?? "最近请求用量读取失败"
            }
        }
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
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
    ) -> Bool {
        var candidate = usageLedger
        let existing = Set(candidate.records.map(\.id))
        let observedNow = now()
        for turn in turns where !existing.contains(turn.id) {
            let profile = profiles.first {
                $0.v011ProviderID == turn.providerID
                    || $0.id == turn.providerID
            }
            let relayPricing = profile.flatMap {
                pricingSnapshots[$0.id]
            }
            let cost = V012UsageCostCalculator.calculate(
                calls: turn.calls,
                model: turn.model,
                providerID: turn.providerID,
                planType: officialSnapshot?.planType,
                serviceTier: turn.serviceTier,
                relayPricing: relayPricing,
                officialPricing: officialPricingSnapshot
            )
            let isOfficial = turn.providerID.caseInsensitiveCompare(
                "openai"
            ) == .orderedSame
            let accountScope = isOfficial
                ? officialSnapshot?.accountScopeSHA256 : nil
            let identityBound = isOfficial
                && officialSnapshot.map { snapshot in
                    snapshot.isFresh(at: observedNow)
                        && snapshot.observedAt >= turn.completedAt
                        && snapshot.observedAt.timeIntervalSince(
                            turn.completedAt
                        ) <= V011OfficialUsageSnapshot
                            .freshnessLifetime
                } == true
            candidate.records.append(
                V013UsageLedgerRecord(
                    version: V013UsageLedgerRecord.schemaVersion,
                    id: turn.id,
                    completedAt: turn.completedAt,
                    recordedAt: observedNow,
                    providerID: turn.providerID,
                    model: turn.model,
                    serviceTier: turn.serviceTier,
                    accountScopeSHA256: accountScope,
                    identityBoundAtCompletion: identityBound,
                    inputTokens: turn.inputTokens,
                    cachedInputTokens: turn.cachedInputTokens,
                    cacheWriteInputTokens:
                        turn.cacheWriteInputTokens,
                    outputTokens: turn.outputTokens,
                    reasoningOutputTokens:
                        turn.reasoningOutputTokens,
                    billableTokens: turn.billableTokens,
                    originalCredits: cost.credits,
                    originalAPIEquivalentUSD:
                        cost.apiEquivalentUSD,
                    originalRelayAmount: cost.relayAmount,
                    originalRelayCurrency: cost.relayCurrency,
                    officialPricing: isOfficial
                        && cost.pricingRevision != nil
                        ? officialPricingSnapshot : nil,
                    relayPricing: isOfficial ? nil : relayPricing,
                    pricingEvidence: cost.pricingEvidence
                )
            )
        }
        candidate.records = Array(
            candidate.records.sorted {
                $0.completedAt > $1.completedAt
            }.prefix(2_000)
        )
        if let snapshot = officialSnapshot,
           snapshot.isFresh(at: observedNow),
           let weekly = snapshot.windows.first(where: {
               $0.durationMinutes == 10_080
           }),
           let resetsAt = weekly.resetsAt,
           resetsAt > snapshot.observedAt {
            let observation = V013QuotaLedgerObservation.current(
                snapshot: snapshot,
                window: weekly,
                resetsAt: resetsAt,
                historyCoverageComplete: historyCoverageComplete,
                sourceReadsStable: sourceReadsStable
            )
            if let index = candidate.quotaObservations.firstIndex(
                where: { $0.id == observation.id }
            ) {
                candidate.quotaObservations[index] = observation
            } else {
                candidate.quotaObservations.append(observation)
            }
        }
        candidate.quotaObservations = Array(
            candidate.quotaObservations.sorted {
                $0.observedAt < $1.observedAt
            }.suffix(400)
        )
        guard candidate != usageLedger else { return true }
        do {
            try usageLedgerStore.commit(candidate)
            usageLedger = candidate
            return true
        } catch {
            return false
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
            let rate = V012ModelTokenRate(
                model: model,
                inputPerMillion: inputPerMillion,
                cachedInputPerMillion: cachedInputPerMillion,
                cacheWriteInputPerMillion: nil,
                outputPerMillion: outputPerMillion
            )
            let snapshot: V012RelayPricingSnapshot
            if let existing = pricingSnapshots[profile.id] {
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
            var candidate = pricingSnapshots
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
            lastPricingCheckByProfile[profileID] = now()
            if fetched.revision == current.revision {
                pendingPricingSnapshots.removeValue(forKey: profileID)
            } else {
                pendingPricingSnapshots[profileID] = fetched
            }
            pricingMessageByProfile[profileID] =
                fetched.revision == current.revision
                    ? "检查完成：定价未变化；生效快照保持不变"
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
            var candidate = pricingSnapshots
            candidate[profileID] = pending
            try pricingStore.commit(candidate)
            pricingSnapshots = candidate
            pendingPricingSnapshots.removeValue(forKey: profileID)
            pricingMessageByProfile[profileID] =
                "已由用户应用价格快照 \(pending.revision.prefix(8))；历史请求仍保留原快照"
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
            if candidate.revision == officialPricingSnapshot.revision {
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
            weeklyUsageStatus = V013WeeklyUsageEstimator.evaluate(
                ledger: usageLedger,
                officialSnapshot: latestOfficialUsageSnapshot,
                planType: latestOfficialUsageSnapshot?.planType,
                pricing: pending,
                now: now()
            )
            officialPricingMessage =
                "已由用户应用官方 API 价格快照 \(pending.revision.prefix(8))；历史请求原快照不变"
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
            model: turn.model,
            providerID: turn.providerID,
            planType: planType,
            serviceTier: turn.serviceTier,
            relayPricing: profile.flatMap {
                pricingSnapshots[$0.id]
            },
            officialPricing: officialPricingSnapshot
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
        let current = V012UsageCostCalculator.calculate(
            calls: turn.calls,
            model: turn.model,
            providerID: turn.providerID,
            planType: planType,
            serviceTier: turn.serviceTier,
            relayPricing: profile.flatMap {
                pricingSnapshots[$0.id]
            },
            officialPricing: officialPricingSnapshot
        )
        guard current.pricingRevision != recorded
            .originalCostResult().pricingRevision else { return nil }
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
