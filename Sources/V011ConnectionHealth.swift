// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011SessionProviderCheck:
    String, Codable, Equatable, Sendable {
    case synchronized
    case drifted
    case unavailable
}

enum V011ConnectionReceiptFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unverified
}

enum V011ConnectionHealthOutcome:
    String, Codable, Equatable, Sendable {
    case passed
    case degraded
    case failed
}

enum V011ConnectionHealthFailureCode:
    String, Codable, Equatable, Sendable {
    case probeFailed
    case savedProfileMissing
    case savedProfileMismatch
    case endpointHostUnavailable
    case configurationChangedDuringCheck
    case sessionProviderDrift
    case receiptMismatch
    case unavailable
}

enum V011ConnectionHealthFailureCategory:
    String, Codable, Equatable, Sendable {
    case authentication
    case permission
    case endpointOrModel
    case quotaExhausted
    case rateLimited
    case upstreamUnavailable
    case networkNameResolutionFailed
    case networkSecureConnectionFailed
    case networkTimedOut
    case networkUnavailable
    case invalidResponse
    case unknown
}

enum V011ConnectionHealthRuntimeState:
    String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case notRunning
    case unknown
}

struct V011ConnectionHealthObservation:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let observedAt: Date
    let durationMilliseconds: Double
    let providerID: String?
    let configHash: String?
    let outcome: V011ConnectionHealthOutcome
    let failureCode: V011ConnectionHealthFailureCode?
    let failureCategory: V011ConnectionHealthFailureCategory?
    let httpStatus: Int?
    let sessionProviderCheck: V011SessionProviderCheck?
    let runtimeState: V011ConnectionHealthRuntimeState

    init(
        id: String = UUID().uuidString.lowercased(),
        observedAt: Date,
        durationMilliseconds: Double,
        providerID: String?,
        configHash: String?,
        outcome: V011ConnectionHealthOutcome,
        failureCode: V011ConnectionHealthFailureCode?,
        failureCategory: V011ConnectionHealthFailureCategory? = nil,
        httpStatus: Int? = nil,
        sessionProviderCheck: V011SessionProviderCheck?,
        runtimeState: V011ConnectionHealthRuntimeState
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.observedAt = observedAt
        self.durationMilliseconds = durationMilliseconds
        self.providerID = providerID
        self.configHash = configHash
        self.outcome = outcome
        self.failureCode = failureCode
        self.failureCategory = failureCategory
        self.httpStatus = httpStatus
        self.sessionProviderCheck = sessionProviderCheck
        self.runtimeState = runtimeState
    }

    var isStructurallyValid: Bool {
        let normalizedID = UUID(uuidString: id)?
            .uuidString.lowercased()
        let providerIsValid = providerID.map {
            !$0.isEmpty
                && $0.count <= 256
                && $0 == $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        } != false
        let hashIsValid = configHash.map {
            $0.count == 64
                && $0.allSatisfy {
                    $0.isHexDigit && !$0.isUppercase
                }
        } != false
        let outcomeIsValid: Bool
        switch outcome {
        case .passed:
            outcomeIsValid = failureCode == nil
        case .degraded, .failed:
            outcomeIsValid = failureCode != nil
        }
        let diagnosisIsValid =
            (failureCategory == nil || failureCode == .probeFailed)
            && (httpStatus == nil
                || (failureCategory != nil
                    && (100...599).contains(httpStatus!)))
        return schemaVersion == Self.currentSchemaVersion
            && normalizedID == id
            && observedAt.timeIntervalSinceReferenceDate.isFinite
            && durationMilliseconds.isFinite
            && durationMilliseconds >= 0
            && providerIsValid
            && hashIsValid
            && outcomeIsValid
            && diagnosisIsValid
    }
}

struct V011ConnectionHealthDigest: Equatable, Sendable {
    let sampleCount: Int
    let passedCount: Int
    let degradedCount: Int
    let failedCount: Int
    let passRate: Double
    let medianDurationMilliseconds: Double?
    let consecutiveIssueCount: Int
}

struct V011ConnectionHealthProviderDescriptor:
    Equatable, Sendable {
    let providerID: String
    let displayName: String
    let savedModelCount: Int?
    let defaultModelPresent: Bool?
    let isCurrent: Bool
}

struct V011ConnectionHealthProviderSummary:
    Identifiable, Equatable, Sendable {
    var id: String { providerID }

    let providerID: String
    let displayName: String
    let savedModelCount: Int?
    let defaultModelPresent: Bool?
    let isCurrent: Bool
    let latestObservation: V011ConnectionHealthObservation?
    let digest: V011ConnectionHealthDigest?
}

enum V011ConnectionHealthAdvice:
    String, Codable, Equatable, Sendable {
    case none
    case retryConnectionCheck
    case reviewRelayProfile
    case refreshCurrentState
    case openCodex
    case reopenCodex
    case recoverPendingSwitch
}

enum V011ConnectionHealthEvidenceFreshness:
    String, Equatable, Sendable {
    case untested
    case fresh
    case aging
    case stale
    case clockSkewed
}

enum V011ConnectionHealthAnalyzer {
    static let defaultSampleCount = 10
    static let freshEvidenceInterval: TimeInterval = 24 * 60 * 60
    static let staleEvidenceInterval: TimeInterval = 7 * 24 * 60 * 60
    static let allowedFutureClockSkew: TimeInterval = 5 * 60
    private static let unknownProviderID = "__unknown__"

    static func evidenceFreshness(
        for observation: V011ConnectionHealthObservation?,
        at now: Date = Date()
    ) -> V011ConnectionHealthEvidenceFreshness {
        guard let observation else { return .untested }
        let age = now.timeIntervalSince(observation.observedAt)
        if age < -allowedFutureClockSkew {
            return .clockSkewed
        }
        if age <= freshEvidenceInterval {
            return .fresh
        }
        if age <= staleEvidenceInterval {
            return .aging
        }
        return .stale
    }

    static func digest(
        _ observations: [V011ConnectionHealthObservation],
        maximumCount: Int = defaultSampleCount
    ) -> V011ConnectionHealthDigest? {
        guard maximumCount > 0 else { return nil }
        let recent = Array(observations.prefix(maximumCount))
        guard !recent.isEmpty else { return nil }
        let passedCount = recent.filter {
            $0.outcome == .passed
        }.count
        let degradedCount = recent.filter {
            $0.outcome == .degraded
        }.count
        let failedCount = recent.filter {
            $0.outcome == .failed
        }.count
        let durations = recent.map(\.durationMilliseconds)
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
        let medianDurationMilliseconds: Double?
        if durations.isEmpty {
            medianDurationMilliseconds = nil
        } else if durations.count.isMultiple(of: 2) {
            let upper = durations.count / 2
            medianDurationMilliseconds =
                (durations[upper - 1] + durations[upper]) / 2
        } else {
            medianDurationMilliseconds =
                durations[durations.count / 2]
        }
        let consecutiveIssueCount = recent.prefix {
            $0.outcome != .passed
        }.count
        return V011ConnectionHealthDigest(
            sampleCount: recent.count,
            passedCount: passedCount,
            degradedCount: degradedCount,
            failedCount: failedCount,
            passRate: Double(passedCount)
                / Double(recent.count),
            medianDurationMilliseconds:
                medianDurationMilliseconds,
            consecutiveIssueCount: consecutiveIssueCount
        )
    }

    static func providerSummaries(
        _ observations: [V011ConnectionHealthObservation],
        descriptors: [V011ConnectionHealthProviderDescriptor],
        maximumCountPerProvider: Int = defaultSampleCount
    ) -> [V011ConnectionHealthProviderSummary] {
        guard maximumCountPerProvider > 0 else { return [] }

        var descriptorsByProvider:
            [String: V011ConnectionHealthProviderDescriptor] = [:]
        for descriptor in descriptors {
            let providerID = normalizedProviderID(
                descriptor.providerID
            )
            guard providerID != unknownProviderID else { continue }
            let normalized = V011ConnectionHealthProviderDescriptor(
                providerID: providerID,
                displayName: descriptor.displayName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                savedModelCount: descriptor.savedModelCount,
                defaultModelPresent: descriptor.defaultModelPresent,
                isCurrent: descriptor.isCurrent
            )
            if let existing = descriptorsByProvider[providerID],
               existing.isCurrent || !normalized.isCurrent {
                continue
            }
            descriptorsByProvider[providerID] = normalized
        }

        var observationsByProvider:
            [String: [V011ConnectionHealthObservation]] = [:]
        for observation in observations {
            let providerID = normalizedProviderID(
                observation.providerID
            )
            observationsByProvider[providerID, default: []]
                .append(observation)
            if descriptorsByProvider[providerID] == nil {
                descriptorsByProvider[providerID] =
                    V011ConnectionHealthProviderDescriptor(
                        providerID: providerID,
                        displayName: providerDisplayName(
                            providerID
                        ),
                        savedModelCount: nil,
                        defaultModelPresent: nil,
                        isCurrent: false
                    )
            }
        }

        return descriptorsByProvider.values.map { descriptor in
            let recent = Array(
                (observationsByProvider[descriptor.providerID] ?? [])
                    .sorted(by: observationComesFirst)
                    .prefix(maximumCountPerProvider)
            )
            return V011ConnectionHealthProviderSummary(
                providerID: descriptor.providerID,
                displayName: descriptor.displayName.isEmpty
                    ? providerDisplayName(descriptor.providerID)
                    : descriptor.displayName,
                savedModelCount: descriptor.savedModelCount,
                defaultModelPresent: descriptor.defaultModelPresent,
                isCurrent: descriptor.isCurrent,
                latestObservation: recent.first,
                digest: digest(
                    recent,
                    maximumCount: maximumCountPerProvider
                )
            )
        }.sorted(by: providerSummaryComesFirst)
    }

    private static func normalizedProviderID(
        _ providerID: String?
    ) -> String {
        let value = providerID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return value.isEmpty ? unknownProviderID : value
    }

    private static func providerDisplayName(
        _ providerID: String
    ) -> String {
        switch providerID {
        case "openai":
            return "ChatGPT官方"
        case unknownProviderID:
            return "未知轨道"
        default:
            return providerID
        }
    }

    private static func observationComesFirst(
        _ lhs: V011ConnectionHealthObservation,
        _ rhs: V011ConnectionHealthObservation
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt > rhs.observedAt
        }
        return lhs.id < rhs.id
    }

    private static func providerSummaryComesFirst(
        _ lhs: V011ConnectionHealthProviderSummary,
        _ rhs: V011ConnectionHealthProviderSummary
    ) -> Bool {
        if lhs.isCurrent != rhs.isCurrent {
            return lhs.isCurrent
        }
        switch (lhs.latestObservation, rhs.latestObservation) {
        case let (left?, right?)
            where left.observedAt != right.observedAt:
            return left.observedAt > right.observedAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        let nameOrder = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.providerID < rhs.providerID
    }

    static func advice(
        for observation: V011ConnectionHealthObservation,
        at now: Date = Date()
    ) -> V011ConnectionHealthAdvice {
        if let failureCode = observation.failureCode {
            switch failureCode {
            case .probeFailed:
                switch observation.failureCategory {
                case .rateLimited,
                        .upstreamUnavailable,
                        .networkSecureConnectionFailed,
                        .networkTimedOut,
                        .networkUnavailable:
                    return .retryConnectionCheck
                case .authentication,
                        .permission,
                        .endpointOrModel,
                        .quotaExhausted,
                        .networkNameResolutionFailed,
                        .invalidResponse:
                    return observation.providerID == "openai"
                        ? .retryConnectionCheck
                        : .reviewRelayProfile
                case .unknown, nil:
                    break
                }
                return observation.providerID == "openai"
                    ? .retryConnectionCheck
                    : .reviewRelayProfile
            case .savedProfileMissing,
                    .savedProfileMismatch,
                    .endpointHostUnavailable:
                return .reviewRelayProfile
            case .configurationChangedDuringCheck,
                    .receiptMismatch,
                    .unavailable:
                return .refreshCurrentState
            case .sessionProviderDrift:
                return .reopenCodex
            }
        }
        switch observation.sessionProviderCheck {
        case .drifted:
            return .reopenCodex
        case .unavailable:
            return .refreshCurrentState
        case .synchronized, nil:
            break
        }
        switch observation.runtimeState {
        case .stale:
            return .reopenCodex
        case .unknown:
            return .refreshCurrentState
        case .notRunning:
            return .openCodex
        case .fresh:
            break
        }
        switch evidenceFreshness(for: observation, at: now) {
        case .fresh:
            return .none
        case .aging, .stale, .clockSkewed:
            return .retryConnectionCheck
        case .untested:
            return .refreshCurrentState
        }
    }

    static func rescueAdvice(
        hasPendingRecovery: Bool,
        needsRelayAdoption: Bool,
        latestObservation: V011ConnectionHealthObservation?,
        at now: Date = Date()
    ) -> V011ConnectionHealthAdvice {
        if hasPendingRecovery {
            return .recoverPendingSwitch
        }
        if needsRelayAdoption {
            return .reviewRelayProfile
        }
        guard let latestObservation else {
            return .retryConnectionCheck
        }
        return advice(for: latestObservation, at: now)
    }
}
