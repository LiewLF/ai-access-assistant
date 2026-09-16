// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

private struct V011ConnectionHealthHistoryPayload:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let observations: [V011ConnectionHealthObservation]
}

struct V011ConnectionReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let validityDuration: TimeInterval = 86_400

    let schemaVersion: Int
    let configHash: String
    let providerID: String
    let endpointHost: String?
    let verifiedAt: Date
    let sessionProviderCheck: V011SessionProviderCheck
    /// Legacy schema1 receipts decode with nil expiry and remain readable as
    /// unverified until a fresh probe is recorded.
    let expiresAt: Date?

    init(
        configHash: String,
        providerID: String,
        endpointHost: String?,
        verifiedAt: Date,
        sessionProviderCheck: V011SessionProviderCheck,
        expiresAt: Date? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.configHash = configHash
        self.providerID = providerID
        self.endpointHost = endpointHost
        self.verifiedAt = verifiedAt
        self.sessionProviderCheck = sessionProviderCheck
        self.expiresAt = expiresAt
    }

    func freshness(at now: Date = Date())
        -> V011ConnectionReceiptFreshness {
        guard let expiresAt else { return .unverified }
        return expiresAt <= now ? .stale : .fresh
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && configHash.count == 64
            && configHash.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && !providerID.isEmpty
            && providerID.count <= 256
            && providerID == providerID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && verifiedAt.timeIntervalSinceReferenceDate
                .isFinite
            && endpointHost.map(Self.safeHost) != false
    }

    private static func safeHost(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.contains(where: {
                $0.isWhitespace
                    || "/@?#\\".contains($0)
            })
    }
}

private struct V011ConnectionReceiptSnapshot:
    Equatable, Sendable {
    let data: Data?
    let hash: String?
}

struct V011SessionRetentionReferenceGraph: Codable, Equatable, Sendable {
    let activeTransactionIDs: Set<String>
    let pendingTransactionIDs: Set<String>
    let diagnosticReferenceIDs: Set<String>

    var referencedIDs: Set<String> {
        activeTransactionIDs
            .union(pendingTransactionIDs)
            .union(diagnosticReferenceIDs)
    }
}

struct V011SessionRetentionPlan: Codable, Equatable, Sendable {
    let keptIDs: [String]
    let candidateIDs: [String]
    let blockedIDs: [String]
    let expectedHashes: [String: String]

    var isSafe: Bool {
        blockedIDs.isEmpty
            && candidateIDs.allSatisfy {
                expectedHashes[$0]?.isEmpty == false
            }
    }
}

enum V011SessionRetentionPlanner {
    /// Computes a CAS/lock-aware terminal retention plan only. It never
    /// deletes or moves a journal; callers must re-read hashes under the
    /// existing store lock before any separately authorized archive action.
    static func plan(
        terminalIDs: [String],
        graph: V011SessionRetentionReferenceGraph,
        expectedHashes: [String: String],
        keepCount: Int = 5
    ) -> V011SessionRetentionPlan {
        let ordered = terminalIDs.filter { !$0.isEmpty }
        let keep = Set(ordered.prefix(max(keepCount, 0)))
        let referenced = graph.referencedIDs
        let blocked = ordered.filter { referenced.contains($0) }
        let candidates = ordered.filter {
            !keep.contains($0)
                && !referenced.contains($0)
                && expectedHashes[$0]?.isEmpty == false
        }
        return V011SessionRetentionPlan(
            keptIDs: ordered.filter { keep.contains($0) },
            candidateIDs: candidates,
            blockedIDs: blocked,
            expectedHashes: expectedHashes
        )
    }
}

struct V011ConnectionReceiptStore {
    let fileURL: URL

    func load() throws -> V011ConnectionReceipt? {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return nil
        }
        return try withReceiptLock(operation: LOCK_SH) {
            try loadUnlocked()
        }
    }

    func save(_ receipt: V011ConnectionReceipt) throws {
        try withReceiptLock(operation: LOCK_EX) {
            let current = try snapshotUnlocked()
            _ = try saveUnlocked(
                receipt,
                expectedHash: current.hash
            )
        }
    }

    func commit(
        _ receipt: V011ConnectionReceipt,
        validateAfterSave: () throws -> Void
    ) throws {
        try withReceiptLock(operation: LOCK_EX) {
            let previous = try snapshotUnlocked()
            let savedHash = try saveUnlocked(
                receipt,
                expectedHash: previous.hash
            )
            do {
                try validateAfterSave()
            } catch let validationError {
                do {
                    try restoreUnlocked(
                        previous,
                        expectedCurrentHash: savedHash
                    )
                } catch {
                    throw error
                }
                throw validationError
            }
        }
    }

    private func loadUnlocked() throws -> V011ConnectionReceipt? {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return nil
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let receipt = try JSONDecoder().decode(
            V011ConnectionReceipt.self,
            from: Data(contentsOf: fileURL)
        )
        guard receipt.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return receipt
    }

    private func snapshotUnlocked()
        throws -> V011ConnectionReceiptSnapshot {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return V011ConnectionReceiptSnapshot(
                data: nil,
                hash: nil
            )
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let data = try Data(
            contentsOf: fileURL,
            options: .mappedIfSafe
        )
        return V011ConnectionReceiptSnapshot(
            data: data,
            hash: TOMLSemanticEngine.sha256(data)
        )
    }

    @discardableResult
    private func saveUnlocked(
        _ receipt: V011ConnectionReceipt,
        expectedHash: String?
    ) throws -> String {
        guard receipt.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        let encoded = try encoder.encode(receipt)
        let data: Data
        if let original = try? Data(contentsOf: fileURL) {
            data = try preservingUnknownJSONFields(
                encoded,
                from: original,
                knownRootKeys: [
                    "schemaVersion", "configHash", "providerID",
                    "endpointHost", "verifiedAt",
                    "sessionProviderCheck", "expiresAt",
                ]
            )
        } else {
            data = encoded
        }
        try SessionSyncAtomicFile.write(
            data,
            to: fileURL,
            expectedHash: expectedHash,
            permissions: 0o600,
            modificationDate: nil
        )
        return TOMLSemanticEngine.sha256(data)
    }

    private func restoreUnlocked(
        _ snapshot: V011ConnectionReceiptSnapshot,
        expectedCurrentHash: String
    ) throws {
        guard SessionSyncFileSafety.hashIfPresent(fileURL)
                == expectedCurrentHash else {
            throw SessionSyncError.rolloutChanged(fileURL.path)
        }
        if let data = snapshot.data {
            try SessionSyncAtomicFile.write(
                data,
                to: fileURL,
                expectedHash: expectedCurrentHash,
                permissions: 0o600,
                modificationDate: nil
            )
            return
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        guard SessionSyncFileSafety.hashIfPresent(fileURL)
                == expectedCurrentHash else {
            throw SessionSyncError.rolloutChanged(fileURL.path)
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func withReceiptLock<T>(
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = directory.appendingPathComponent(
            ".connection-receipt.lock"
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(
                  descriptor,
                  S_IRUSR | S_IWUSR
              ) == 0,
              flock(
                  descriptor,
                  operation | LOCK_NB
              ) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

struct V011ConnectionHealthHistoryStore {
    static let maximumCount = 50

    let fileURL: URL

    func load() throws -> [V011ConnectionHealthObservation] {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return []
        }
        return try withHistoryLock(operation: LOCK_SH) {
            try loadUnlocked()
        }
    }

    @discardableResult
    func append(
        _ observation: V011ConnectionHealthObservation
    ) throws -> [V011ConnectionHealthObservation] {
        guard observation.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withHistoryLock(operation: LOCK_EX) {
            let current = try loadUnlocked()
            let observations = Array(
                ([observation] + current)
                    .prefix(Self.maximumCount)
            )
            let payload = V011ConnectionHealthHistoryPayload(
                schemaVersion:
                    V011ConnectionHealthHistoryPayload
                        .currentSchemaVersion,
                observations: observations
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
            ]
            let data = try encoder.encode(payload)
            try SessionSyncAtomicFile.write(
                data,
                to: fileURL,
                expectedHash:
                    SessionSyncFileSafety.hashIfPresent(fileURL),
                permissions: 0o600,
                modificationDate: nil
            )
            return observations
        }
    }

    private func loadUnlocked()
        throws -> [V011ConnectionHealthObservation] {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return []
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let payload = try JSONDecoder().decode(
            V011ConnectionHealthHistoryPayload.self,
            from: Data(contentsOf: fileURL)
        )
        guard payload.schemaVersion
                == V011ConnectionHealthHistoryPayload
                    .currentSchemaVersion,
              payload.observations.count <= Self.maximumCount,
              payload.observations.allSatisfy(
                  \.isStructurallyValid
              ),
              Set(payload.observations.map(\.id)).count
                == payload.observations.count else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return payload.observations
    }

    private func withHistoryLock<T>(
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let lockURL = directory.appendingPathComponent(
            ".connection-health-history.lock"
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(
                  descriptor,
                  S_IRUSR | S_IWUSR
              ) == 0,
              flock(
                  descriptor,
                  operation | LOCK_NB
              ) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

struct V011CurrentConnectionVerification:
    Equatable, @unchecked Sendable {
    let state: LiveCodexState
    let providerID: String
    let configHash: String
    let routeIdentity: String
    let verifiedAt: Date
    let endpointHost: String?
    let sessionProviderCheck: V011SessionProviderCheck
    let savedProfileID: String?
}

struct V011CurrentConnectionProbeFailure:
    LocalizedError, @unchecked Sendable {
    let state: LiveCodexState
    let providerID: String
    let configHash: String
    let endpointHost: String?
    let sessionProviderCheck: V011SessionProviderCheck
    let failureCategory: V011ConnectionHealthFailureCategory
    let httpStatus: Int?
    let safeMessage: String

    var errorDescription: String? { safeMessage }
}

struct V011ConnectionHealthProbeDiagnosis:
    Equatable, Sendable {
    let category: V011ConnectionHealthFailureCategory
    let httpStatus: Int?

    static func classify(
        _ error: Error
    ) -> V011ConnectionHealthProbeDiagnosis {
        // LTP-140: the bounded specified-model probe reports typed evidence
        // instead of a boolean, so its limited outcomes never reach the
        // generic fallbacks below.
        if let probeError = error as? RelayConnectionVerifierError {
            switch probeError {
            case .missingModel:
                return diagnosis(.endpointOrModel)
            case let .probeNotCompleted(reason, _):
                return diagnosis(reason.healthCategory)
            case let .probeRemoteFailure(failure, _):
                return diagnosis(failure.healthCategory)
            }
        }
        if let controlError = error as? CodexControlError {
            switch controlError {
            case let .badResponse(status, message):
                if status == 402
                    || hasExplicitQuotaEvidence(message) {
                    return diagnosis(
                        .quotaExhausted,
                        httpStatus: status
                    )
                }
                return classify(httpStatus: status)
            case .missingSecret, .credentialBridge:
                return diagnosis(.authentication)
            case .invalidProfile:
                return diagnosis(.endpointOrModel)
            case .responseTooLarge, .invalidResponseBody:
                return diagnosis(.invalidResponse)
            default:
                break
            }
        }
        if let adapterError = error as? FableLiveAdapterError {
            switch adapterError {
            case .invalidCredential,
                    .credentialUnavailable,
                    .credentialStoreFailure:
                return diagnosis(.authentication)
            case .invalidRelayEndpoint:
                return diagnosis(.endpointOrModel)
            case .commandTimedOut:
                return diagnosis(.networkTimedOut)
            case .relayRequestFailed:
                return diagnosis(.networkUnavailable)
            case let .relayRejected(status):
                return classify(httpStatus: status)
            case .commandOutputTooLarge,
                    .relayResponseTooLarge,
                    .invalidRelayResponse:
                return diagnosis(.invalidResponse)
            default:
                break
            }
        }
        // LTP-140: a cancelled wait is not a network fault. Callers keep the
        // original error type (the LTP-130 cancel contract rethrows
        // `CancellationError` untouched); only the persisted category is
        // corrected so an actual cancellation is never stored as an
        // unavailable network or an unknown failure.
        if error is CancellationError {
            return diagnosis(.probeCancelled)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return diagnosis(.probeCancelled)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(urlErrorCode: nsError.code)
        }
        return diagnosis(.unknown)
    }

    private static func classify(
        urlErrorCode: Int
    ) -> V011ConnectionHealthProbeDiagnosis {
        switch urlErrorCode {
        case NSURLErrorCancelled:
            return diagnosis(.probeCancelled)
        case NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed:
            return diagnosis(.networkNameResolutionFailed)
        case NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate:
            return diagnosis(.networkSecureConnectionFailed)
        case NSURLErrorTimedOut:
            return diagnosis(.networkTimedOut)
        default:
            return diagnosis(.networkUnavailable)
        }
    }

    private static func classify(
        httpStatus: Int
    ) -> V011ConnectionHealthProbeDiagnosis {
        let category: V011ConnectionHealthFailureCategory
        switch httpStatus {
        case 401:
            category = .authentication
        case 403:
            category = .permission
        case 404, 405:
            category = .endpointOrModel
        case 408:
            category = .networkUnavailable
        case 429:
            category = .rateLimited
        case 500...599:
            category = .upstreamUnavailable
        case 400, 409, 413, 415, 422:
            category = .invalidResponse
        default:
            category = .unknown
        }
        return V011ConnectionHealthProbeDiagnosis(
            category: category,
            httpStatus: (100...599).contains(httpStatus)
                ? httpStatus : nil
        )
    }

    private static func diagnosis(
        _ category: V011ConnectionHealthFailureCategory,
        httpStatus: Int? = nil
    ) -> V011ConnectionHealthProbeDiagnosis {
        V011ConnectionHealthProbeDiagnosis(
            category: category,
            httpStatus: httpStatus.flatMap {
                (100...599).contains($0) ? $0 : nil
            }
        )
    }

    private static func hasExplicitQuotaEvidence(
        _ message: String
    ) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("insufficient_quota")
            || normalized.contains("insufficient quota")
            || normalized.contains("insufficient_balance")
            || normalized.contains("insufficient balance")
            || normalized.contains("insufficient_credit")
            || normalized.contains("insufficient credit")
            || normalized.contains("payment_required")
            || normalized.contains("billing hard limit")
    }
}

enum V011CurrentConnectionVerificationError:
    LocalizedError, Equatable {
    case savedProfileMissing
    case savedProfileMismatch
    case endpointHostUnavailable
    case configurationChangedDuringCheck

    var errorDescription: String? {
        switch self {
        case .savedProfileMissing:
            return "当前中转没有匹配的已保存资料"
        case .savedProfileMismatch:
            return "当前Provider、地址、模型或认证与保存资料不一致"
        case .endpointHostUnavailable:
            return "当前中转地址无法识别主机名"
        case .configurationChangedDuringCheck:
            return "检测期间Codex设置发生变化，本次结果已作废"
        }
    }
}
