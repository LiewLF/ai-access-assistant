// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

struct V011AgentLoopRouteIdentity:
    Codable, Equatable, Sendable {
    let providerID: String
    let endpointHost: String?
    let endpointPath: String?
    let modelID: String?

    init(
        providerID: String,
        endpointHost: String?,
        endpointPath: String?,
        modelID: String?
    ) {
        self.providerID = providerID
        self.endpointHost = endpointHost
        self.endpointPath = endpointPath
        self.modelID = modelID
    }

    init(configurationData: Data) throws {
        guard let configuration = try? TOMLSemanticEngine.parse(
            String(decoding: configurationData, as: UTF8.self)
        ) else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        let providerID = (configuration.rootString(
            "model_provider"
        ) ?? "openai").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let modelID = configuration.rootString("model")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: Endpoint?
        if providerID == "openai" {
            endpoint = nil
        } else {
            guard let baseURL = configuration.string(at: [
                "model_providers", providerID, "base_url",
            ]),
            let normalized = Self.endpoint(baseURL) else {
                throw V011AgentLoopVerificationError
                    .unsafeConfiguration
            }
            endpoint = normalized
        }
        self.init(
            providerID: providerID,
            endpointHost: endpoint?.host,
            endpointPath: endpoint?.path,
            modelID: modelID?.isEmpty == false ? modelID : nil
        )
        guard isStructurallyValid else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
    }

    init?(live: LiveCodexState) {
        let providerID: String
        let endpoint: Endpoint?
        switch live.mode {
        case .official:
            providerID = "openai"
            endpoint = nil
        case let .relay(value):
            providerID = value
            guard let normalized = Self.endpoint(
                live.provider?.baseURL
            ) else { return nil }
            endpoint = normalized
        }
        self.init(
            providerID: providerID,
            endpointHost: endpoint?.host,
            endpointPath: endpoint?.path,
            modelID: live.model
        )
        guard isStructurallyValid else { return nil }
    }

    init?(profile: CodexRelayProfile) {
        guard let endpoint = Self.endpoint(
            profile.baseURL
        ) else { return nil }
        self.init(
            providerID: profile.v011ProviderID,
            endpointHost: endpoint.host,
            endpointPath: endpoint.path,
            modelID: profile.defaultModel
        )
        guard isStructurallyValid else { return nil }
    }

    var isStructurallyValid: Bool {
        Self.safeIdentifier(providerID, maximum: 256)
            && endpointHost.map(Self.safeHost) != false
            && endpointPath.map(Self.safePath) != false
            && modelID.map {
                Self.safeIdentifier($0, maximum: 512)
            } != false
            && (providerID == "openai"
                ? endpointHost == nil && endpointPath == nil
                : endpointHost != nil && endpointPath != nil)
    }

    private struct Endpoint {
        let host: String
        let path: String
    }

    private static func endpoint(_ baseURL: String?) -> Endpoint? {
        guard let baseURL,
              let components = URLComponents(string: baseURL),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        let authority = components.port.map {
            "\(host.lowercased()):\($0)"
        } ?? host.lowercased()
        let path = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        guard safePath(path) else { return nil }
        return Endpoint(host: authority, path: path)
    }

    private static func safeIdentifier(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func safeHost(_ value: String) -> Bool {
        safeIdentifier(value, maximum: 512)
            && !value.contains(where: {
                $0.isWhitespace || "/@?#\\".contains($0)
            })
    }

    private static func safePath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 2_048
            && value.hasPrefix("/")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

struct V011AgentLoopRuntimeIdentity:
    Codable, Equatable, Sendable {
    let codexAppVersion: String
    let codexAppBuild: String
    let codexCLIVersion: String
    let compatibilitySchemaID: String
    let executionProtocol: CodexAgentLoopExecutionProtocol

    init(
        codexAppVersion: String,
        codexAppBuild: String,
        codexCLIVersion: String,
        compatibilitySchemaID: String,
        executionProtocol: CodexAgentLoopExecutionProtocol
    ) {
        self.codexAppVersion = codexAppVersion
        self.codexAppBuild = codexAppBuild
        self.codexCLIVersion = codexCLIVersion
        self.compatibilitySchemaID = compatibilitySchemaID
        self.executionProtocol = executionProtocol
    }

    init?(installation: FableCodexInstallation) {
        guard let entry = installation.contractEntry,
              entry.matches(installation.identity),
              let executionProtocol =
                installation.agentLoopExecutionProtocol else {
            return nil
        }
        self.init(
            codexAppVersion: installation.identity.appVersion,
            codexAppBuild: installation.identity.appBuild,
            codexCLIVersion: installation.identity.cliVersion,
            compatibilitySchemaID: entry.schemaID,
            executionProtocol: executionProtocol
        )
        guard isStructurallyValid else { return nil }
    }

    var isStructurallyValid: Bool {
        [
            codexAppVersion,
            codexAppBuild,
            codexCLIVersion,
            compatibilitySchemaID,
        ].allSatisfy {
            !$0.isEmpty
                && $0.utf8.count <= 256
                && $0 == $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                && !$0.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
    }

    func matches(_ identity: CodexVersionIdentity) -> Bool {
        codexAppVersion == identity.appVersion
            && codexAppBuild == identity.appBuild
            && codexCLIVersion == identity.cliVersion
    }
}

struct V011AgentLoopReceipt:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let currentProbeVersion = 2

    let schemaVersion: Int
    let probeVersion: Int
    let observedAt: Date
    let expiresAt: Date
    let durationMilliseconds: Double
    let routeIdentity: V011AgentLoopRouteIdentity
    let runtimeIdentity: V011AgentLoopRuntimeIdentity
    let outcome: V011AgentLoopOutcome
    let failureStage: V011AgentLoopFailureStage?
    let toolCallCount: Int
    let requestCount: Int
    let failureReason: V011AgentLoopFailureReason?

    init(
        observedAt: Date,
        expiresAt: Date,
        durationMilliseconds: Double,
        routeIdentity: V011AgentLoopRouteIdentity,
        runtimeIdentity: V011AgentLoopRuntimeIdentity,
        outcome: V011AgentLoopOutcome,
        failureStage: V011AgentLoopFailureStage?,
        toolCallCount: Int,
        requestCount: Int = 1,
        failureReason: V011AgentLoopFailureReason? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        probeVersion = Self.currentProbeVersion
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.durationMilliseconds = durationMilliseconds
        self.routeIdentity = routeIdentity
        self.runtimeIdentity = runtimeIdentity
        self.outcome = outcome
        self.failureStage = failureStage
        self.toolCallCount = toolCallCount
        self.requestCount = requestCount
        self.failureReason = failureReason
    }

    var providerID: String { routeIdentity.providerID }
    var endpointHost: String? { routeIdentity.endpointHost }
    var endpointPath: String? { routeIdentity.endpointPath }
    var modelID: String? { routeIdentity.modelID }
    var codexAppVersion: String {
        runtimeIdentity.codexAppVersion
    }
    var codexAppBuild: String { runtimeIdentity.codexAppBuild }
    var codexCLIVersion: String {
        runtimeIdentity.codexCLIVersion
    }

    var isStructurallyValid: Bool {
        let outcomeIsValid = outcome == .passed
            ? failureStage == nil
            : failureStage != nil
        return schemaVersion == Self.currentSchemaVersion
            && probeVersion == Self.currentProbeVersion
            && observedAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt > observedAt
            && durationMilliseconds.isFinite
            && durationMilliseconds >= 0
            && routeIdentity.isStructurallyValid
            && routeIdentity.modelID != nil
            && runtimeIdentity.isStructurallyValid
            && toolCallCount >= 0
            && toolCallCount <= 32
            && requestCount == 1
            && outcomeIsValid
            && (failureReason == nil || (outcome == .failed
                && failureStage != .preparation
                && failureStage != .configurationChanged
                && failureStage != .cleanup))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func targets(_ live: LiveCodexState) -> Bool {
        guard let current = V011AgentLoopRouteIdentity(
            live: live
        ) else { return false }
        return routeIdentity == current
            && runtimeIdentity.matches(live.version)
    }
}

struct V011ReceiptFileWriter {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ data: Data, to fileURL: URL) throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            let existing = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard existing.isRegularFile == true,
                  existing.isSymbolicLink != true else {
                throw V011AgentLoopVerificationError
                    .unsafeConfiguration
            }
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let written = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard written.isRegularFile == true,
              written.isSymbolicLink != true else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
    }
}

struct V011AgentLoopReceiptStore {
    static let maximumBytes = 128 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: V011ReceiptFileWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        writer = V011ReceiptFileWriter(fileManager: fileManager)
    }

    func load() throws -> V011AgentLoopReceipt? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBytes,
              let receipt = try? JSONDecoder().decode(
                V011AgentLoopReceipt.self,
                from: Data(contentsOf: fileURL)
              ),
              receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return receipt
    }

    func commit(_ receipt: V011AgentLoopReceipt) throws {
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maximumBytes else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        try writer.write(data, to: fileURL)
    }
}
