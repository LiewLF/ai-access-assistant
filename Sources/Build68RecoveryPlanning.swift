// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

enum B68RecoveryOperation: String, Codable, CaseIterable, Sendable {
    case restore
    case cleanup
    case retry
}

enum B68RecoveryIdentityState: String, Codable, CaseIterable, Sendable {
    case absent
    case present
    case unknown
}

struct B68RecoveryArtifactIdentity: Codable, Equatable, Sendable {
    let state: B68RecoveryIdentityState
    let sha256: String?
    let version: Int

    var isKnown: Bool {
        state != .unknown
            && version >= 0
            && (state == .absent || !(sha256 ?? "").isEmpty)
    }
}

enum B68RecoveryPreflightCode:
    String, Codable, CaseIterable, Sendable {
    case ready
    case invalidPlan = "invalid_plan"
    case permissionDenied = "permission_denied"
    case capacityExceeded = "capacity_exceeded"
    case sessionCoreUnavailable = "session_core_unavailable"
    case lockBusy = "lock_busy"
    case futureSchema = "future_schema"
    case thirdValueConflict = "third_value_conflict"
    case identityUnknown = "identity_unknown"
    case unmanagedWrite = "unmanaged_write"
    case confirmationRequired = "confirmation_required"
    case planHashMismatch = "plan_hash_mismatch"
    case planExpired = "plan_expired"
    case identityDrift = "identity_drift"
}

enum B68RecoveryPlanNextAction:
    String, Codable, CaseIterable, Sendable {
    case proceed
    case recheck
    case requestPermission = "request_permission"
    case freeSpace = "free_space"
    case retryLater = "retry_later"
    case updateApplication = "update_application"
    case exportDiagnostic = "export_diagnostic"
    case reviewImpact = "review_impact"
    case keepCurrent = "keep_current"
}

struct B68RecoveryPlanInput: Equatable, Sendable {
    let operationID: String
    let operation: B68RecoveryOperation
    let generation: Int
    let build: Int
    let environmentFingerprint: String
    let pointer: B68RecoveryArtifactIdentity
    let journal: B68RecoveryArtifactIdentity
    let receipt: B68RecoveryArtifactIdentity
    let estimatedReadObjects: Int
    let estimatedBytes: Int64
    let availableBytes: Int64
    let phases: [String]
    let recoveryPoint: String?
    let managedWriteSet: [String]
    let unmanagedWriteSet: [String]
    let irreversibleItems: [String]
    let irreversibleItemsConfirmed: Bool
    let permissionGranted: Bool
    let sessionCoreAvailable: Bool
    let lockAvailable: Bool
    let schemaVersion: Int
    let supportedSchemaVersion: Int
    let createdAt: Date
    let expiresAt: Date
}

struct RecoveryOperationPlan: Codable, Equatable, Sendable {
    let operationID: String
    let operation: B68RecoveryOperation
    let generation: Int
    let build: Int
    let environmentFingerprint: String
    let pointer: B68RecoveryArtifactIdentity
    let journal: B68RecoveryArtifactIdentity
    let receipt: B68RecoveryArtifactIdentity
    let estimatedReadObjects: Int
    let estimatedWriteObjects: Int
    let estimatedBytes: Int64
    let availableBytes: Int64
    let phases: [String]
    let recoveryPoint: String?
    let managedWriteSet: [String]
    let unmanagedWriteSet: [String]
    let irreversibleItems: [String]
    let irreversibleItemsConfirmed: Bool
    let blockingReasons: [B68RecoveryPreflightCode]
    let retryable: Bool
    let nextAction: B68RecoveryPlanNextAction
    let createdAt: Date
    let expiresAt: Date
    let planHash: String

    var isReady: Bool { blockingReasons.isEmpty }

    func recomputedHash() throws -> String {
        let payload = HashPayload(
            operationID: operationID,
            operation: operation,
            generation: generation,
            build: build,
            environmentFingerprint: environmentFingerprint,
            pointer: pointer,
            journal: journal,
            receipt: receipt,
            estimatedReadObjects: estimatedReadObjects,
            estimatedWriteObjects: estimatedWriteObjects,
            estimatedBytes: estimatedBytes,
            availableBytes: availableBytes,
            phases: phases,
            recoveryPoint: recoveryPoint,
            managedWriteSet: managedWriteSet,
            unmanagedWriteSet: unmanagedWriteSet,
            irreversibleItems: irreversibleItems,
            irreversibleItemsConfirmed: irreversibleItemsConfirmed,
            blockingReasons: blockingReasons,
            retryable: retryable,
            nextAction: nextAction,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct HashPayload: Codable {
        let operationID: String
        let operation: B68RecoveryOperation
        let generation: Int
        let build: Int
        let environmentFingerprint: String
        let pointer: B68RecoveryArtifactIdentity
        let journal: B68RecoveryArtifactIdentity
        let receipt: B68RecoveryArtifactIdentity
        let estimatedReadObjects: Int
        let estimatedWriteObjects: Int
        let estimatedBytes: Int64
        let availableBytes: Int64
        let phases: [String]
        let recoveryPoint: String?
        let managedWriteSet: [String]
        let unmanagedWriteSet: [String]
        let irreversibleItems: [String]
        let irreversibleItemsConfirmed: Bool
        let blockingReasons: [B68RecoveryPreflightCode]
        let retryable: Bool
        let nextAction: B68RecoveryPlanNextAction
        let createdAt: Date
        let expiresAt: Date
    }
}

struct B68RecoveryPreflightReceipt: Codable, Equatable, Sendable {
    let plan: RecoveryOperationPlan
    let code: B68RecoveryPreflightCode
    let nextAction: B68RecoveryPlanNextAction
    let observedReadObjects: Int
    let observedWriteObjects: Int

    var isReady: Bool { code == .ready && plan.isReady }
}

struct B68RecoveryImpactPreview: Codable, Equatable, Sendable {
    let plan: RecoveryOperationPlan

    var planHash: String { plan.planHash }
    var objectCount: Int { plan.estimatedWriteObjects }
    var estimatedBytes: Int64 { plan.estimatedBytes }
    var phases: [String] { plan.phases }
    var recoveryPoint: String? { plan.recoveryPoint }
    var irreversibleItems: [String] { plan.irreversibleItems }
}

struct B68RecoveryPlanBundle: Codable, Equatable, Sendable {
    let preflight: B68RecoveryPreflightReceipt
    let preview: B68RecoveryImpactPreview
}

enum B68RecoveryPlanFactory {
    static func make(_ input: B68RecoveryPlanInput) throws
        -> B68RecoveryPlanBundle {
        let reasons = blockingReasons(input)
        let primary = reasons.first ?? .ready
        let next = nextAction(for: primary)
        let retryable = isRetryable(primary)
        let draft = RecoveryOperationPlan(
            operationID: input.operationID,
            operation: input.operation,
            generation: input.generation,
            build: input.build,
            environmentFingerprint: input.environmentFingerprint,
            pointer: input.pointer,
            journal: input.journal,
            receipt: input.receipt,
            estimatedReadObjects: max(0, input.estimatedReadObjects),
            estimatedWriteObjects:
                input.managedWriteSet.count + input.unmanagedWriteSet.count,
            estimatedBytes: max(0, input.estimatedBytes),
            availableBytes: max(0, input.availableBytes),
            phases: input.phases,
            recoveryPoint: input.recoveryPoint,
            managedWriteSet: input.managedWriteSet,
            unmanagedWriteSet: input.unmanagedWriteSet,
            irreversibleItems: input.irreversibleItems,
            irreversibleItemsConfirmed: input.irreversibleItemsConfirmed,
            blockingReasons: reasons,
            retryable: retryable,
            nextAction: next,
            createdAt: input.createdAt,
            expiresAt: input.expiresAt,
            planHash: ""
        )
        let plan = RecoveryOperationPlan(
            operationID: draft.operationID,
            operation: draft.operation,
            generation: draft.generation,
            build: draft.build,
            environmentFingerprint: draft.environmentFingerprint,
            pointer: draft.pointer,
            journal: draft.journal,
            receipt: draft.receipt,
            estimatedReadObjects: draft.estimatedReadObjects,
            estimatedWriteObjects: draft.estimatedWriteObjects,
            estimatedBytes: draft.estimatedBytes,
            availableBytes: draft.availableBytes,
            phases: draft.phases,
            recoveryPoint: draft.recoveryPoint,
            managedWriteSet: draft.managedWriteSet,
            unmanagedWriteSet: draft.unmanagedWriteSet,
            irreversibleItems: draft.irreversibleItems,
            irreversibleItemsConfirmed: draft.irreversibleItemsConfirmed,
            blockingReasons: draft.blockingReasons,
            retryable: draft.retryable,
            nextAction: draft.nextAction,
            createdAt: draft.createdAt,
            expiresAt: draft.expiresAt,
            planHash: try draft.recomputedHash()
        )
        return B68RecoveryPlanBundle(
            preflight: B68RecoveryPreflightReceipt(
                plan: plan,
                code: primary,
                nextAction: next,
                observedReadObjects: plan.estimatedReadObjects,
                observedWriteObjects: 0
            ),
            preview: B68RecoveryImpactPreview(plan: plan)
        )
    }

    private static func blockingReasons(
        _ input: B68RecoveryPlanInput
    ) -> [B68RecoveryPreflightCode] {
        var reasons: [B68RecoveryPreflightCode] = []
        if input.operationID.isEmpty
            || input.generation < 1
            || input.build < 1
            || input.environmentFingerprint.isEmpty
            || input.phases.isEmpty
            || input.createdAt >= input.expiresAt
            || input.estimatedReadObjects < 0
            || input.estimatedBytes < 0
            || input.availableBytes < 0
            || ((!input.managedWriteSet.isEmpty
                || !input.unmanagedWriteSet.isEmpty)
                && (input.recoveryPoint ?? "").isEmpty) {
            reasons.append(.invalidPlan)
        }
        if !input.permissionGranted { reasons.append(.permissionDenied) }
        if !input.sessionCoreAvailable {
            reasons.append(.sessionCoreUnavailable)
        }
        if !input.lockAvailable { reasons.append(.lockBusy) }
        if input.schemaVersion > input.supportedSchemaVersion {
            reasons.append(.futureSchema)
        }
        if !input.pointer.isKnown
            || !input.journal.isKnown
            || !input.receipt.isKnown {
            reasons.append(.identityUnknown)
        }
        if input.estimatedBytes > input.availableBytes {
            reasons.append(.capacityExceeded)
        }
        if !input.unmanagedWriteSet.isEmpty {
            reasons.append(.unmanagedWrite)
        }
        if input.irreversibleItems.isEmpty == false
            && !input.irreversibleItemsConfirmed {
            reasons.append(.confirmationRequired)
        }
        return reasons
    }

    private static func nextAction(
        for code: B68RecoveryPreflightCode
    ) -> B68RecoveryPlanNextAction {
        switch code {
        case .ready:
            return .proceed
        case .permissionDenied:
            return .requestPermission
        case .capacityExceeded:
            return .freeSpace
        case .sessionCoreUnavailable, .lockBusy:
            return .retryLater
        case .futureSchema:
            return .updateApplication
        case .confirmationRequired:
            return .reviewImpact
        case .planExpired, .identityDrift:
            return .recheck
        case .thirdValueConflict, .identityUnknown,
             .unmanagedWrite, .planHashMismatch, .invalidPlan:
            return .exportDiagnostic
        }
    }

    private static func isRetryable(
        _ code: B68RecoveryPreflightCode
    ) -> Bool {
        switch code {
        case .ready, .permissionDenied, .capacityExceeded,
             .sessionCoreUnavailable, .lockBusy,
             .confirmationRequired, .planExpired, .identityDrift:
            return true
        case .invalidPlan, .futureSchema, .thirdValueConflict,
             .identityUnknown, .unmanagedWrite, .planHashMismatch:
            return false
        }
    }
}

struct B68RecoveryExecutionObservation: Equatable, Sendable {
    let planHash: String
    let generation: Int
    let build: Int
    let environmentFingerprint: String
    let pointer: B68RecoveryArtifactIdentity
    let journal: B68RecoveryArtifactIdentity
    let receipt: B68RecoveryArtifactIdentity
    let lockAvailable: Bool
    let thirdValueDetected: Bool
    let observedAt: Date
}

struct B68RecoveryExecutionDecision: Equatable, Sendable {
    let permitted: Bool
    let code: B68RecoveryPreflightCode
    let nextAction: B68RecoveryPlanNextAction
}

enum B68RecoveryPlanExecutionGuard {
    static func validate(
        plan: RecoveryOperationPlan,
        observation: B68RecoveryExecutionObservation
    ) -> B68RecoveryExecutionDecision {
        guard (try? plan.recomputedHash()) == plan.planHash,
              observation.planHash == plan.planHash else {
            return rejected(.planHashMismatch)
        }
        guard observation.observedAt < plan.expiresAt else {
            return rejected(.planExpired)
        }
        guard !observation.thirdValueDetected else {
            return rejected(.thirdValueConflict)
        }
        guard observation.lockAvailable else {
            return rejected(.lockBusy)
        }
        guard observation.generation == plan.generation,
              observation.build == plan.build,
              observation.environmentFingerprint
                == plan.environmentFingerprint,
              observation.pointer == plan.pointer,
              observation.journal == plan.journal,
              observation.receipt == plan.receipt else {
            return rejected(.identityDrift)
        }
        guard let blocker = plan.blockingReasons.first else {
            return B68RecoveryExecutionDecision(
                permitted: true,
                code: .ready,
                nextAction: .proceed
            )
        }
        return rejected(blocker)
    }

    private static func rejected(
        _ code: B68RecoveryPreflightCode
    ) -> B68RecoveryExecutionDecision {
        let action: B68RecoveryPlanNextAction
        switch code {
        case .planExpired, .identityDrift:
            action = .recheck
        case .lockBusy:
            action = .retryLater
        case .thirdValueConflict, .planHashMismatch:
            action = .exportDiagnostic
        default:
            action = .keepCurrent
        }
        return B68RecoveryExecutionDecision(
            permitted: false,
            code: code,
            nextAction: action
        )
    }
}

enum B68RecoveryAuditSource:
    String, Codable, CaseIterable, Sendable {
    case pointer
    case journal
    case receipt
    case diagnostic
}

enum B68RecoveryAuditOrder:
    String, Codable, CaseIterable, Sendable {
    case known
    case unknown
    case conflict
}

struct B68RecoveryAuditObservation: Equatable, Sendable {
    let source: B68RecoveryAuditSource
    let timestamp: Date?
    let stateCode: String
    let reference: String?
}

struct B68RecoveryAuditEvent: Codable, Equatable, Sendable,
    Identifiable {
    let source: B68RecoveryAuditSource
    let timestamp: Date?
    let stateCode: String
    let reference: String?
    let order: B68RecoveryAuditOrder

    var id: String {
        [
            source.rawValue,
            timestamp.map { String($0.timeIntervalSince1970) } ?? "none",
            stateCode,
            reference ?? "none",
        ].joined(separator: ":")
    }
}

struct B68RecoveryAuditTimeline: Codable, Equatable, Sendable {
    let events: [B68RecoveryAuditEvent]

    var copyText: String {
        let lines = events.map { event in
            let timestamp = event.timestamp.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "unknown-time"
            let reference = event.reference.map {
                " / ref=" + B68RecoveryAuditRedactor.redact($0)
            } ?? ""
            return [
                timestamp,
                event.source.rawValue,
                B68RecoveryAuditRedactor.redact(event.stateCode),
                "order=" + event.order.rawValue,
            ].joined(separator: " / ") + reference
        }
        return (["Build 68 recovery audit timeline"] + lines)
            .joined(separator: "\n")
    }
}

enum B68RecoveryAuditTimelineFactory {
    static func make(
        _ observations: [B68RecoveryAuditObservation]
    ) -> B68RecoveryAuditTimeline {
        let conflictKeys = Dictionary(grouping: observations) {
            observation in
            guard let timestamp = observation.timestamp else {
                return "missing:\(observation.source.rawValue)"
            }
            return "\(timestamp.timeIntervalSince1970):"
                + observation.source.rawValue
        }
        .filter { _, group in
            Set(group.map(\.stateCode)).count > 1
        }
        .keys

        let timestampCounts = Dictionary(grouping: observations) {
            $0.timestamp?.timeIntervalSince1970
        }.mapValues(\.count)

        let indexed = observations.enumerated().map { index, item in
            (index: index, item: item)
        }
        let sorted = indexed.sorted { lhs, rhs in
            switch (lhs.item.timestamp, rhs.item.timestamp) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.index < rhs.index
            }
        }
        let events = sorted.map { pair -> B68RecoveryAuditEvent in
            let item = pair.item
            let conflictKey: String
            if let timestamp = item.timestamp {
                conflictKey = "\(timestamp.timeIntervalSince1970):"
                    + item.source.rawValue
            } else {
                conflictKey = "missing:\(item.source.rawValue)"
            }
            let order: B68RecoveryAuditOrder
            if conflictKeys.contains(conflictKey) {
                order = .conflict
            } else if item.timestamp == nil
                || timestampCounts[item.timestamp?.timeIntervalSince1970,
                                   default: 0] > 1 {
                order = .unknown
            } else {
                order = .known
            }
            return B68RecoveryAuditEvent(
                source: item.source,
                timestamp: item.timestamp,
                stateCode: item.stateCode,
                reference: item.reference,
                order: order
            )
        }
        return B68RecoveryAuditTimeline(events: events)
    }
}

enum B68RecoveryAuditRedactor {
    static func redact(_ value: String) -> String {
        var output = value
        let replacements: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
             "[REDACTED_CREDENTIAL]"),
            (#"(?i)(token|api[_-]?key|cookie|authorization|account(?:_id)?|user(?:_id)?|session(?:_body|body))\s*[:=]\s*[^\s,;]+"#,
             "$1=[REDACTED]"),
            (#"https?://[^\s]+"#, "[REDACTED_URL]"),
            (#"(?:/Users|/private|/Volumes|/Applications|/tmp)/[^\s,;]+"#,
             "[REDACTED_PATH]"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
             "[REDACTED_ACCOUNT]"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        return output
    }
}

enum B68WarningLifecycleStatus:
    String, Codable, CaseIterable, Sendable {
    case resolved
    case active
    case recurrence
    case evidenceChanged = "evidence_changed"
    case coolingDown = "cooling_down"
}

enum B68WarningLifecycleSeverity:
    String, Codable, CaseIterable, Sendable {
    case informational
    case warning
    case blocking
}

struct B68WarningLifecycleInput: Equatable, Sendable {
    let severity: B68WarningLifecycleSeverity?
    let evidenceFingerprint: String?
    let observedAt: Date
    let dismissedFingerprint: String?
    let dismissedAt: Date?
    let cooldown: TimeInterval
}

struct B68WarningLifecycleSnapshot:
    Codable, Equatable, Sendable {
    let status: B68WarningLifecycleStatus
    let severity: B68WarningLifecycleSeverity?
    let evidenceFingerprint: String?
    let recurrenceCount: Int
    let lastEvidenceAt: Date?
    let cooldownUntil: Date?
    let primaryVisible: Bool
    let technicalVisible: Bool
}

enum B68WarningLifecycleEvaluator {
    static func evaluate(
        previous: B68WarningLifecycleSnapshot?,
        input: B68WarningLifecycleInput
    ) -> B68WarningLifecycleSnapshot {
        guard let severity = input.severity else {
            return B68WarningLifecycleSnapshot(
                status: .resolved,
                severity: nil,
                evidenceFingerprint: nil,
                recurrenceCount: previous?.recurrenceCount ?? 0,
                lastEvidenceAt: previous?.lastEvidenceAt,
                cooldownUntil: nil,
                primaryVisible: false,
                technicalVisible: true
            )
        }

        let fingerprint = input.evidenceFingerprint
        let changed = previous?.evidenceFingerprint != nil
            && previous?.evidenceFingerprint != fingerprint
        let recurred = previous?.status == .resolved
        let recurrenceCount = (previous?.recurrenceCount ?? 0)
            + (recurred ? 1 : 0)
        let cooldownUntil = input.dismissedAt.map {
            $0.addingTimeInterval(max(0, input.cooldown))
        }
        let matchingDismissal = severity != .blocking
            && fingerprint != nil
            && fingerprint == input.dismissedFingerprint
            && cooldownUntil.map { input.observedAt < $0 } == true

        let status: B68WarningLifecycleStatus
        if changed {
            status = .evidenceChanged
        } else if recurred {
            status = .recurrence
        } else if matchingDismissal {
            status = .coolingDown
        } else {
            status = .active
        }
        return B68WarningLifecycleSnapshot(
            status: status,
            severity: severity,
            evidenceFingerprint: fingerprint,
            recurrenceCount: recurrenceCount,
            lastEvidenceAt: changed || recurred
                ? input.observedAt
                : (previous?.lastEvidenceAt ?? input.observedAt),
            cooldownUntil: matchingDismissal ? cooldownUntil : nil,
            primaryVisible: severity == .blocking || !matchingDismissal,
            technicalVisible: true
        )
    }
}
