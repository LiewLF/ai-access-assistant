// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

struct TrustedUpdatePayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let channel: String
    let product: String
    let version: String
    let build: Int
    let architecture: String
    let bundleIdentifier: String
    let minimumMacOS: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
    let publishedAtEpoch: Int64
    let expiresAtEpoch: Int64

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct TrustedUpdateEnvelope: Codable, Equatable, Sendable {
    let payload: TrustedUpdatePayload
    let keyID: String
    let signatureBase64: String
}

struct TrustedUpdatePublicKey: Equatable, Sendable {
    let keyID: String
    let x963RepresentationBase64: String
}

enum TrustedUpdateTrustConfigurationBlocker: String, Equatable, Sendable {
    case malformedDocument
    case unsupportedSchema
    case unexpectedField
    case privateSigningMaterialForbidden
    case invalidKeyID
    case duplicateKeyID
    case invalidPublicKey
    case unreadableResource
}

enum TrustedUpdateTrustConfigurationState: Equatable, Sendable {
    case unconfigured
    case configured([TrustedUpdatePublicKey])
    case blocked(TrustedUpdateTrustConfigurationBlocker)
}

enum TrustedUpdateTrustDiagnosticStatus: String, Equatable, Sendable {
    case unconfigured
    case configured
    case blocked
}

struct TrustedUpdateTrustDiagnostic: Equatable, Sendable {
    let status: TrustedUpdateTrustDiagnosticStatus
    let title: String
    let detail: String
    let symbolName: String
    let showsUpdateAction: Bool
    let networkAccessAllowed: Bool
    let automaticCheckAllowed: Bool
}

enum TrustedUpdateTrustDiagnosticResolver {
    static func resolve(
        _ state: TrustedUpdateTrustConfigurationState
    ) -> TrustedUpdateTrustDiagnostic {
        switch state {
        case .unconfigured:
            return unconfigured()
        case .configured(let keys):
            guard !keys.isEmpty else { return unconfigured() }
            return TrustedUpdateTrustDiagnostic(
                status: .configured,
                title: "更新验签公钥已配置",
                detail:
                    "已配置 \(keys.count) 个可信更新公钥。这里只显示本机配置状态；不会自动检查、下载、安装或重启。",
                symbolName: "checkmark.shield.fill",
                showsUpdateAction: false,
                networkAccessAllowed: false,
                automaticCheckAllowed: false
            )
        case .blocked(let blocker):
            return TrustedUpdateTrustDiagnostic(
                status: .blocked,
                title: "更新信任配置不可用",
                detail:
                    "更新路径已停止：\(blockerDescription(blocker))。当前版本可继续使用，不会自动联网或改动应用。",
                symbolName: "exclamationmark.shield.fill",
                showsUpdateAction: false,
                networkAccessAllowed: false,
                automaticCheckAllowed: false
            )
        }
    }

    private static func unconfigured() -> TrustedUpdateTrustDiagnostic {
        TrustedUpdateTrustDiagnostic(
            status: .unconfigured,
            title: "更新信任尚未配置",
            detail:
                "当前版本未配置可信更新公钥，不会检查、下载或安装更新；现有功能可继续使用。",
            symbolName: "shield.slash.fill",
            showsUpdateAction: false,
            networkAccessAllowed: false,
            automaticCheckAllowed: false
        )
    }

    private static func blockerDescription(
        _ blocker: TrustedUpdateTrustConfigurationBlocker
    ) -> String {
        switch blocker {
        case .malformedDocument, .unexpectedField,
             .privateSigningMaterialForbidden:
            return "配置文件内容不受支持"
        case .unsupportedSchema:
            return "配置版本不受支持"
        case .invalidKeyID:
            return "公钥标识无效"
        case .duplicateKeyID:
            return "公钥标识重复"
        case .invalidPublicKey:
            return "公钥内容无效"
        case .unreadableResource:
            return "配置文件无法读取"
        }
    }
}

enum PublicDistributionReadinessGateID:
    String, Codable, CaseIterable, Hashable, Sendable {
    case developerIDApplication = "developer_id_application"
    case appleNotarization = "apple_notarization"
    case productionUpdatePublicKey = "production_update_public_key"
    case transitiveDependencyLicenses =
        "transitive_dependency_licenses"
}

enum PublicDistributionReadinessGateStatus:
    String, Codable, Equatable, Sendable {
    case verified
    case missing
    case notVerified = "not_verified"
    case configuredUnverified = "configured_unverified"
    case incomplete
    case blocked

    var displayName: String {
        switch self {
        case .verified:
            return "已验证"
        case .missing:
            return "缺失"
        case .notVerified:
            return "未验证"
        case .configuredUnverified:
            return "已配置，未验收"
        case .incomplete:
            return "未完成"
        case .blocked:
            return "已阻断"
        }
    }

    var symbolName: String {
        switch self {
        case .verified:
            return "checkmark.circle.fill"
        case .configuredUnverified, .notVerified, .incomplete:
            return "exclamationmark.circle.fill"
        case .missing:
            return "minus.circle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }
}

struct PublicDistributionReadinessGate:
    Codable, Equatable, Identifiable, Sendable {
    let id: PublicDistributionReadinessGateID
    let status: PublicDistributionReadinessGateStatus
    let title: String
    let detail: String
    let primaryAction: String

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case title
        case detail
        case primaryAction = "primary_action"
    }
}

/// Portable source-readiness evidence only. It accepts no certificate,
/// Keychain profile, public-key bytes, filesystem path, or user-content field.
/// Build128 cannot open public distribution even when local configuration is
/// present; real signing, notarization and final-candidate acceptance remain
/// explicit release operations.
struct PublicDistributionReadinessReport:
    Codable, Equatable, Sendable {
    let schemaVersion: Int
    let channel: String
    let publicReleaseReady: Bool
    let readOnly: Bool
    let redacted: Bool
    let networkAccessAllowed: Bool
    let keychainAccessAllowed: Bool
    let signingAllowed: Bool
    let notarizationSubmissionAllowed: Bool
    let gateCount: Int
    let gapCount: Int
    let gates: [PublicDistributionReadinessGate]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case channel
        case publicReleaseReady = "public_release_ready"
        case readOnly = "read_only"
        case redacted
        case networkAccessAllowed = "network_access_allowed"
        case keychainAccessAllowed = "keychain_access_allowed"
        case signingAllowed = "signing_allowed"
        case notarizationSubmissionAllowed =
            "notarization_submission_allowed"
        case gateCount = "gate_count"
        case gapCount = "gap_count"
        case gates
    }

    init(gates: [PublicDistributionReadinessGate]) {
        schemaVersion = 1
        channel = "private-test"
        publicReleaseReady = false
        readOnly = true
        redacted = true
        networkAccessAllowed = false
        keychainAccessAllowed = false
        signingAllowed = false
        notarizationSubmissionAllowed = false
        gateCount = gates.count
        gapCount = gates.filter { $0.status != .verified }.count
        self.gates = gates
    }

    var title: String { "公开发布未就绪" }

    var detail: String {
        if gapCount > 0 {
            return "还有 \(gapCount) 项发布证据待完成；当前继续使用私有测试通道。"
        }
        return "四项基础证据已齐，仍需最终候选安装与运行验收；公开发布保持关闭。"
    }

    var symbolName: String { "shippingbox.and.arrow.backward.fill" }

    func redactedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

enum PublicDistributionReadinessResolver {
    static func sourceBaseline(
        updateTrustState: TrustedUpdateTrustConfigurationState
    ) -> PublicDistributionReadinessReport {
        PublicDistributionReadinessReport(
            gates: [
                PublicDistributionReadinessGate(
                    id: .developerIDApplication,
                    status: .notVerified,
                    title: "Developer ID Application",
                    detail: "尚未取得正式签名和验证证据；不影响当前私有测试版使用。",
                    primaryAction: "准备正式签名证书并在最终候选中验证"
                ),
                PublicDistributionReadinessGate(
                    id: .appleNotarization,
                    status: .notVerified,
                    title: "Apple公证",
                    detail: "尚未取得公证、票据装订和Gatekeeper验收证据。",
                    primaryAction: "配置公证凭据并在最终候选中提交验收"
                ),
                updatePublicKeyGate(updateTrustState),
                PublicDistributionReadinessGate(
                    id: .transitiveDependencyLicenses,
                    status: .incomplete,
                    title: "传递依赖许可证",
                    detail: "当前锁定10个直接运行依赖；完整传递依赖版权与许可证文本尚未审计。",
                    primaryAction: "补齐传递依赖清单、版权声明和许可证文本"
                ),
            ]
        )
    }

    private static func updatePublicKeyGate(
        _ state: TrustedUpdateTrustConfigurationState
    ) -> PublicDistributionReadinessGate {
        switch state {
        case .unconfigured:
            return PublicDistributionReadinessGate(
                id: .productionUpdatePublicKey,
                status: .missing,
                title: "生产更新公钥",
                detail: "尚未注入生产验签公钥；更新检查保持关闭。",
                primaryAction: "注入独立保管私钥对应的生产公钥"
            )
        case .configured(let keys):
            guard !keys.isEmpty else {
                return updatePublicKeyGate(.unconfigured)
            }
            return PublicDistributionReadinessGate(
                id: .productionUpdatePublicKey,
                status: .configuredUnverified,
                title: "生产更新公钥",
                detail: "本机验签公钥已配置，但真实签名清单和最终候选尚未验收。",
                primaryAction: "用真实签名清单完成只提示更新验收"
            )
        case .blocked:
            return PublicDistributionReadinessGate(
                id: .productionUpdatePublicKey,
                status: .blocked,
                title: "生产更新公钥",
                detail: "公钥配置异常；更新路径已停止。",
                primaryAction: "修复公钥配置后重新执行只读检查"
            )
        }
    }
}

private struct TrustedUpdateTrustConfigurationDocument: Decodable {
    let schemaVersion: Int
    let keys: [TrustedUpdateTrustConfigurationKey]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case keys
    }
}

private struct TrustedUpdateTrustConfigurationKey: Decodable {
    let keyID: String
    let x963RepresentationBase64: String

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case x963RepresentationBase64 = "x963_representation_base64"
    }
}

enum TrustedUpdateTrustStore {
    static let supportedSchema = 1
    static let productionResourceName = "TrustedUpdatePublicKeys"

    static func configurationState(
        data: Data?
    ) -> TrustedUpdateTrustConfigurationState {
        guard let data,
              !data.isEmpty,
              !data.allSatisfy({ byte in
                  byte == 9 || byte == 10 || byte == 13 || byte == 32
              }) else {
            return .unconfigured
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: []
        ),
        let dictionary = object as? [String: Any] else {
            return .blocked(.malformedDocument)
        }
        if containsPrivateSigningMaterial(in: dictionary) {
            return .blocked(.privateSigningMaterialForbidden)
        }
        guard Set(dictionary.keys) == ["schema_version", "keys"],
              let keyObjects = dictionary["keys"] as? [Any],
              keyObjects.allSatisfy({ value in
                  guard let keyDictionary = value as? [String: Any] else {
                      return false
                  }
                  return Set(keyDictionary.keys) == [
                      "key_id",
                      "x963_representation_base64",
                  ]
              }) else {
            return .blocked(.unexpectedField)
        }
        guard let document = try? JSONDecoder().decode(
            TrustedUpdateTrustConfigurationDocument.self,
            from: data
        ) else {
            return .blocked(.malformedDocument)
        }
        guard document.schemaVersion == supportedSchema else {
            return .blocked(.unsupportedSchema)
        }
        guard !document.keys.isEmpty else {
            return .unconfigured
        }

        let keys = document.keys.map { value in
            TrustedUpdatePublicKey(
                keyID: value.keyID,
                x963RepresentationBase64: value
                    .x963RepresentationBase64
            )
        }
        do {
            _ = try TrustedUpdateSignatureVerifier(keys: keys)
        } catch let error as TrustedUpdateKeyError {
            switch error {
            case .invalidKeyID:
                return .blocked(.invalidKeyID)
            case .duplicateKeyID:
                return .blocked(.duplicateKeyID)
            case .invalidPublicKey:
                return .blocked(.invalidPublicKey)
            }
        } catch {
            return .blocked(.malformedDocument)
        }
        return .configured(keys)
    }

    static func productionState(
        in bundle: Bundle = .main
    ) -> TrustedUpdateTrustConfigurationState {
        guard let url = bundle.url(
            forResource: productionResourceName,
            withExtension: "json"
        ) else {
            return .unconfigured
        }
        guard let data = try? Data(contentsOf: url) else {
            return .blocked(.unreadableResource)
        }
        return configurationState(data: data)
    }

    private static func containsPrivateSigningMaterial(
        in value: Any
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                let normalizedKey = key.lowercased().filter {
                    $0.isLetter || $0.isNumber
                }
                if normalizedKey == "privatekey"
                    || normalizedKey == "privatekeybase64"
                    || normalizedKey == "secret"
                    || normalizedKey == "seed" {
                    return true
                }
                if containsPrivateSigningMaterial(in: nestedValue) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsPrivateSigningMaterial(in: $0) }
        }
        return false
    }
}

enum TrustedUpdateKeyError: Error, Equatable {
    case invalidKeyID
    case duplicateKeyID
    case invalidPublicKey
}

enum TrustedUpdateSignatureResult: Equatable {
    case valid
    case unknownKey
    case invalidSignature
}

struct TrustedUpdateSignatureVerifier {
    private let keys: [String: P256.Signing.PublicKey]

    init(keys publicKeys: [TrustedUpdatePublicKey]) throws {
        var parsed: [String: P256.Signing.PublicKey] = [:]
        for value in publicKeys {
            guard TrustedUpdateChecker.safeKeyID(value.keyID) else {
                throw TrustedUpdateKeyError.invalidKeyID
            }
            guard parsed[value.keyID] == nil else {
                throw TrustedUpdateKeyError.duplicateKeyID
            }
            guard let data = Data(
                base64Encoded: value.x963RepresentationBase64,
                options: []
            ),
            let key = try? P256.Signing.PublicKey(
                x963Representation: data
            ) else {
                throw TrustedUpdateKeyError.invalidPublicKey
            }
            parsed[value.keyID] = key
        }
        keys = parsed
    }

    func verify(
        _ envelope: TrustedUpdateEnvelope
    ) -> TrustedUpdateSignatureResult {
        guard TrustedUpdateChecker.safeKeyID(envelope.keyID),
              let key = keys[envelope.keyID] else {
            return .unknownKey
        }
        guard let signatureData = Data(
            base64Encoded: envelope.signatureBase64,
            options: []
        ),
        let signature = try? P256.Signing.ECDSASignature(
            derRepresentation: signatureData
        ),
        let payloadData = try? envelope.payload.canonicalData(),
        key.isValidSignature(signature, for: payloadData) else {
            return .invalidSignature
        }
        return .valid
    }
}

enum TrustedUpdateBlocker: String, Codable, Equatable, Sendable {
    case malformedManifest
    case unknownSigningKey
    case invalidSignature
    case unsupportedSchema
    case productMismatch
    case channelMismatch
    case architectureMismatch
    case bundleIdentifierMismatch
    case insecureDownloadURL
    case invalidArtifactEvidence
    case invalidValidityWindow
    case manifestFromFuture
    case expiredManifest
    case rollbackBuild
    case incompatibleSystem
}

struct TrustedUpdateOffer: Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
    let expiresAtEpoch: Int64
}

enum TrustedUpdateOutcome: Equatable, Sendable {
    case noUpdate
    case prompt(TrustedUpdateOffer)
    case blocked(TrustedUpdateBlocker)
}

struct TrustedUpdateDecision: Equatable, Sendable {
    let outcome: TrustedUpdateOutcome
    let interactionMode: String
    let automaticCheckAllowed: Bool
    let automaticDownloadAllowed: Bool
    let automaticInstallAllowed: Bool
    let automaticRelaunchAllowed: Bool
    let requiresExplicitCheck: Bool
    let requiresExplicitDownloadConfirmation: Bool
    let requiresExplicitInstallConfirmation: Bool

    static func noUpdate() -> TrustedUpdateDecision {
        TrustedUpdateDecision(
            outcome: .noUpdate,
            interactionMode: "none",
            automaticCheckAllowed: false,
            automaticDownloadAllowed: false,
            automaticInstallAllowed: false,
            automaticRelaunchAllowed: false,
            requiresExplicitCheck: true,
            requiresExplicitDownloadConfirmation: false,
            requiresExplicitInstallConfirmation: false
        )
    }

    static func prompt(
        _ offer: TrustedUpdateOffer
    ) -> TrustedUpdateDecision {
        TrustedUpdateDecision(
            outcome: .prompt(offer),
            interactionMode: "prompt-only",
            automaticCheckAllowed: false,
            automaticDownloadAllowed: false,
            automaticInstallAllowed: false,
            automaticRelaunchAllowed: false,
            requiresExplicitCheck: true,
            requiresExplicitDownloadConfirmation: true,
            requiresExplicitInstallConfirmation: true
        )
    }

    static func blocked(
        _ blocker: TrustedUpdateBlocker
    ) -> TrustedUpdateDecision {
        TrustedUpdateDecision(
            outcome: .blocked(blocker),
            interactionMode: "blocked",
            automaticCheckAllowed: false,
            automaticDownloadAllowed: false,
            automaticInstallAllowed: false,
            automaticRelaunchAllowed: false,
            requiresExplicitCheck: true,
            requiresExplicitDownloadConfirmation: false,
            requiresExplicitInstallConfirmation: false
        )
    }
}

enum TrustedUpdateChecker {
    static let supportedSchema = 1
    static let stableChannel = "stable"
    static let productName = "AI接入助手"
    static let maximumArtifactBytes: Int64 = 2_147_483_648
    static let maximumValiditySeconds: Int64 = 90 * 24 * 60 * 60
    static let maximumClockSkewSeconds: Int64 = 24 * 60 * 60

    static func evaluate(
        manifestData: Data,
        installedBuild: Int,
        expectedArchitecture: String,
        expectedBundleIdentifier: String,
        hostMacOSVersion: String,
        nowEpoch: Int64,
        verifier: TrustedUpdateSignatureVerifier
    ) -> TrustedUpdateDecision {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(
            TrustedUpdateEnvelope.self,
            from: manifestData
        ) else {
            return .blocked(.malformedManifest)
        }
        switch verifier.verify(envelope) {
        case .unknownKey:
            return .blocked(.unknownSigningKey)
        case .invalidSignature:
            return .blocked(.invalidSignature)
        case .valid:
            break
        }

        let payload = envelope.payload
        guard payload.schemaVersion == supportedSchema else {
            return .blocked(.unsupportedSchema)
        }
        guard payload.product == productName else {
            return .blocked(.productMismatch)
        }
        guard payload.channel == stableChannel else {
            return .blocked(.channelMismatch)
        }
        guard payload.architecture == expectedArchitecture else {
            return .blocked(.architectureMismatch)
        }
        guard payload.bundleIdentifier == expectedBundleIdentifier else {
            return .blocked(.bundleIdentifierMismatch)
        }
        guard secureHTTPS(payload.downloadURL) else {
            return .blocked(.insecureDownloadURL)
        }
        guard payload.build > 0,
              !payload.version.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              payload.byteCount > 0,
              payload.byteCount <= maximumArtifactBytes,
              normalizedSHA256(payload.sha256) != nil else {
            return .blocked(.invalidArtifactEvidence)
        }
        let validitySeconds = payload.expiresAtEpoch
            - payload.publishedAtEpoch
        guard payload.publishedAtEpoch > 0,
              validitySeconds > 0,
              validitySeconds <= maximumValiditySeconds else {
            return .blocked(.invalidValidityWindow)
        }
        guard payload.publishedAtEpoch
            <= nowEpoch + maximumClockSkewSeconds else {
            return .blocked(.manifestFromFuture)
        }
        guard payload.expiresAtEpoch > nowEpoch else {
            return .blocked(.expiredManifest)
        }
        guard compareVersions(
            hostMacOSVersion,
            payload.minimumMacOS
        ) != .orderedAscending else {
            return .blocked(.incompatibleSystem)
        }
        if payload.build < installedBuild {
            return .blocked(.rollbackBuild)
        }
        if payload.build == installedBuild {
            return .noUpdate()
        }
        return .prompt(
            TrustedUpdateOffer(
                version: payload.version,
                build: payload.build,
                downloadURL: payload.downloadURL,
                byteCount: payload.byteCount,
                sha256: payload.sha256.lowercased(),
                expiresAtEpoch: payload.expiresAtEpoch
            )
        )
    }

    static func safeKeyID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else {
            return false
        }
        return value.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func secureHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            return false
        }
        return true
    }

    private static func normalizedSHA256(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return normalized
    }

    private static func compareVersions(
        _ left: String,
        _ right: String
    ) -> ComparisonResult {
        let leftParts = left.split(
            whereSeparator: { !$0.isNumber }
        ).compactMap { Int($0) }
        let rightParts = right.split(
            whereSeparator: { !$0.isNumber }
        ).compactMap { Int($0) }
        guard !leftParts.isEmpty, !rightParts.isEmpty else {
            return .orderedAscending
        }
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let lhs = index < leftParts.count ? leftParts[index] : 0
            let rhs = index < rightParts.count ? rightParts[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }
}
