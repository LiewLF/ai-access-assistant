import Foundation

enum V012PricingError: LocalizedError, Equatable {
    case invalidValue
    case unsafeSourceURL
    case unsupportedManifest
    case responseTooLarge
    case remoteUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "定价格式无效；请检查模型、币种和每百万 token 单价"
        case .unsafeSourceURL:
            return "自动同步只接受不含凭据、查询参数或内网地址的 HTTPS JSON 地址"
        case .unsupportedManifest:
            return "定价地址没有返回受支持的 JSON 价目表"
        case .responseTooLarge:
            return "远程价目表超过 512 KiB，已停止读取"
        case .remoteUnavailable:
            return "定价来源暂时无法读取；现有价格保持不变"
        }
    }
}

struct V012ModelTokenRate: Codable, Equatable, Identifiable {
    let model: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let cacheWriteInputPerMillion: Double?
    let outputPerMillion: Double

    var id: String { model.lowercased() }

    var isStructurallyValid: Bool {
        Self.safeText(model, maximumBytes: 128)
            && [
                inputPerMillion,
                cachedInputPerMillion,
                outputPerMillion,
            ].allSatisfy(Self.safeRate)
            && cacheWriteInputPerMillion.map(Self.safeRate) != false
    }

    private static func safeRate(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1_000_000_000
    }

    static func safeText(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct V012RelayPricingSnapshot: Codable, Equatable, Identifiable {
    enum SourceKind: String, Codable { case manual, remoteManifest }

    static let schemaVersion = 1

    let version: Int
    let profileID: String
    let currency: String
    let rates: [V012ModelTokenRate]
    let sourceKind: SourceKind
    let sourceURL: String?
    let effectiveAt: Date
    let checkedAt: Date
    let automaticUpdates: Bool
    let revision: String

    var id: String { profileID }

    var isStructurallyValid: Bool {
        version == Self.schemaVersion
            && V012ModelTokenRate.safeText(
                profileID,
                maximumBytes: 512
            )
            && currency.count >= 3
            && currency.utf8.count <= 12
            && currency.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
            && !rates.isEmpty
            && rates.count <= 256
            && rates.allSatisfy(\.isStructurallyValid)
            && Set(rates.map { $0.model.lowercased() }).count
                == rates.count
            && sourceURL.map {
                V012PricingManifestFetcher.safeURL($0) != nil
            } != false
            && (!automaticUpdates || sourceURL != nil)
            && effectiveAt.timeIntervalSince1970.isFinite
            && checkedAt.timeIntervalSince1970.isFinite
            && revision.count == 64
            && revision.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }

    func rate(for model: String) -> V012ModelTokenRate? {
        rates.first {
            $0.model.caseInsensitiveCompare(model) == .orderedSame
        }
    }

    func replacing(
        rate: V012ModelTokenRate,
        currency: String,
        sourceURL: String?,
        automaticUpdates: Bool,
        now: Date
    ) throws -> Self {
        var candidate = rates.filter {
            $0.model.caseInsensitiveCompare(rate.model) != .orderedSame
        }
        candidate.append(rate)
        candidate.sort {
            $0.model.localizedCaseInsensitiveCompare($1.model)
                == .orderedAscending
        }
        return try Self.manual(
            profileID: profileID,
            currency: currency,
            rates: candidate,
            sourceURL: sourceURL,
            automaticUpdates: automaticUpdates,
            now: now
        )
    }

    static func manual(
        profileID: String,
        currency: String,
        rates: [V012ModelTokenRate],
        sourceURL: String?,
        automaticUpdates: Bool,
        now: Date
    ) throws -> Self {
        let normalizedCurrency = currency
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedURL = sourceURL?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let source = normalizedURL?.isEmpty == false
            ? normalizedURL : nil
        let revisionData = try JSONEncoder().encode(rates)
            + Data(normalizedCurrency.utf8)
            + Data((source ?? "manual").utf8)
        let value = Self(
            version: schemaVersion,
            profileID: profileID,
            currency: normalizedCurrency,
            rates: rates,
            sourceKind: .manual,
            sourceURL: source,
            effectiveAt: now,
            checkedAt: now,
            automaticUpdates: automaticUpdates,
            revision: V011AgentLoopReceipt.sha256(revisionData)
        )
        guard value.isStructurallyValid else {
            throw V012PricingError.invalidValue
        }
        return value
    }
}

private struct V012RelayPricingDocument: Codable {
    let schemaVersion: Int
    let snapshots: [V012RelayPricingSnapshot]
}

struct V012RelayPricingStore {
    static let maximumBytes = 256 * 1024

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

    func load() throws -> [String: V012RelayPricingSnapshot] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
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
        let document = try decoder.decode(
            V012RelayPricingDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard document.schemaVersion == 1,
              document.snapshots.count <= 1_000,
              document.snapshots.allSatisfy(\.isStructurallyValid),
              Set(document.snapshots.map(\.profileID)).count
                == document.snapshots.count else {
            throw V012PricingError.invalidValue
        }
        return Dictionary(
            uniqueKeysWithValues: document.snapshots.map {
                ($0.profileID, $0)
            }
        )
    }

    func commit(
        _ snapshots: [String: V012RelayPricingSnapshot]
    ) throws {
        let values = snapshots.values.sorted {
            $0.profileID < $1.profileID
        }
        guard values.count <= 1_000,
              values.allSatisfy(\.isStructurallyValid) else {
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
        let data = try encoder.encode(
            V012RelayPricingDocument(
                schemaVersion: 1,
                snapshots: values
            )
        )
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

private struct V012RemotePricingManifest: Decodable {
    let schemaVersion: Int
    let currency: String
    let effectiveAt: String?
    let models: [V012ModelTokenRate]
}

struct V012PricingManifestFetcher: Sendable {
    static let maximumBytes = 512 * 1024

    typealias Resolver = @Sendable (String) -> [String]
    typealias Transport = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    let now: @Sendable () -> Date
    let resolver: Resolver
    let transport: Transport

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        resolver: @escaping Resolver = { host in
            RelayDNSResolver.resolve(host: host)
        },
        transport: Transport? = nil
    ) {
        self.now = now
        self.resolver = resolver
        self.transport = transport ?? { request in
            try await RelaySecureHTTPClient.data(
                for: request,
                source: .remoteDocument,
                networkRoute: .direct
            )
        }
    }

    func fetch(
        profileID: String,
        sourceURL: String,
        automaticUpdates: Bool
    ) async throws -> V012RelayPricingSnapshot {
        guard let url = Self.safeURL(sourceURL) else {
            throw V012PricingError.unsafeSourceURL
        }
        try requireSafeAutomaticURL(url)
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        let pair: (Data, URLResponse)
        do {
            pair = try await transport(request)
        } catch RelaySecureNetworkError.blocked {
            throw V012PricingError.unsafeSourceURL
        } catch {
            throw V012PricingError.remoteUnavailable
        }
        guard let response = pair.1 as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let finalURL = response.url,
              finalURL.scheme?.lowercased() == "https" else {
            throw V012PricingError.remoteUnavailable
        }
        try requireSafeAutomaticURL(finalURL)
        guard finalURL.host?.lowercased() == url.host?.lowercased(),
              finalURL.port == url.port else {
            throw V012PricingError.unsafeSourceURL
        }
        guard pair.0.count <= Self.maximumBytes else {
            throw V012PricingError.responseTooLarge
        }
        let manifest: V012RemotePricingManifest
        do {
            manifest = try JSONDecoder().decode(
                V012RemotePricingManifest.self,
                from: pair.0
            )
        } catch {
            throw V012PricingError.unsupportedManifest
        }
        let observedAt = now()
        let effectiveAt = manifest.effectiveAt.flatMap {
            ISO8601DateFormatter().date(from: $0)
        } ?? observedAt
        let snapshot = V012RelayPricingSnapshot(
            version: V012RelayPricingSnapshot.schemaVersion,
            profileID: profileID,
            currency: manifest.currency.uppercased(),
            rates: manifest.models,
            sourceKind: .remoteManifest,
            sourceURL: sourceURL,
            effectiveAt: effectiveAt,
            checkedAt: observedAt,
            automaticUpdates: automaticUpdates,
            revision: V011AgentLoopReceipt.sha256(pair.0)
        )
        guard manifest.schemaVersion == 1,
              snapshot.isStructurallyValid else {
            throw V012PricingError.unsupportedManifest
        }
        return snapshot
    }

    private func requireSafeAutomaticURL(_ url: URL) throws {
        guard let host = url.host else {
            throw V012PricingError.unsafeSourceURL
        }
        let decision = RelayURLSecurityPolicy.evaluate(
            url: url,
            source: .remoteDocument,
            resolvedAddresses: resolver(host)
        )
        guard decision.allowed else {
            throw V012PricingError.unsafeSourceURL
        }
    }

    static func safeURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !isLocalHost(host) else {
            return nil
        }
        return components.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "::1"
            || host.hasPrefix("127.")
            || host.hasPrefix("10.")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("169.254.")
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || host.hasPrefix("fe80:")
    }
}

struct V012CostResult: Equatable {
    let credits: Double?
    let apiEquivalentUSD: Double?
    let relayAmount: Double?
    let relayCurrency: String?
    let pricingRevision: String?
    let pricingEvidence: String
    let pricingSourceURL: String?
    let pricingCheckedAt: Date?
}

enum V012UsageCostCalculator {
    static func calculate(
        calls: [V012UpstreamTokenUsage],
        model: String,
        providerID: String,
        planType: String?,
        serviceTier: String?,
        relayPricing: V012RelayPricingSnapshot?,
        officialPricing: V013OfficialPricingSnapshot = .current
    ) -> V012CostResult {
        if providerID.caseInsensitiveCompare("openai") != .orderedSame {
            guard let relayPricing,
                  let rate = relayPricing.rate(for: model) else {
                return V012CostResult(
                    credits: nil,
                    apiEquivalentUSD: nil,
                    relayAmount: nil,
                    relayCurrency: nil,
                    pricingRevision: nil,
                    pricingEvidence: "中转未保存该模型定价",
                    pricingSourceURL: nil,
                    pricingCheckedAt: nil
                )
            }
            return V012CostResult(
                credits: nil,
                apiEquivalentUSD: nil,
                relayAmount: amount(calls: calls, rate: rate),
                relayCurrency: relayPricing.currency,
                pricingRevision: relayPricing.revision,
                pricingEvidence:
                    "中转定价快照 · revision \(relayPricing.revision.prefix(8))",
                pricingSourceURL: relayPricing.sourceURL,
                pricingCheckedAt: relayPricing.checkedAt
            )
        }
        guard officialPricing.isStructurallyValid,
              let rate = officialPricing.rate(
                  model: model,
                  serviceTier: serviceTier
              ) else {
            return V012CostResult(
                credits: nil,
                apiEquivalentUSD: nil,
                relayAmount: nil,
                relayCurrency: nil,
                pricingRevision: nil,
                pricingEvidence: "当前模型或 service tier 无可用官方价格",
                pricingSourceURL: nil,
                pricingCheckedAt: nil
            )
        }
        let credits = officialPricing
            .supportsSubscriptionCredits(planType: planType)
            ? creditAmount(calls: calls, rate: rate)
            : nil
        return V012CostResult(
            credits: credits,
            apiEquivalentUSD: apiAmount(calls: calls, rate: rate),
            relayAmount: nil,
            relayCurrency: nil,
            pricingRevision: officialPricing.revision,
            pricingEvidence:
                "OpenAI 官方 credits 与 API 快照 · revision \(officialPricing.revision.prefix(8))",
            pricingSourceURL: officialPricing.subscriptionSourceURL,
            pricingCheckedAt: officialPricing.checkedAt
        )
    }

    private static func amount(
        calls: [V012UpstreamTokenUsage],
        rate: V012ModelTokenRate
    ) -> Double? {
        var total = 0.0
        for call in calls {
            guard let cacheWrite = call.cacheWriteInputTokens else {
                return nil
            }
            let uncached = max(
                0,
                call.inputTokens
                    - call.cachedInputTokens
                    - cacheWrite
            )
            let inputCost = Double(uncached) / 1_000_000
                * rate.inputPerMillion
            let cachedCost = Double(call.cachedInputTokens)
                / 1_000_000 * rate.cachedInputPerMillion
            let cacheWriteRate = rate.cacheWriteInputPerMillion
                ?? rate.inputPerMillion
            let cacheWriteCost = Double(
                cacheWrite
            ) / 1_000_000 * cacheWriteRate
            let outputCost = Double(call.outputTokens)
                / 1_000_000 * rate.outputPerMillion
            total += inputCost + cachedCost
                + cacheWriteCost + outputCost
        }
        return total
    }

    private static func creditAmount(
        calls: [V012UpstreamTokenUsage],
        rate: V013OfficialPricingRate
    ) -> Double? {
        var total = 0.0
        for call in calls {
            guard let cacheWrite = call.cacheWriteInputTokens else {
                return nil
            }
            let uncached = max(
                0,
                call.inputTokens - call.cachedInputTokens - cacheWrite
            )
            total += Double(uncached) / 1_000_000
                * rate.creditsInputPerMillion
            total += Double(call.cachedInputTokens) / 1_000_000
                * rate.creditsCachedInputPerMillion
            total += Double(call.outputTokens) / 1_000_000
                * rate.creditsOutputPerMillion
        }
        return total
    }

    private static func apiAmount(
        calls: [V012UpstreamTokenUsage],
        rate: V013OfficialPricingRate
    ) -> Double? {
        var total = 0.0
        for call in calls {
            guard let cacheWrite = call.cacheWriteInputTokens else {
                return nil
            }
            let longContext = call.inputTokens
                > rate.longContextThreshold
            let inputMultiplier = longContext
                ? rate.longContextInputMultiplier : 1
            let outputMultiplier = longContext
                ? rate.longContextOutputMultiplier : 1
            let uncached = max(
                0,
                call.inputTokens
                    - call.cachedInputTokens
                    - cacheWrite
            )
            let inputCost = Double(uncached) / 1_000_000
                * rate.apiInputPerMillionUSD * inputMultiplier
            let cachedCost = Double(call.cachedInputTokens)
                / 1_000_000 * rate.apiCachedInputPerMillionUSD
                * inputMultiplier
            let cacheWriteCost = Double(
                cacheWrite
            ) / 1_000_000 * rate.apiCacheWritePerMillionUSD
                * inputMultiplier
            let outputCost = Double(call.outputTokens)
                / 1_000_000 * rate.apiOutputPerMillionUSD
                * outputMultiplier
            total += inputCost + cachedCost
                + cacheWriteCost + outputCost
        }
        return total
    }
}
