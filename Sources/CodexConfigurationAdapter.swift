// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

struct FileMetadataSnapshot: Equatable {
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
    let extendedAttributes: [String: Data]
    let accessControlList: String?

    static func capture(_ url: URL) throws -> FileMetadataSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var attributes: [String: Data] = [:]
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if length > 0 {
            var names = [CChar](repeating: 0, count: length)
            let read = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
            if read > 0 {
                var start = 0
                for index in 0..<read where names[index] == 0 {
                    let name = names[start..<index].map { UInt8(bitPattern: $0) }
                    if let key = String(bytes: name, encoding: .utf8) {
                        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
                        if size >= 0 {
                            var data = Data(count: size)
                            let copied = data.withUnsafeMutableBytes {
                                getxattr(url.path, key, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
                            }
                            if copied == size { attributes[key] = data }
                        }
                    }
                    start = index + 1
                }
            }
        }
        var aclText: String?
        if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
            var count: ssize_t = 0
            if let text = acl_to_text(acl, &count) {
                aclText = String(cString: text)
                acl_free(text)
            }
            acl_free(UnsafeMutableRawPointer(acl))
        }
        return FileMetadataSnapshot(
            permissions: info.st_mode & mode_t(0o7777),
            owner: info.st_uid,
            group: info.st_gid,
            extendedAttributes: attributes,
            accessControlList: aclText
        )
    }

    func apply(to url: URL) throws {
        guard chmod(url.path, permissions) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if chown(url.path, owner, group) != 0, errno != EPERM {
            throw CocoaError(.fileWriteUnknown)
        }
        for (name, data) in extendedAttributes {
            let result = data.withUnsafeBytes {
                setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        if let accessControlList,
           let acl = acl_from_text(accessControlList) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

enum AtomicWriteStage: String, Codable, CaseIterable {
    case beforeTemporaryWrite
    case afterTemporaryWrite
    case afterMetadataRestore
    case afterFileSync
    case beforeCompareAndSwap
    case beforeAtomicReplace
    case afterAtomicReplace
    case beforeDirectorySync
    case afterDirectorySync
    case beforeReread
}

struct CodexConfigurationAdapter {
    let codexHome: URL
    let vault: SecureProfileVault
    let allowTestRoot: Bool
    let atomicWriteFault: ((AtomicWriteStage) throws -> Void)?

    init(
        codexHome: URL,
        vault: SecureProfileVault,
        allowTestRoot: Bool = false,
        atomicWriteFault: ((AtomicWriteStage) throws -> Void)? = nil
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.vault = vault
        self.allowTestRoot = allowTestRoot
        self.atomicWriteFault = atomicWriteFault
    }

    var configURL: URL { codexHome.appendingPathComponent("config.toml") }
    var authURL: URL { codexHome.appendingPathComponent("auth.json") }

    func preflight() throws {
        if !allowTestRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            guard codexHome.path == home + "/.codex" || codexHome.path.hasPrefix(home + "/Library/Application Support/") else {
                throw CodexControlError.unsafeCodexHome
            }
        }
        for url in [configURL, authURL] where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw CodexControlError.symbolicLink(url.path) }
            guard values.isRegularFile == true else { throw CodexControlError.unsafeCodexHome }
        }
        if FileManager.default.fileExists(atPath: configURL.path) {
            try PreservingTOMLEditor.validate(String(decoding: Data(contentsOf: configURL), as: UTF8.self))
        }
    }

    func buildPlan(
        profile: CodexRelayProfile,
        allowLegacyBearerRemoval: Bool = false
    ) throws -> CodexConfigurationPlan {
        try preflight()
        let original = FileManager.default.fileExists(atPath: configURL.path)
            ? String(decoding: try Data(contentsOf: configURL), as: UTF8.self) : ""
        return try PreservingTOMLEditor.plan(
            original: original,
            profile: profile,
            allowLegacyBearerRemoval: allowLegacyBearerRemoval
        )
    }

    func createBaseline() throws -> OfficialBaseline {
        try preflight()
        try requireOfficialConfiguration(
            FileManager.default.fileExists(atPath: configURL.path)
                ? Data(contentsOf: configURL)
                : nil
        )
        let configExists = FileManager.default.fileExists(atPath: configURL.path)
        let authExists = FileManager.default.fileExists(atPath: authURL.path)
        var inputs: [SnapshotInput] = []
        if configExists {
            inputs.append(SnapshotInput(relativePath: "codex/config.toml", data: try Data(contentsOf: configURL), permissions: permissions(configURL)))
        }
        if authExists {
            inputs.append(SnapshotInput(relativePath: "codex/auth.json", data: try Data(contentsOf: authURL), permissions: permissions(authURL)))
        }
        let manifest = try vault.saveSnapshot(
            profileID: "official",
            adapterVersion: AppReleaseMetadata.version,
            inputs: inputs
        )
        return OfficialBaseline(
            codexHomePath: codexHome.path,
            snapshot: manifest,
            configExisted: configExists,
            authExisted: authExists,
            configHash: configExists ? SecureProfileVault.sha256(try Data(contentsOf: configURL)) : nil,
            authHash: authExists ? SecureProfileVault.sha256(try Data(contentsOf: authURL)) : nil,
            createdAt: Date()
        )
    }

    func createOfficialOverlay() throws -> OfficialOverlay {
        try preflight()
        let original = FileManager.default.fileExists(atPath: configURL.path)
            ? String(decoding: try Data(contentsOf: configURL), as: UTF8.self) : ""
        try requireOfficialConfiguration(Data(original.utf8))
        return try PreservingTOMLEditor.officialOverlay(from: original)
    }

    func buildOfficialPlan(
        overlay: OfficialOverlay,
        removingProviderIDs: Set<String>
    ) throws -> CodexConfigurationPlan {
        try preflight()
        let original = FileManager.default.fileExists(atPath: configURL.path)
            ? String(decoding: try Data(contentsOf: configURL), as: UTF8.self) : ""
        return try PreservingTOMLEditor.planOfficial(
            original: original,
            overlay: overlay,
            removingProviderIDs: removingProviderIDs
        )
    }

    func apply(
        _ plan: CodexConfigurationPlan,
        expectedCurrentHash: String? = nil,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        try requireIsolatedLegacyWrite()
        try preflight()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let metadata = FileManager.default.fileExists(atPath: configURL.path)
            ? try FileMetadataSnapshot.capture(configURL) : nil
        let originalData = FileManager.default.fileExists(atPath: configURL.path)
            ? try Data(contentsOf: configURL) : nil
        try beforeCommit?()
        do {
            try atomicWrite(
                Data(plan.proposed.utf8),
                to: configURL,
                metadata: metadata,
                expectedCurrentHash: expectedCurrentHash
            )
            try atomicWriteFault?(.beforeReread)
            let reread = try Data(contentsOf: configURL)
            guard String(decoding: reread, as: UTF8.self) == plan.proposed else {
                throw CodexControlError.atomicWriteFailed
            }
        } catch {
            if case CodexControlError.compareAndSwapFailed = error {
                // 外部写者已经获胜；不能用旧恢复点覆盖它。
            } else {
                try? restoreAfterFailedCommit(
                    originalData,
                    to: configURL,
                    metadata: metadata
                )
            }
            throw error
        }
    }

    func restore(_ baseline: OfficialBaseline) throws {
        try requireIsolatedLegacyWrite()
        guard baseline.codexHomePath == codexHome.path else { throw CodexControlError.baselineMissing }
        let inputs = try vault.loadSnapshot(baseline.snapshot)
        let config = inputs.first(where: { $0.relativePath == "codex/config.toml" })
        let auth = inputs.first(where: { $0.relativePath == "codex/auth.json" })
        if let config {
            try atomicWrite(
                config.data,
                to: configURL,
                metadata: metadataForLegacySnapshot(configURL, permissions: config.permissions)
            )
        }
        else if !baseline.configExisted, FileManager.default.fileExists(atPath: configURL.path) { try FileManager.default.removeItem(at: configURL) }
        if let auth {
            try atomicWrite(
                auth.data,
                to: authURL,
                metadata: metadataForLegacySnapshot(authURL, permissions: auth.permissions)
            )
        }
        else if !baseline.authExisted, FileManager.default.fileExists(atPath: authURL.path) { try FileManager.default.removeItem(at: authURL) }
    }

    func restoreAuthentication(_ baseline: OfficialBaseline) throws {
        try requireIsolatedLegacyWrite()
        guard baseline.codexHomePath == codexHome.path else { throw CodexControlError.baselineMissing }
        let inputs = try vault.loadSnapshot(baseline.snapshot)
        if let auth = inputs.first(where: { $0.relativePath == "codex/auth.json" }) {
            try atomicWrite(
                auth.data,
                to: authURL,
                metadata: metadataForLegacySnapshot(authURL, permissions: auth.permissions)
            )
        } else if !baseline.authExisted, FileManager.default.fileExists(atPath: authURL.path) {
            try FileManager.default.removeItem(at: authURL)
        }
    }

    func baselineConfigData(
        _ baseline: OfficialBaseline
    ) throws -> Data? {
        guard baseline.codexHomePath == codexHome.path else {
            throw CodexControlError.baselineMissing
        }
        return try vault.loadSnapshot(baseline.snapshot)
            .first(where: { $0.relativePath == "codex/config.toml" })?
            .data
    }

    func currentConfigHash() throws -> String? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        return SecureProfileVault.sha256(try Data(contentsOf: configURL))
    }

    func currentAuthHash() throws -> String? {
        guard FileManager.default.fileExists(atPath: authURL.path) else { return nil }
        return SecureProfileVault.sha256(try Data(contentsOf: authURL))
    }

    func currentConfigData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        return try Data(contentsOf: configURL)
    }

    func requireOfficialConfiguration(_ data: Data?) throws {
        guard let data, !data.isEmpty else { return }
        let document = try TOMLSemanticEngine.parse(
            String(decoding: data, as: UTF8.self)
        )
        let provider = document.rootString("model_provider")
        guard provider == nil || provider == "openai" else {
            throw CodexControlError.officialBaselineContainsRelay
        }
    }

    func restoreConfigData(_ data: Data?, expectedCurrentHash: String? = nil) throws {
        try requireIsolatedLegacyWrite()
        if let data {
            let metadata = FileManager.default.fileExists(atPath: configURL.path)
                ? try FileMetadataSnapshot.capture(configURL) : nil
            try atomicWrite(
                data,
                to: configURL,
                metadata: metadata,
                expectedCurrentHash: expectedCurrentHash
            )
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
            try synchronizeDirectory(configURL.deletingLastPathComponent())
        }
    }

    func manualConfigurationMatches(_ profile: CodexRelayProfile) throws -> Bool {
        try preflight()
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
        let text = String(decoding: try Data(contentsOf: configURL), as: UTF8.self)
        let providerID = profile.providerID ?? PreservingTOMLEditor.providerIdentifier(profile.id)
        let document = try TOMLSemanticEngine.parse(text)
        let command = document.string(
            at: [
                "model_providers", providerID, "auth",
                "command",
            ]
        )
        let hasForbiddenAuthentication =
            document.string(
                at: ["model_providers", providerID, "env_key"]
            ) != nil
            || document.string(
                at: [
                    "model_providers", providerID,
                    "experimental_bearer_token",
                ]
            ) != nil
        return document.rootString("model_provider") == providerID
            && document.rootString("model") == profile.defaultModel
            && document.string(
                at: ["model_providers", providerID, "base_url"]
            ) == CodexPlusPlusAdapter.cleanBaseURL(profile.baseURL)
            && command?.hasSuffix(
                PersistentCredentialBridge.helperName
            ) == true
            && !hasForbiddenAuthentication
    }

    func inspectExistingProvider(
        displayName: String? = nil
    ) throws -> ExistingProviderImportResult {
        try preflight()
        guard let originalData = try currentConfigData() else {
            throw CodexControlError.invalidProfile
        }
        let beforeHash = SecureProfileVault.sha256(originalData)
        let originalText = String(decoding: originalData, as: UTF8.self)
        let redactedText = TOMLSensitiveValueRedactor.redact(originalText)
        let document = try TOMLSemanticEngine.parse(redactedText)
        guard let providerID = document.rootString("model_provider"),
              providerID != "openai",
              let baseURL = document.string(
                  at: ["model_providers", providerID, "base_url"]
              ),
              let model = document.rootString("model"),
              !model.isEmpty else {
            throw CodexControlError.invalidProfile
        }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredName = document.string(
            at: ["model_providers", providerID, "name"]
        )
        let finalName = (name?.isEmpty == false ? name : nil)
            ?? configuredName
            ?? providerID
        let wireValue = document.string(
            at: ["model_providers", providerID, "wire_api"]
        )?.lowercased()
        let wireProtocol: RelayWireProtocol
        switch wireValue {
        case "chat", "chat_completions", "chat-completions":
            wireProtocol = .chatCompletions
        case "anthropic", "messages", "anthropic_messages":
            wireProtocol = .anthropicMessages
        default:
            wireProtocol = .responses
        }
        let effortValue = document.rootString("model_reasoning_effort")?.lowercased()
        let effort: ReasoningEffort
        switch effortValue {
        case "low": effort = .low
        case "medium": effort = .medium
        case "high": effort = .high
        case "xhigh": effort = .xhigh
        case "max": effort = .max
        case "ultra": effort = .ultra
        default: effort = .automatic
        }
        let legacyBearer = document.leaves.keys.contains {
            let components = TOMLSemanticEngine.decodePath($0)
            return components.last == "experimental_bearer_token"
                && (components.count == 1
                    || components.prefix(2).elementsEqual([
                        "model_providers", providerID,
                    ]))
        }
        let environmentKey = document.string(
            at: ["model_providers", providerID, "env_key"]
        ) != nil
        let commandAuthentication = document.leaves.keys.contains {
            let components = TOMLSemanticEngine.decodePath($0)
            return components.starts(with: [
                "model_providers", providerID, "auth",
            ])
        }
        let profile = CodexRelayProfile(
            id: providerID,
            providerID: providerID,
            name: finalName,
            baseURL: baseURL,
            wireProtocol: wireProtocol,
            models: [model],
            defaultModel: model,
            contextWindow: document.rootInteger("model_context_window"),
            autoCompactTokenLimit: document.rootInteger(
                "model_auto_compact_token_limit"
            ),
            reasoningEffort: effort
        )
        let afterData = try Data(contentsOf: configURL)
        let afterHash = SecureProfileVault.sha256(afterData)
        var warnings: [String] = []
        if legacyBearer {
            warnings.append("检测到旧Bearer字段；未读取或显示正文。迁移需单独授权。")
        }
        if !environmentKey, !commandAuthentication, !legacyBearer {
            warnings.append("未识别认证来源；接管后仍需用户在安全输入框提供Key。")
        }
        return ExistingProviderImportResult(
            profile: profile,
            report: ExistingProviderImportReport(
                providerID: providerID,
                displayName: finalName,
                configHashBefore: beforeHash,
                configHashAfter: afterHash,
                byteCount: originalData.count,
                legacyBearerFieldPresent: legacyBearer,
                environmentKeyFieldPresent: environmentKey,
                commandAuthenticationPresent: commandAuthentication,
                warnings: warnings
            )
        )
    }

    func legacyBearerForMigration(
        profile: CodexRelayProfile
    ) throws -> String {
        try preflight()
        guard let data = try currentConfigData() else {
            throw CodexControlError.invalidProfile
        }
        let document = try TOMLSemanticEngine.parse(
            String(decoding: data, as: UTF8.self)
        )
        let providerID = profile.providerID
            ?? PreservingTOMLEditor.providerIdentifier(
                profile.id
            )
        guard document.rootString("model_provider")
                == providerID,
              let secret =
                document.string(
                    at: [
                        "model_providers", providerID,
                        "experimental_bearer_token",
                    ]
                )
                ?? document.rootString(
                    "experimental_bearer_token"
                ),
              !secret.isEmpty,
              Data(secret.utf8).count
                <= PersistentCredentialBridge
                    .maximumSecretBytes else {
            throw CodexControlError.missingSecret
        }
        return secret
    }

    private func permissions(_ url: URL) -> Int {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return values?[.posixPermissions] as? Int ?? 0o600
    }

    private func requireIsolatedLegacyWrite() throws {
        guard allowTestRoot else {
            throw CodexControlError.legacyWriterDisabled
        }
    }

    private func metadataForLegacySnapshot(_ url: URL, permissions: Int) -> FileMetadataSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path),
              var metadata = try? FileMetadataSnapshot.capture(url) else {
            return nil
        }
        metadata = FileMetadataSnapshot(
            permissions: mode_t(permissions),
            owner: metadata.owner,
            group: metadata.group,
            extendedAttributes: metadata.extendedAttributes,
            accessControlList: metadata.accessControlList
        )
        return metadata
    }

    private func atomicWrite(
        _ data: Data,
        to url: URL,
        metadata: FileMetadataSnapshot?,
        expectedCurrentHash: String? = nil,
        injectFaults: Bool = true
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ai-access-\(UUID().uuidString).tmp")
        let originalData = manager.fileExists(atPath: url.path)
            ? try Data(contentsOf: url) : nil
        var didReplace = false
        do {
            if injectFaults { try atomicWriteFault?(.beforeTemporaryWrite) }
            try data.write(to: temporary, options: [])
            if injectFaults { try atomicWriteFault?(.afterTemporaryWrite) }
            if let metadata {
                try metadata.apply(to: temporary)
            } else {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            }
            if injectFaults { try atomicWriteFault?(.afterMetadataRestore) }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if injectFaults { try atomicWriteFault?(.afterFileSync) }
            if injectFaults { try atomicWriteFault?(.beforeCompareAndSwap) }
            if let expectedCurrentHash,
               try currentHash(of: url) != expectedCurrentHash {
                throw CodexControlError.compareAndSwapFailed
            }
            if injectFaults { try atomicWriteFault?(.beforeAtomicReplace) }
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            didReplace = true
            if injectFaults { try atomicWriteFault?(.afterAtomicReplace) }
            if injectFaults { try atomicWriteFault?(.beforeDirectorySync) }
            try synchronizeDirectory(url.deletingLastPathComponent())
            if injectFaults { try atomicWriteFault?(.afterDirectorySync) }
        } catch {
            try? manager.removeItem(at: temporary)
            if didReplace {
                try? restoreAfterFailedCommit(
                    originalData,
                    to: url,
                    metadata: metadata
                )
            }
            throw error
        }
    }

    private func restoreAfterFailedCommit(
        _ originalData: Data?,
        to url: URL,
        metadata: FileMetadataSnapshot?
    ) throws {
        if let originalData {
            try atomicWrite(
                originalData,
                to: url,
                metadata: metadata,
                injectFaults: false
            )
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func currentHash(of url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return SecureProfileVault.sha256(try Data(contentsOf: url))
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
