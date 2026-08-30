// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V016SupportActionKind:
    String, Codable, Equatable, Sendable {
    case none
    case installCodex = "install_codex"
    case previewRecovery = "preview_recovery"
    case openDiagnostics = "open_diagnostics"
    case resolveFailure = "resolve_failure"
    case performDoctorAction = "perform_doctor_action"
    case refreshState = "refresh_state"
    case checkBasicConnection = "check_basic_connection"
    case verifyRealTask = "verify_real_task"
    case openCodex = "open_codex"
}

struct V016SupportAction:
    Codable, Equatable, Sendable {
    let kind: V016SupportActionKind
    let failureCode: String?
    let doctorCode: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case failureCode = "failure_code"
        case doctorCode = "doctor_code"
    }

    static func make(
        _ action: V016AccessReadinessPrimaryAction?
    ) -> Self {
        switch action {
        case nil:
            return Self(kind: .none)
        case .installCodex:
            return Self(kind: .installCodex)
        case .previewRecovery:
            return Self(kind: .previewRecovery)
        case .openDiagnostics:
            return Self(kind: .openDiagnostics)
        case let .resolveFailure(failure):
            return Self(
                kind: .resolveFailure,
                failureCode: failure.rawValue
            )
        case let .performDoctorAction(doctor):
            return Self(
                kind: .performDoctorAction,
                doctorCode: doctor.rawValue
            )
        case .refreshState:
            return Self(kind: .refreshState)
        case .checkBasicConnection:
            return Self(kind: .checkBasicConnection)
        case .verifyRealTask:
            return Self(kind: .verifyRealTask)
        case .openCodex:
            return Self(kind: .openCodex)
        }
    }

    private init(
        kind: V016SupportActionKind,
        failureCode: String? = nil,
        doctorCode: String? = nil
    ) {
        self.kind = kind
        self.failureCode = failureCode
        self.doctorCode = doctorCode
    }

    fileprivate var isValid: Bool {
        switch kind {
        case .resolveFailure:
            return failureCode.flatMap(
                V013FailurePrimaryAction.init(rawValue:)
            ) != nil && doctorCode == nil
        case .performDoctorAction:
            return doctorCode.flatMap(
                CodexDoctorPrimaryAction.init(rawValue:)
            ) != nil && failureCode == nil
        default:
            return failureCode == nil && doctorCode == nil
        }
    }
}

enum V016SupportFreshnessValue:
    String, Codable, Equatable, Sendable {
    case untested
    case fresh
    case aging
    case stale
    case clockSkewed
    case mismatched
    case cached
    case bundled
    case blocked

    static func normalized(_ value: String) -> Self {
        Self(rawValue: value) ?? .untested
    }
}

struct V016SupportEvidenceFreshness:
    Codable, Equatable, Sendable {
    let connection: V016SupportFreshnessValue
    let realTask: V016SupportFreshnessValue
    let compatibility: V016SupportFreshnessValue
    let officialUsage: V016SupportFreshnessValue

    enum CodingKeys: String, CodingKey {
        case connection
        case realTask = "real_task"
        case compatibility
        case officialUsage = "official_usage"
    }

    init(_ source: V013DiagnosticEvidenceFreshness) {
        connection = .normalized(source.connection)
        realTask = .normalized(source.agentLoop)
        compatibility = .normalized(source.compatibility)
        officialUsage = .normalized(source.officialUsage)
    }
}

struct V016SupportProductIdentity:
    Codable, Equatable, Sendable {
    let version: String
    let build: String
    let bundleClass: V011RunningBundleClass

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case bundleClass = "bundle_class"
    }

    init(_ evidence: V011RunningBuildEvidence) {
        version = Self.safeVersion(evidence.version)
        build = Self.safeBuild(evidence.build)
        bundleClass = evidence.bundleClass
    }

    private static func safeVersion(_ value: String) -> String {
        value.range(
            of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#,
            options: .regularExpression
        ) == nil ? "unknown" : value
    }

    private static func safeBuild(_ value: String) -> String {
        value.range(
            of: #"^[0-9]{1,7}$"#,
            options: .regularExpression
        ) == nil ? "unknown" : value
    }
}

struct V016SupportPrivacyBoundary:
    Codable, Equatable, Sendable {
    let credentialsIncluded = false
    let pathsIncluded = false
    let promptsIncluded = false
    let responsesIncluded = false
    let toolContentIncluded = false
    let projectContentIncluded = false
    let endpointsIncluded = false
    let customNamesIncluded = false
    let persistentIdentifiersIncluded = false
    let automaticSharing = false
    let networkActivity = false
    let localFileOnly = true

    enum CodingKeys: String, CodingKey {
        case credentialsIncluded = "credentials_included"
        case pathsIncluded = "paths_included"
        case promptsIncluded = "prompts_included"
        case responsesIncluded = "responses_included"
        case toolContentIncluded = "tool_content_included"
        case projectContentIncluded = "project_content_included"
        case endpointsIncluded = "endpoints_included"
        case customNamesIncluded = "custom_names_included"
        case persistentIdentifiersIncluded =
            "persistent_identifiers_included"
        case automaticSharing = "automatic_sharing"
        case networkActivity = "network_activity"
        case localFileOnly = "local_file_only"
    }
}

struct V016RedactedSupportBundle:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let marker = "ai_access_redacted_support_bundle"
    static let maximumDocumentBytes = 64 * 1024

    let schemaVersion: Int
    let documentMarker: String
    let exportedAt: Date
    let product: V016SupportProductIdentity
    let route: V013DiagnosticRoute
    let readinessCode: V016AccessReadinessCode
    let readinessState: V016AccessReadinessState
    let evidenceSource: V016AccessReadinessEvidenceSource
    let nextAction: V016SupportAction
    let freshness: V016SupportEvidenceFreshness
    let privacy: V016SupportPrivacyBoundary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentMarker = "marker"
        case exportedAt = "exported_at"
        case product
        case route
        case readinessCode = "readiness_code"
        case readinessState = "readiness_state"
        case evidenceSource = "evidence_source"
        case nextAction = "next_action"
        case freshness
        case privacy
    }

    func encodedData() throws -> Data {
        guard schemaVersion == Self.currentSchemaVersion,
              documentMarker == Self.marker,
              nextAction.isValid else {
            throw V016RedactedSupportBundleError.invalidDocument
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard !data.isEmpty else {
            throw V016RedactedSupportBundleError.invalidDocument
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw V016RedactedSupportBundleError.documentTooLarge
        }
        return data
    }
}

enum V016RedactedSupportBundleBuilder {
    static func make(
        decision: V016AccessReadinessDecision,
        product: V011RunningBuildEvidence,
        freshness: V013DiagnosticEvidenceFreshness,
        exportedAt: Date = Date()
    ) throws -> V016RedactedSupportBundle {
        let document = V016RedactedSupportBundle(
            schemaVersion:
                V016RedactedSupportBundle.currentSchemaVersion,
            documentMarker: V016RedactedSupportBundle.marker,
            exportedAt: Date(
                timeIntervalSince1970:
                    exportedAt.timeIntervalSince1970.rounded(.down)
            ),
            product: V016SupportProductIdentity(product),
            route: diagnosticRoute(decision.route),
            readinessCode: decision.code,
            readinessState: decision.state,
            evidenceSource: decision.evidenceSource,
            nextAction: .make(decision.primaryAction),
            freshness: V016SupportEvidenceFreshness(freshness),
            privacy: V016SupportPrivacyBoundary()
        )
        _ = try document.encodedData()
        return document
    }

    private static func diagnosticRoute(
        _ route: V015UserJourneyRoute
    ) -> V013DiagnosticRoute {
        switch route {
        case .official: return .official
        case .relay: return .relay
        case .unknown: return .unknown
        }
    }
}
