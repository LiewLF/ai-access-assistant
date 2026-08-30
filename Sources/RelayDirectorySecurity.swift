import CryptoKit
import Darwin
import Foundation
enum RelayServiceType: String, Codable {
    case officialAPI
    case compatibleService
    case thirdPartyRelay
}
enum RelayCatalogRecordState: String, Codable {
    case verified
    case reviewRequired
    case anomalous
    case revoked
}

enum RelayProbeState: String, Codable {
    case passed
    case failed
    case unverified
}

struct RelayVerificationEvidence: Codable, Equatable {
    let documentation: RelayProbeState
    let tls: RelayProbeState
    let modelList: RelayProbeState
    let minimalRequest: RelayProbeState
    let evidenceURLs: [URL]
    let verifierID: String
    let verifiedAt: Date
    let consecutiveFailures: Int
}

struct ProviderCatalogEntryV2: Identifiable, Codable, Equatable {
    let id: String
    let serviceName: String
    let officialWebsite: URL
    let registrationURL: URL?
    let documentationURL: URL
    let serviceType: RelayServiceType
    let baseURLPattern: String?
    let protocols: [String]
    let models: [String]
    let contextWindow: Int?
    let supportsImageInput: Bool?
    let supportsToolCalls: Bool?
    let supportsResponses: Bool?
    let supportsClaudeMessages: Bool?
    let supportedAgents: [String]
    let knownIssues: [String]
    let privacyDisclosure: String
    let commercialRelationship: String?
    let verification: RelayVerificationEvidence
    let state: RelayCatalogRecordState
}

struct SignedRelayCatalogPayload: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let generatedAt: Date
    let entries: [ProviderCatalogEntryV2]
    let revokedEntryIDs: [String]
}

struct SignedRelayCatalogPackage: Codable, Equatable {
    let payload: SignedRelayCatalogPayload
    let keyID: String
    let signature: Data
}

enum RelayCatalogSecurityError: LocalizedError, Equatable {
    case invalidSignature
    case unsupportedSchema
    case missingEvidence(String)
    case revokedEntry(String)
    case malformedPackage
    case malformedPublicKey
    case keyIdentifierMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSignature: return "中转目录签名无效"
        case .unsupportedSchema: return "中转目录Schema版本不受支持"
        case let .missingEvidence(id): return "目录记录缺少证据，禁止发布：\(id)"
        case let .revokedEntry(id): return "目录记录已撤销：\(id)"
        case .malformedPackage: return "中转目录文件格式无法识别"
        case .malformedPublicKey: return "发布者公钥文件格式无法识别"
        case .keyIdentifierMismatch: return "目录签名Key ID与所选发布者公钥不一致"
        }
    }
}

struct RelayCatalogPublicKeyDocument: Codable, Equatable {
    let schemaVersion: Int
    let keyID: String
    let displayName: String
    let publicKeyBase64: String
    let sourceURL: URL?
}

struct RelayCatalogImportReceipt: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let keyID: String
    let publisherName: String
    let publicKeyFingerprint: String
    let generatedAt: Date
    let importedAt: Date
    let entries: [ProviderCatalogEntryV2]
    let revokedEntryIDs: [String]
}

enum RelayCatalogPackageImporter {
    static func decodePackage(_ data: Data) throws -> SignedRelayCatalogPackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let package = try? decoder.decode(SignedRelayCatalogPackage.self, from: data) else {
            throw RelayCatalogSecurityError.malformedPackage
        }
        return package
    }

    static func decodePublicKey(_ data: Data) throws -> (
        document: RelayCatalogPublicKeyDocument,
        key: Curve25519.Signing.PublicKey
    ) {
        let decoder = JSONDecoder()
        guard let document = try? decoder.decode(RelayCatalogPublicKeyDocument.self, from: data),
              document.schemaVersion == 1,
              let raw = Data(base64Encoded: document.publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw RelayCatalogSecurityError.malformedPublicKey
        }
        return (document, key)
    }

    static func importPackage(
        packageData: Data,
        publicKeyData: Data,
        now: Date = Date()
    ) throws -> RelayCatalogImportReceipt {
        let package = try decodePackage(packageData)
        let publicKey = try decodePublicKey(publicKeyData)
        guard package.keyID == publicKey.document.keyID else {
            throw RelayCatalogSecurityError.keyIdentifierMismatch
        }
        let entries = try SignedRelayCatalogVerifier.verify(
            package: package,
            trustedKeys: [publicKey.document.keyID: publicKey.key]
        )
        return RelayCatalogImportReceipt(
            schemaVersion: 1,
            catalogVersion: package.payload.catalogVersion,
            keyID: package.keyID,
            publisherName: publicKey.document.displayName,
            publicKeyFingerprint: fingerprint(publicKey.key.rawRepresentation),
            generatedAt: package.payload.generatedAt,
            importedAt: now,
            entries: entries,
            revokedEntryIDs: package.payload.revokedEntryIDs
        )
    }

    static func fingerprint(_ rawKey: Data) -> String {
        let digest = SHA256.hash(data: rawKey)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct RelayDirectoryCacheStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI接入助手/RelayDirectory", isDirectory: true)
    }

    var receiptURL: URL { directory.appendingPathComponent("verified-catalog.json") }

    func load() throws -> RelayCatalogImportReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            RelayCatalogImportReceipt.self,
            from: Data(contentsOf: receiptURL, options: .mappedIfSafe)
        )
        guard receipt.schemaVersion == 1 else {
            throw RelayCatalogSecurityError.unsupportedSchema
        }
        return receipt
    }

    func save(_ receipt: RelayCatalogImportReceipt) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let temporary = directory.appendingPathComponent(".verified-catalog-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            _ = try FileManager.default.replaceItemAt(receiptURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: receiptURL)
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        try FileManager.default.removeItem(at: receiptURL)
    }
}

enum SignedRelayCatalogVerifier {
    static func sign(
        payload: SignedRelayCatalogPayload,
        keyID: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedRelayCatalogPackage {
        let data = try canonicalData(payload)
        return SignedRelayCatalogPackage(
            payload: payload,
            keyID: keyID,
            signature: try privateKey.signature(for: data)
        )
    }

    static func verify(
        package: SignedRelayCatalogPackage,
        trustedKeys: [String: Curve25519.Signing.PublicKey],
        supportedSchema: ClosedRange<Int> = 1...1
    ) throws -> [ProviderCatalogEntryV2] {
        guard supportedSchema.contains(package.payload.schemaVersion) else {
            throw RelayCatalogSecurityError.unsupportedSchema
        }
        guard let key = trustedKeys[package.keyID],
              key.isValidSignature(
                package.signature,
                for: try canonicalData(package.payload)
              ) else {
            throw RelayCatalogSecurityError.invalidSignature
        }
        for entry in package.payload.entries {
            guard !entry.verification.evidenceURLs.isEmpty,
                  !entry.verification.verifierID.isEmpty else {
                throw RelayCatalogSecurityError.missingEvidence(entry.id)
            }
            guard entry.state != .revoked,
                  !package.payload.revokedEntryIDs.contains(entry.id) else {
                throw RelayCatalogSecurityError.revokedEntry(entry.id)
            }
        }
        return package.payload.entries
    }

    private static func canonicalData(_ payload: SignedRelayCatalogPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

enum RelayCatalogGovernance {
    static func effectiveState(
        entry: ProviderCatalogEntryV2,
        now: Date,
        reviewInterval: TimeInterval = 30 * 24 * 60 * 60
    ) -> RelayCatalogRecordState {
        if entry.state == .revoked { return .revoked }
        if entry.verification.consecutiveFailures > 0 { return .anomalous }
        if now.timeIntervalSince(entry.verification.verifiedAt) >= reviewInterval {
            return .reviewRequired
        }
        return entry.state
    }

    static func allowsOneClick(_ entry: ProviderCatalogEntryV2, now: Date) -> Bool {
        effectiveState(entry: entry, now: now) == .verified
            && entry.verification.documentation == .passed
            && entry.verification.tls == .passed
            && entry.verification.modelList == .passed
            && entry.verification.minimalRequest == .passed
    }

    static func effectiveState(
        entry: ProviderCatalogEntryV2,
        localProbe: ScheduledRelayProbe?,
        now: Date,
        reviewInterval: TimeInterval = 30 * 24 * 60 * 60
    ) -> RelayCatalogRecordState {
        let signedState = effectiveState(
            entry: entry,
            now: now,
            reviewInterval: reviewInterval
        )
        guard signedState != .revoked else { return .revoked }
        if let localProbe {
            if localProbe.consecutiveFailures > 0 {
                return .anomalous
            }
            if localProbe.requiresAuthenticatedVerification {
                return .reviewRequired
            }
            if localProbe.nextDueAt <= now {
                return .reviewRequired
            }
        }
        return signedState
    }

    static func allowsOneClick(
        _ entry: ProviderCatalogEntryV2,
        localProbe: ScheduledRelayProbe?,
        now: Date
    ) -> Bool {
        effectiveState(
            entry: entry,
            localProbe: localProbe,
            now: now
        ) == .verified
            && entry.verification.documentation == .passed
            && entry.verification.tls == .passed
            && entry.verification.modelList == .passed
            && entry.verification.minimalRequest == .passed
    }
}

struct ScheduledRelayProbe: Identifiable, Codable, Equatable {
    let id: String
    let entryID: String
    let verifierTaskID: String
    let nextDueAt: Date
    let lastAttemptAt: Date?
    let consecutiveFailures: Int
    let authenticatedVerificationPending: Bool?

    var requiresAuthenticatedVerification: Bool {
        authenticatedVerificationPending ?? false
    }
}

struct RelayProbeScheduleState: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let tasks: [ScheduledRelayProbe]
}

struct RelayProbeRunResult: Codable, Equatable {
    let entryID: String
    let verifierTaskID: String
    let completedAt: Date
    let documentation: RelayProbeState
    let tls: RelayProbeState
    let modelList: RelayProbeState
    let minimalRequest: RelayProbeState
    let failureSummarySHA256: String?

    var passed: Bool {
        documentation == .passed
            && tls == .passed
            && modelList == .passed
            && minimalRequest == .passed
    }

    var hasFailure: Bool {
        documentation == .failed
            || tls == .failed
            || modelList == .failed
            || minimalRequest == .failed
    }
}

enum RelayProbeScheduler {
    static func reconcile(
        entries: [ProviderCatalogEntryV2],
        previous: RelayProbeScheduleState?,
        now: Date,
        reviewInterval: TimeInterval = 30 * 24 * 60 * 60
    ) -> RelayProbeScheduleState {
        let previousByEntry = Dictionary(
            uniqueKeysWithValues: (previous?.tasks ?? []).map {
                ($0.entryID, $0)
            }
        )
        let tasks = entries
            .filter { $0.state != .revoked }
            .map { entry -> ScheduledRelayProbe in
                if let existing = previousByEntry[entry.id] {
                    return existing
                }
                let taskID = "relay-probe-\(String(RelayCatalogPackageImporter.fingerprint(Data(entry.id.utf8)).prefix(16)))"
                let due = entry.verification.consecutiveFailures > 0
                    ? now
                    : entry.verification.verifiedAt
                        .addingTimeInterval(reviewInterval)
                return ScheduledRelayProbe(
                    id: taskID,
                    entryID: entry.id,
                    verifierTaskID: taskID,
                    nextDueAt: due,
                    lastAttemptAt: nil,
                    consecutiveFailures:
                        entry.verification.consecutiveFailures,
                    authenticatedVerificationPending: nil
                )
            }
            .sorted {
                if $0.nextDueAt != $1.nextDueAt {
                    return $0.nextDueAt < $1.nextDueAt
                }
                return $0.entryID < $1.entryID
            }
        return RelayProbeScheduleState(
            schemaVersion: RelayProbeScheduleState.currentSchemaVersion,
            generatedAt: now,
            tasks: tasks
        )
    }

    static func dueTasks(
        _ schedule: RelayProbeScheduleState,
        now: Date
    ) -> [ScheduledRelayProbe] {
        schedule.tasks.filter { $0.nextDueAt <= now }
    }

    static func recording(
        _ result: RelayProbeRunResult,
        in schedule: RelayProbeScheduleState,
        retryInterval: TimeInterval = 6 * 60 * 60,
        successInterval: TimeInterval = 30 * 24 * 60 * 60
    ) -> RelayProbeScheduleState {
        let tasks = schedule.tasks.map { task -> ScheduledRelayProbe in
            guard task.entryID == result.entryID,
                  task.verifierTaskID == result.verifierTaskID else {
                return task
            }
            let failures = result.hasFailure
                ? task.consecutiveFailures + 1 : 0
            let interval: TimeInterval
            if result.hasFailure {
                interval = retryInterval
            } else if result.passed {
                interval = successInterval
            } else {
                interval = 24 * 60 * 60
            }
            return ScheduledRelayProbe(
                id: task.id,
                entryID: task.entryID,
                verifierTaskID: task.verifierTaskID,
                nextDueAt: result.completedAt.addingTimeInterval(
                    interval
                ),
                lastAttemptAt: result.completedAt,
                consecutiveFailures: failures,
                authenticatedVerificationPending:
                    result.passed ? false : true
            )
        }
        return RelayProbeScheduleState(
            schemaVersion: schedule.schemaVersion,
            generatedAt: result.completedAt,
            tasks: tasks.sorted {
                if $0.nextDueAt != $1.nextDueAt {
                    return $0.nextDueAt < $1.nextDueAt
                }
                return $0.entryID < $1.entryID
            }
        )
    }
}

struct RelayProbeScheduleStore {
    let fileURL: URL

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "AI接入助手/RelayDirectory",
                isDirectory: true
            )
        fileURL = root.appendingPathComponent("probe-schedule.json")
    }

    func load() throws -> RelayProbeScheduleState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(
            RelayProbeScheduleState.self,
            from: Data(contentsOf: fileURL, options: .mappedIfSafe)
        )
        guard state.schemaVersion
            == RelayProbeScheduleState.currentSchemaVersion else {
            throw RelayCatalogSecurityError.unsupportedSchema
        }
        return state
    }

    func save(_ state: RelayProbeScheduleState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func recordAuthenticatedSuccess(
        entryID: String,
        completedAt: Date = Date()
    ) throws -> Bool {
        guard let schedule = try load(),
              let task = schedule.tasks.first(
                  where: { $0.entryID == entryID }
              ) else {
            return false
        }
        let result = RelayProbeRunResult(
            entryID: entryID,
            verifierTaskID: task.verifierTaskID,
            completedAt: completedAt,
            documentation: .passed,
            tls: .passed,
            modelList: .passed,
            minimalRequest: .passed,
            failureSummarySHA256: nil
        )
        try save(
            RelayProbeScheduler.recording(
                result,
                in: schedule
            )
        )
        return true
    }
}

enum RelayDirectoryProbeError: LocalizedError, Equatable {
    case authorizationRequired
    case taskMismatch

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "必须先确认本次公开文档和TLS探针"
        case .taskMismatch:
            return "探针任务与目录记录不一致"
        }
    }
}

enum RelayDirectoryPublicProbeRunner {
    typealias Transport =
        (URLRequest) async throws -> (Data, URLResponse)

    static func run(
        entry: ProviderCatalogEntryV2,
        task: ScheduledRelayProbe,
        userAuthorized: Bool,
        now: Date = Date(),
        transport: Transport? = nil
    ) async throws -> RelayProbeRunResult {
        guard userAuthorized else {
            throw RelayDirectoryProbeError.authorizationRequired
        }
        guard task.entryID == entry.id else {
            throw RelayDirectoryProbeError.taskMismatch
        }
        var request = URLRequest(
            url: entry.documentationURL,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "AI-Access-Assistant-Relay-Probe/1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let result: (Data, URLResponse)
            if let transport {
                result = try await transport(request)
            } else {
                result = try await RelaySecureHTTPClient.data(
                    for: request,
                    source: .catalog
                )
            }
            let tlsState: RelayProbeState =
                result.1.url?.scheme?.lowercased() == "https"
                ? .passed : .failed
            guard result.0.count <= 1_000_000,
                  let response = result.1 as? HTTPURLResponse,
                  (200...399).contains(response.statusCode),
                  tlsState == .passed else {
                return resultRecord(
                    entry: entry,
                    task: task,
                    now: now,
                    documentation: .failed,
                    tls: tlsState,
                    failureCode: "invalid-http-response"
                )
            }
            return resultRecord(
                entry: entry,
                task: task,
                now: now,
                documentation: .passed,
                tls: .passed,
                failureCode: nil
            )
        } catch {
            let nsError = error as NSError
            return resultRecord(
                entry: entry,
                task: task,
                now: now,
                documentation: .failed,
                tls: .failed,
                failureCode: "\(nsError.domain):\(nsError.code)"
            )
        }
    }

    private static func resultRecord(
        entry: ProviderCatalogEntryV2,
        task: ScheduledRelayProbe,
        now: Date,
        documentation: RelayProbeState,
        tls: RelayProbeState,
        failureCode: String?
    ) -> RelayProbeRunResult {
        RelayProbeRunResult(
            entryID: entry.id,
            verifierTaskID: task.verifierTaskID,
            completedAt: now,
            documentation: documentation,
            tls: tls,
            modelList: .unverified,
            minimalRequest: .unverified,
            failureSummarySHA256: failureCode.map {
                RelayCatalogPackageImporter.fingerprint(Data($0.utf8))
            }
        )
    }
}

enum RelayURLSource: String, Codable {
    case catalog
    case remoteDocument
    case screenshotOCR
    case automaticDiscovery
    case userTyped
}

enum RelayNetworkScope: String, Codable {
    case publicInternet
    case localGateway
    case privateNetwork
}

enum RelayURLBlockReason: String, Codable {
    case malformed
    case unsupportedScheme
    case credentialsEmbedded
    case fragment
    case insecureAutomaticSource
    case unresolvedAutomaticSource
    case loopback
    case privateAddress
    case linkLocal
    case reservedAddress
    case dnsRebinding
    case tooManyRedirects
}

struct RelayURLSecurityDecision: Codable, Equatable {
    let allowed: Bool
    let requiresConfirmation: Bool
    let scope: RelayNetworkScope?
    let blockers: [RelayURLBlockReason]
    let warnings: [String]
}

enum RelayURLSecurityPolicy {
    static func evaluate(
        url: URL,
        source: RelayURLSource,
        resolvedAddresses: [String],
        confirmedLocalGateway: Bool = false,
        confirmedPrivateNetworkRisk: Bool = false
    ) -> RelayURLSecurityDecision {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return blocked(.malformed)
        }
        if components.user != nil || components.password != nil {
            return blocked(.credentialsEmbedded)
        }
        if components.fragment != nil { return blocked(.fragment) }
        guard scheme == "https" || scheme == "http" else {
            return blocked(.unsupportedScheme)
        }
        let automatic = source != .userTyped
        if automatic, scheme != "https" { return blocked(.insecureAutomaticSource) }

        var scopes = resolvedAddresses.map(IPAddressClassifier.classify)
        if host == "localhost" || host.hasSuffix(".localhost") {
            scopes.append(.loopback)
        } else if IPAddressClassifier.isIPAddress(host) {
            scopes.append(IPAddressClassifier.classify(host))
        } else if automatic, resolvedAddresses.isEmpty {
            return blocked(.unresolvedAutomaticSource)
        }
        let unique = Set(scopes)
        let privateLike = unique.filter { $0 != .publicInternet }
        if automatic, !privateLike.isEmpty {
            return RelayURLSecurityDecision(
                allowed: false,
                requiresConfirmation: false,
                scope: nil,
                blockers: [.dnsRebinding] + privateLike.map(\.blockReason),
                warnings: ["自动来源解析到非公网地址，已按DNS重绑定风险阻止。"]
            )
        }
        if unique.contains(.loopback) {
            guard source == .userTyped, confirmedLocalGateway else {
                return RelayURLSecurityDecision(
                    allowed: false,
                    requiresConfirmation: true,
                    scope: .localGateway,
                    blockers: [.loopback],
                    warnings: ["本机环回网关必须由用户手填并对该配置档单独确认。"]
                )
            }
            return RelayURLSecurityDecision(
                allowed: true,
                requiresConfirmation: false,
                scope: .localGateway,
                blockers: [],
                warnings: scheme == "http"
                    ? ["本地网关使用明文HTTP；只对本机配置档生效，不进入公共目录。"]
                    : ["本地网关只对本机配置档生效，不进入公共目录。"]
            )
        }
        if privateLike.contains(.privateNetwork) {
            let safeByDefault = scheme == "https"
            guard safeByDefault || confirmedPrivateNetworkRisk else {
                return RelayURLSecurityDecision(
                    allowed: false,
                    requiresConfirmation: true,
                    scope: .privateNetwork,
                    blockers: [.privateAddress],
                    warnings: ["私网HTTP可能被同网段窃听；需单独接受风险。"]
                )
            }
            return RelayURLSecurityDecision(
                allowed: true,
                requiresConfirmation: !safeByDefault,
                scope: .privateNetwork,
                blockers: [],
                warnings: ["私网地址不进入公共目录，也不外推到其他配置档。"]
            )
        }
        if privateLike.contains(.linkLocal) { return blocked(.linkLocal) }
        if privateLike.contains(.reserved) { return blocked(.reservedAddress) }
        return RelayURLSecurityDecision(
            allowed: true,
            requiresConfirmation: false,
            scope: .publicInternet,
            blockers: [],
            warnings: []
        )
    }

    static func evaluateRedirectChain(
        _ urls: [URL],
        source: RelayURLSource,
        resolvedAddresses: [URL: [String]],
        maximumRedirects: Int = 3
    ) -> RelayURLSecurityDecision {
        guard urls.count > 0, urls.count - 1 <= maximumRedirects else {
            return blocked(.tooManyRedirects)
        }
        for url in urls {
            let decision = evaluate(
                url: url,
                source: source,
                resolvedAddresses: resolvedAddresses[url] ?? []
            )
            if !decision.allowed { return decision }
        }
        return RelayURLSecurityDecision(
            allowed: true,
            requiresConfirmation: false,
            scope: .publicInternet,
            blockers: [],
            warnings: []
        )
    }

    private static func blocked(_ reason: RelayURLBlockReason) -> RelayURLSecurityDecision {
        RelayURLSecurityDecision(
            allowed: false,
            requiresConfirmation: false,
            scope: nil,
            blockers: [reason],
            warnings: []
        )
    }
}

private enum ClassifiedIPAddress: Hashable {
    case publicInternet
    case loopback
    case privateNetwork
    case linkLocal
    case reserved

    var blockReason: RelayURLBlockReason {
        switch self {
        case .publicInternet: return .malformed
        case .loopback: return .loopback
        case .privateNetwork: return .privateAddress
        case .linkLocal: return .linkLocal
        case .reserved: return .reservedAddress
        }
    }
}

private enum IPAddressClassifier {
    static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    static func classify(_ value: String) -> ClassifiedIPAddress {
        var ipv4 = in_addr()
        let isV4 = value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        if isV4 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            guard bytes.count == 4 else { return .reserved }
            let a = Int(bytes[0]), b = Int(bytes[1])
            if a == 127 { return .loopback }
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) {
                return .privateNetwork
            }
            if a == 169 && b == 254 { return .linkLocal }
            if a == 0 || a >= 224 || (a == 100 && (64...127).contains(b)) {
                return .reserved
            }
            return .publicInternet
        }
        var ipv6 = in6_addr()
        let isV6 = value.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
        guard isV6 else { return .reserved }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .reserved }
        if bytes[0] & 0xFE == 0xFC { return .privateNetwork }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .linkLocal }
        if bytes[0] == 0xFF { return .reserved }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }),
           bytes[10] == 0xFF, bytes[11] == 0xFF {
            let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            return classify(mapped)
        }
        return .publicInternet
    }
}

enum RelayCompatibilityOutcome: String, Codable {
    case verifiedOneClick
    case manualWithAssistantCheck
    case textOnly
    case imageUnsupported
    case toolsUnsupported
    case agentUnsupported
    case insufficientEvidence
}

struct RelayCompatibilityDimension: Codable, Equatable {
    let relayID: String
    let desktopAgent: String
    let protocolName: String
    let model: String
    let capability: String
    let configurationMethod: String
    let outcome: RelayCompatibilityOutcome
    let evidence: [URL]
    let verifiedAt: Date?
}

enum RelayDNSResolver {
    static func resolve(host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        return Array(Set(addresses)).sorted()
    }
}

enum RelaySecureNetworkError: LocalizedError {
    case blocked(RelayURLSecurityDecision)
    case responseTooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case let .blocked(decision):
            return "网络地址安全检查未通过：\(decision.blockers.map(\.rawValue).joined(separator: "、"))"
        case let .responseTooLarge(limit):
            return "网络响应超过\(limit)字节安全上限，已停止下载"
        }
    }
}

class RelayRedirectGuard: NSObject, URLSessionTaskDelegate {
    let source: RelayURLSource
    let maximumRedirects: Int
    let confirmedLocalGateway: Bool
    let confirmedPrivateNetworkRisk: Bool
    private let lock = NSLock()
    private var redirectCount = 0

    init(
        source: RelayURLSource,
        maximumRedirects: Int = 3,
        confirmedLocalGateway: Bool = false,
        confirmedPrivateNetworkRisk: Bool = false
    ) {
        self.source = source
        self.maximumRedirects = maximumRedirects
        self.confirmedLocalGateway = confirmedLocalGateway
        self.confirmedPrivateNetworkRisk = confirmedPrivateNetworkRisk
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        guard count <= maximumRedirects,
              let url = request.url,
              let host = url.host else {
            completionHandler(nil)
            return
        }
        let decision = RelayURLSecurityPolicy.evaluate(
            url: url,
            source: source,
            resolvedAddresses: RelayDNSResolver.resolve(host: host),
            confirmedLocalGateway: confirmedLocalGateway,
            confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk
        )
        completionHandler(decision.allowed ? request : nil)
    }
}

final class RelayBoundedDownloadGuard:
    RelayRedirectGuard,
    URLSessionDownloadDelegate {
    let maximumBytes: Int64
    private let sizeLock = NSLock()
    private var exceeded = false

    init(
        source: RelayURLSource,
        maximumBytes: Int64,
        maximumRedirects: Int = 3
    ) {
        self.maximumBytes = maximumBytes
        super.init(
            source: source,
            maximumRedirects: maximumRedirects
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if Self.exceedsLimit(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite:
                totalBytesExpectedToWrite,
            maximumBytes: maximumBytes
        ) {
            sizeLock.lock()
            exceeded = true
            sizeLock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) { }

    var didExceedLimit: Bool {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return exceeded
    }

    static func exceedsLimit(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        maximumBytes: Int64
    ) -> Bool {
        totalBytesWritten > maximumBytes
            || (
                totalBytesExpectedToWrite > 0
                    && totalBytesExpectedToWrite > maximumBytes
            )
    }
}

enum RelayHTTPNetworkRoute: String, Codable, Equatable, Sendable {
    case direct
    case inherited
}

enum RelaySecureHTTPClient {
    static func data(
        for request: URLRequest,
        source: RelayURLSource,
        confirmedLocalGateway: Bool = false,
        confirmedPrivateNetworkRisk: Bool = false,
        networkRoute: RelayHTTPNetworkRoute = .inherited
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host else {
            throw RelaySecureNetworkError.blocked(
                RelayURLSecurityDecision(
                    allowed: false,
                    requiresConfirmation: false,
                    scope: nil,
                    blockers: [.malformed],
                    warnings: []
                )
            )
        }
        let initial = RelayURLSecurityPolicy.evaluate(
            url: url,
            source: source,
            resolvedAddresses: RelayDNSResolver.resolve(host: host),
            confirmedLocalGateway: confirmedLocalGateway,
            confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk
        )
        guard initial.allowed else { throw RelaySecureNetworkError.blocked(initial) }
        let configuration = sessionConfiguration(
            networkRoute: networkRoute
        )
        let delegate = RelayRedirectGuard(
            source: source,
            confirmedLocalGateway: confirmedLocalGateway,
            confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let result = try await session.data(for: request)
        if let finalURL = result.1.url, let finalHost = finalURL.host {
            let final = RelayURLSecurityPolicy.evaluate(
                url: finalURL,
                source: source,
                resolvedAddresses: RelayDNSResolver.resolve(host: finalHost),
                confirmedLocalGateway: confirmedLocalGateway,
                confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk
            )
            guard final.allowed else { throw RelaySecureNetworkError.blocked(final) }
        }
        return result
    }

    static func sessionConfiguration(
        networkRoute: RelayHTTPNetworkRoute
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if networkRoute == .direct {
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    static func download(
        for request: URLRequest,
        source: RelayURLSource,
        maximumBytes: Int64
    ) async throws -> (URL, URLResponse) {
        guard let url = request.url, let host = url.host else {
            throw RelaySecureNetworkError.blocked(
                RelayURLSecurityDecision(
                    allowed: false,
                    requiresConfirmation: false,
                    scope: nil,
                    blockers: [.malformed],
                    warnings: []
                )
            )
        }
        let initial = RelayURLSecurityPolicy.evaluate(
            url: url,
            source: source,
            resolvedAddresses: RelayDNSResolver.resolve(host: host)
        )
        guard initial.allowed else {
            throw RelaySecureNetworkError.blocked(initial)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = RelayBoundedDownloadGuard(
            source: source,
            maximumBytes: maximumBytes
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let result: (URL, URLResponse)
        do {
            result = try await session.download(
                for: request,
                delegate: delegate
            )
        } catch {
            if delegate.didExceedLimit {
                throw RelaySecureNetworkError.responseTooLarge(
                    maximumBytes
                )
            }
            throw error
        }
        if let finalURL = result.1.url,
           let finalHost = finalURL.host {
            let final = RelayURLSecurityPolicy.evaluate(
                url: finalURL,
                source: source,
                resolvedAddresses: RelayDNSResolver.resolve(host: finalHost)
            )
            guard final.allowed else {
                throw RelaySecureNetworkError.blocked(final)
            }
        }
        return result
    }
}
