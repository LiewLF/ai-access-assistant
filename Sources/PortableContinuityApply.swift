// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

enum PortableContinuityApplyError: LocalizedError, Equatable {
    case confirmationRequired
    case sourceChanged
    case targetChanged
    case previewChanged
    case pendingRecovery
    case nothingSelected
    case invalidDecision
    case credentialRequired
    case activeProfile
    case referencedProfile
    case invalidWorkspaceTarget
    case stateChanged
    case invalidJournal
    case recoveryRequired
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "请先确认本次导入范围"
        case .sourceChanged:
            return "迁移设置文件已变化；请重新预检"
        case .targetChanged:
            return "当前设置已变化；请重新预检"
        case .previewChanged:
            return "预检结果已变化；请重新查看后确认"
        case .pendingRecovery:
            return "发现未完成的迁移导入；请先恢复"
        case .nothingSelected:
            return "尚未选择要导入的中转或工作区标签"
        case .invalidDecision:
            return "导入选择与预检内容不一致"
        case .credentialRequired:
            return "每条要导入的中转都必须重新输入凭据"
        case .activeProfile:
            return "当前正在使用这条中转；请先切到官方或另一条中转"
        case .referencedProfile:
            return "这条中转仍被恢复记录引用；请先完成安全切换"
        case .invalidWorkspaceTarget:
            return "请选择当前设备已收藏的目标工作区"
        case .stateChanged:
            return "导入期间当前设置被其他操作改变，已停止"
        case .invalidJournal:
            return "迁移导入恢复记录无法安全读取"
        case .recoveryRequired:
            return "导入已进入恢复阶段；请使用恢复入口完成收尾"
        case .rollbackFailed:
            return "导入未完成，自动恢复也未完成；恢复记录已保留"
        }
    }
}

struct PortableContinuityImportSession: Equatable, Sendable {
    let sourceURL: URL
    let sourceSHA256: String
    let expectedStateSHA256: String?
    let expectedWorkspaceSHA256: String?
    let previewSHA256: String
    let targetVersion: String
    let targetBuild: String
    let targetPlatform: PortableSourcePlatform
    let protectedProviderID: String?
    let manifest: PortableContinuityManifest
    let preview: PortableContinuityImportPreview
}

struct PortableContinuityRelayDecision: Equatable, Sendable {
    let sourceID: UUID
    let targetProfileID: String?
    let useIncomingDisplayName: Bool
    let useIncomingBaseURL: Bool
    let useIncomingDefaultModel: Bool
    let credential: String
}

struct PortableContinuityWorkspaceDecision: Equatable, Sendable {
    let sourceID: UUID
    let targetPath: String
}

struct PortableContinuityApplyRequest: Equatable, Sendable {
    let session: PortableContinuityImportSession
    let relayDecisions: [PortableContinuityRelayDecision]
    let workspaceDecisions: [PortableContinuityWorkspaceDecision]
    let userConfirmed: Bool
}

struct PortableContinuityApplyResult: Equatable, Sendable {
    let importedRelayCount: Int
    let mappedWorkspaceCount: Int
    let transactionID: String
    let continuation: PortableContinuityContinuation
}

enum PortableContinuityApplyFaultPoint: String, Sendable {
    case prepared
    case credentialsStaged
    case stateApplied
    case workspaceApplied
    case credentialApplied
    case applied
}

enum PortableContinuityApplyPhase: String, Codable, Sendable {
    case prepared
    case credentialsStaged
    case stateApplied
    case workspaceApplied
    case credentialsApplying
    case applied
    case committed
    case rollbackRequired
    case rolledBack
    case rollbackFailed

    var isPending: Bool {
        ![.committed, .rolledBack].contains(self)
    }
}

struct PortableContinuityCredentialJournal: Codable, Equatable, Sendable {
    let finalReference: String
    let stagingReference: String
    let backupReference: String
    let previousExisted: Bool
    let previousSHA256: String?
    let incomingSHA256: String
}

struct PortableContinuityApplyJournal:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let version: Int
    let id: String
    let controlRootPath: String
    let sourceSHA256: String
    let previewSHA256: String
    let sourceStateSHA256: String?
    let targetStateSHA256: String?
    let sourceStateExisted: Bool
    let targetStateExisted: Bool
    let sourceWorkspaceSHA256: String?
    let targetWorkspaceSHA256: String?
    let sourceWorkspaceExisted: Bool
    let targetWorkspaceExisted: Bool
    let credentialChanges: [PortableContinuityCredentialJournal]
    let snapshot: SnapshotManifest
    let importedRelayCount: Int
    let mappedWorkspaceCount: Int
    let startedAt: Date
    var updatedAt: Date
    var phase: PortableContinuityApplyPhase
    var message: String
}

struct PortableContinuityApplyJournalStore {
    let rootURL: URL

    func save(_ journal: PortableContinuityApplyJournal) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = url(journal.id)
        try SessionSyncAtomicFile.write(
            encoder.encode(journal),
            to: file,
            expectedHash: SessionSyncFileSafety.hashIfPresent(file),
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func pending() throws -> [PortableContinuityApplyJournal] {
        try all().filter(\.phase.isPending)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func all() throws -> [PortableContinuityApplyJournal] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }
        try prepareRoot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [
                .skipsHiddenFiles,
                .skipsSubdirectoryDescendants,
            ]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .map { file in
            try SessionSyncFileSafety.requireRegularFile(file)
            let journal = try decoder.decode(
                PortableContinuityApplyJournal.self,
                from: Data(contentsOf: file)
            )
            guard journal.version == 1,
                file.lastPathComponent == "\(journal.id).json"
            else {
                throw PortableContinuityApplyError.invalidJournal
            }
            return journal
        }
    }

    private func prepareRoot() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw PortableContinuityApplyError.invalidJournal
            }
        } else {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func url(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }
}

private struct PortableContinuityWorkspaceDocument: Codable, Equatable {
    let schemaVersion: Int
    let paths: [String]
    let labels: [String: String]?

    static let empty = PortableContinuityWorkspaceDocument(
        schemaVersion: 2,
        paths: [],
        labels: [:]
    )
}

private struct PortableContinuityWorkspaceStore {
    let fileURL: URL

    func load() throws -> PortableContinuityWorkspaceDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let document = try JSONDecoder().decode(
            PortableContinuityWorkspaceDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard [1, 2].contains(document.schemaVersion),
            document.paths.count <= 20,
            Set(document.paths).count == document.paths.count,
            (document.labels ?? [:]).keys.allSatisfy({
                document.paths.contains($0)
            })
        else {
            throw PortableContinuityApplyError.invalidWorkspaceTarget
        }
        return document
    }

    func preparedData(
        paths: [String],
        labels: [String: String]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(
            PortableContinuityWorkspaceDocument(
                schemaVersion: 2,
                paths: paths,
                labels: labels
            )
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return encoded
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        return try preservingUnknownJSONFields(
            encoded,
            from: Data(contentsOf: fileURL),
            knownRootKeys: ["schemaVersion", "paths", "labels"]
        )
    }

    func writePrepared(_ data: Data, expectedHash: String?) throws {
        try SessionSyncAtomicFile.write(
            data,
            to: fileURL,
            expectedHash: expectedHash,
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func restore(
        _ data: Data?,
        expectedCurrentHash: String?
    ) throws {
        if let data {
            try writePrepared(data, expectedHash: expectedCurrentHash)
            return
        }
        guard SessionSyncFileSafety.hashIfPresent(fileURL)
            == expectedCurrentHash
        else {
            throw PortableContinuityApplyError.stateChanged
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try synchronizeParentDirectory()
    }

    private func synchronizeParentDirectory() throws {
        let descriptor = Darwin.open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PortableContinuityApplyError.stateChanged
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PortableContinuityApplyError.stateChanged
        }
    }
}

private struct PortableContinuityApplyBaseline {
    let state: V011ManagedState
    let stateData: Data?
    let stateSHA256: String?
    let workspace: PortableContinuityWorkspaceDocument
    let workspaceData: Data?
    let workspaceSHA256: String?
}

private struct PortableContinuityPreparedApply {
    let targetState: V011ManagedState
    let targetStateData: Data?
    let targetWorkspaceData: Data?
    let targetWorkspace: PortableContinuityWorkspaceDocument
    let credentials: [(profile: CodexRelayProfile, secret: String)]
    let importedRelayCount: Int
    let mappedWorkspaceCount: Int
}

struct PortableContinuityImportCoordinator: @unchecked Sendable {
    let controlRoot: URL
    let credentialStore: any FableCredentialStore
    let keyProvider: () throws -> Data
    let faultInjector:
        (PortableContinuityApplyFaultPoint) throws -> Void

    init(
        controlRoot: URL,
        credentialStore: any FableCredentialStore,
        keyProvider: @escaping () throws -> Data,
        faultInjector: @escaping
            (PortableContinuityApplyFaultPoint) throws -> Void = { _ in }
    ) {
        self.controlRoot = controlRoot.standardizedFileURL
        self.credentialStore = credentialStore
        self.keyProvider = keyProvider
        self.faultInjector = faultInjector
    }

    var journalStore: PortableContinuityApplyJournalStore {
        PortableContinuityApplyJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "PortableContinuityImportTransactions",
                isDirectory: true
            )
        )
    }

    func prepare(
        sourceURL: URL,
        targetVersion: String,
        targetBuild: String,
        targetPlatform: PortableSourcePlatform,
        protectedProviderID: String?
    ) throws -> PortableContinuityImportSession {
        try requireNoPendingTransaction()
        let source = try PortableContinuityImportFileReader.document(
            from: sourceURL
        )
        let baseline = try loadBaseline()
        let preview = PortableContinuityImportPreflight.inspect(
            manifest: source.manifest,
            target: targetState(baseline),
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            targetPlatform: targetPlatform
        )
        return PortableContinuityImportSession(
            sourceURL: sourceURL.standardizedFileURL,
            sourceSHA256: SecureProfileVault.sha256(source.data),
            expectedStateSHA256: baseline.stateSHA256,
            expectedWorkspaceSHA256: baseline.workspaceSHA256,
            previewSHA256: previewFingerprint(preview),
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            targetPlatform: targetPlatform,
            protectedProviderID: protectedProviderID,
            manifest: source.manifest,
            preview: preview
        )
    }

    func apply(
        _ request: PortableContinuityApplyRequest
    ) throws -> PortableContinuityApplyResult {
        guard request.userConfirmed else {
            throw PortableContinuityApplyError.confirmationRequired
        }
        try requireNoPendingTransaction()
        let freshData: Data
        do {
            freshData = try PortableContinuityImportFileReader.data(
                from: request.session.sourceURL
            )
        } catch {
            throw PortableContinuityApplyError.sourceChanged
        }
        guard SecureProfileVault.sha256(freshData)
                == request.session.sourceSHA256 else {
            throw PortableContinuityApplyError.sourceChanged
        }
        let freshManifest: PortableContinuityManifest
        do {
            freshManifest = try PortableContinuityManifest
                .decodeStrict(freshData)
        } catch {
            throw PortableContinuityApplyError.sourceChanged
        }
        guard freshManifest == request.session.manifest else {
            throw PortableContinuityApplyError.sourceChanged
        }
        let baseline = try loadBaseline()
        guard baseline.stateSHA256
                == request.session.expectedStateSHA256,
            baseline.workspaceSHA256
                == request.session.expectedWorkspaceSHA256
        else {
            throw PortableContinuityApplyError.targetChanged
        }
        let freshPreview = PortableContinuityImportPreflight.inspect(
            manifest: freshManifest,
            target: targetState(baseline),
            targetVersion: request.session.targetVersion,
            targetBuild: request.session.targetBuild,
            targetPlatform: request.session.targetPlatform
        )
        guard previewFingerprint(freshPreview)
                == request.session.previewSHA256
        else {
            throw PortableContinuityApplyError.previewChanged
        }
        let prepared = try prepareTarget(
            request: request,
            baseline: baseline
        )
        let continuation = try PortableContinuityMigrationContract
            .evaluate(
                manifest: freshManifest,
                targetVersion: request.session.targetVersion,
                targetBuild: request.session.targetBuild,
                before: baseline.state,
                after: prepared.targetState,
                importedProfiles: prepared.credentials.map(\.profile),
                importedRelayCount: prepared.importedRelayCount
            )
        let transactionID = UUID().uuidString.lowercased()
        let credentialMaterial = try credentialMaterial(
            prepared.credentials,
            transactionID: transactionID
        )
        let snapshot = try vault.saveSnapshot(
            profileID: "portable-import-\(transactionID)",
            adapterVersion: "0.12.0-build132",
            inputs: snapshotInputs(
                baseline: baseline,
                prepared: prepared
            )
        )
        let targetStateSHA = prepared.targetStateData.map(
            SecureProfileVault.sha256
        )
        let targetWorkspaceSHA = prepared.targetWorkspaceData.map(
            SecureProfileVault.sha256
        )
        let now = Date()
        var journal = PortableContinuityApplyJournal(
            version: 1,
            id: transactionID,
            controlRootPath: controlRoot.path,
            sourceSHA256: request.session.sourceSHA256,
            previewSHA256: request.session.previewSHA256,
            sourceStateSHA256: baseline.stateSHA256,
            targetStateSHA256: targetStateSHA,
            sourceStateExisted: baseline.stateData != nil,
            targetStateExisted: prepared.targetStateData != nil,
            sourceWorkspaceSHA256: baseline.workspaceSHA256,
            targetWorkspaceSHA256: targetWorkspaceSHA,
            sourceWorkspaceExisted: baseline.workspaceData != nil,
            targetWorkspaceExisted:
                prepared.targetWorkspaceData != nil,
            credentialChanges: credentialMaterial.records,
            snapshot: snapshot,
            importedRelayCount: prepared.importedRelayCount,
            mappedWorkspaceCount: prepared.mappedWorkspaceCount,
            startedAt: now,
            updatedAt: now,
            phase: .prepared,
            message: "已建立迁移导入恢复点"
        )
        do {
            try journalStore.save(journal)
        } catch {
            try? vault.deleteSnapshot(snapshot)
            throw error
        }

        do {
            try faultInjector(.prepared)
            try stageCredentials(credentialMaterial)
            try update(
                &journal,
                phase: .credentialsStaged,
                message: "凭据已暂存，尚未替换目标凭据"
            )
            try faultInjector(.credentialsStaged)
            try writeTargetState(
                prepared.targetStateData,
                sourceHash: baseline.stateSHA256,
                targetHash: targetStateSHA
            )
            try update(
                &journal,
                phase: .stateApplied,
                message: "中转资料已写入，恢复点仍保留"
            )
            try faultInjector(.stateApplied)
            try writeTargetWorkspace(
                prepared.targetWorkspaceData,
                sourceHash: baseline.workspaceSHA256,
                targetHash: targetWorkspaceSHA
            )
            try update(
                &journal,
                phase: .workspaceApplied,
                message: "工作区映射已写入，恢复点仍保留"
            )
            try faultInjector(.workspaceApplied)
            try update(
                &journal,
                phase: .credentialsApplying,
                message: "正在替换目标凭据"
            )
            try applyFinalCredentials(credentialMaterial)
            try faultInjector(.credentialApplied)
            try update(
                &journal,
                phase: .applied,
                message: "导入已应用，正在清理临时凭据"
            )
            try faultInjector(.applied)
        } catch {
            do {
                try update(
                    &journal,
                    phase: .rollbackRequired,
                    message: "导入未完成，正在恢复写入前状态"
                )
                try rollback(&journal)
            } catch {
                try? update(
                    &journal,
                    phase: .rollbackFailed,
                    message: "自动恢复未完成"
                )
                throw PortableContinuityApplyError.rollbackFailed
            }
            throw error
        }

        do {
            try finalizeApplied(&journal)
        } catch {
            throw PortableContinuityApplyError.recoveryRequired
        }
        return PortableContinuityApplyResult(
            importedRelayCount: prepared.importedRelayCount,
            mappedWorkspaceCount: prepared.mappedWorkspaceCount,
            transactionID: transactionID,
            continuation: continuation
        )
    }

    func recoverPending() throws -> Int {
        var count = 0
        for var journal in try journalStore.pending() {
            guard journal.controlRootPath == controlRoot.path else {
                throw PortableContinuityApplyError.invalidJournal
            }
            do {
                if journal.phase == .applied {
                    try finalizeApplied(&journal)
                } else {
                    try rollback(&journal)
                }
                count += 1
            } catch {
                try? update(
                    &journal,
                    phase: .rollbackFailed,
                    message: "迁移导入恢复仍未完成"
                )
                throw PortableContinuityApplyError.rollbackFailed
            }
        }
        return count
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(fileURL: stateURL)
    }

    private var stateURL: URL {
        controlRoot
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private var workspaceStore: PortableContinuityWorkspaceStore {
        PortableContinuityWorkspaceStore(
            fileURL: controlRoot.appendingPathComponent(
                "workspace-favorites.json"
            )
        )
    }

    private var vault: SecureProfileVault {
        SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "PortableContinuityImportVault",
                isDirectory: true
            ),
            keyProvider: keyProvider
        )
    }

    private func requireNoPendingTransaction() throws {
        guard try journalStore.pending().isEmpty else {
            throw PortableContinuityApplyError.pendingRecovery
        }
    }

    private func loadBaseline() throws
        -> PortableContinuityApplyBaseline {
        let stateData: Data?
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try SessionSyncFileSafety.requireRegularFile(stateURL)
            stateData = try Data(contentsOf: stateURL)
        } else {
            stateData = nil
        }
        let workspaceURL = workspaceStore.fileURL
        let workspaceData: Data?
        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            try SessionSyncFileSafety.requireRegularFile(workspaceURL)
            workspaceData = try Data(contentsOf: workspaceURL)
        } else {
            workspaceData = nil
        }
        return PortableContinuityApplyBaseline(
            state: try stateStore.load(),
            stateData: stateData,
            stateSHA256: stateData.map(SecureProfileVault.sha256),
            workspace: try workspaceStore.load(),
            workspaceData: workspaceData,
            workspaceSHA256:
                workspaceData.map(SecureProfileVault.sha256)
        )
    }

    private func targetState(
        _ baseline: PortableContinuityApplyBaseline
    ) -> PortableContinuityTargetState {
        PortableContinuityTargetState(
            relayProfiles: baseline.state.relayProfiles.map {
                PortableContinuityTargetProfile(
                    displayName: $0.name,
                    baseURL: $0.baseURL,
                    defaultModel: $0.defaultModel,
                    usesResponsesAPI:
                        $0.wireProtocol == .responses
                )
            },
            workspaceLabels: Array(
                (baseline.workspace.labels ?? [:]).values
            ),
            startDestination: nil,
            historyGrouping: nil
        )
    }

    private func previewFingerprint(
        _ preview: PortableContinuityImportPreview
    ) -> String {
        let changes = preview.changes.sorted { $0.id < $1.id }.map {
            [
                $0.id,
                $0.scope.rawValue,
                $0.recordTitle,
                $0.field.rawValue,
                $0.incomingValue,
                $0.currentValue ?? "<nil>",
                $0.disposition.rawValue,
                $0.detail,
            ].joined(separator: "\u{1f}")
        }
        let value = (
            [
                preview.sourceVersion,
                preview.sourceBuild,
                preview.sourcePlatform.rawValue,
                preview.writesAllowed ? "write" : "read-only",
            ] + preview.warnings.sorted() + changes
        ).joined(separator: "\u{1e}")
        return SecureProfileVault.sha256(Data(value.utf8))
    }

    private func prepareTarget(
        request: PortableContinuityApplyRequest,
        baseline: PortableContinuityApplyBaseline
    ) throws -> PortableContinuityPreparedApply {
        guard !request.relayDecisions.isEmpty
                || !request.workspaceDecisions.isEmpty else {
            throw PortableContinuityApplyError.nothingSelected
        }
        guard Set(request.relayDecisions.map(\.sourceID)).count
                == request.relayDecisions.count,
            Set(request.workspaceDecisions.map(\.sourceID)).count
                == request.workspaceDecisions.count
        else {
            throw PortableContinuityApplyError.invalidDecision
        }

        var state = baseline.state
        var credentials: [(CodexRelayProfile, String)] = []
        var targetProfileIDs = Set<String>()
        for decision in request.relayDecisions {
            guard let source = request.session.manifest.accessProfiles
                .first(where: {
                    $0.id == decision.sourceID && $0.kind == .relay
                }),
                let incomingURL = source.baseURL,
                let incomingModel = source.defaultModel
            else {
                throw PortableContinuityApplyError.invalidDecision
            }
            let secret = try validatedCredential(decision.credential)
            let profile: CodexRelayProfile
            if let targetID = decision.targetProfileID {
                guard targetProfileIDs.insert(targetID).inserted,
                    let current = state.relayProfiles.first(where: {
                        $0.id == targetID
                    })
                else {
                    throw PortableContinuityApplyError.invalidDecision
                }
                try requireImportable(
                    current,
                    state: state,
                    protectedProviderID:
                        request.session.protectedProviderID
                )
                let name = decision.useIncomingDisplayName
                    ? source.displayName : current.name
                let baseURL = decision.useIncomingBaseURL
                    ? incomingURL : current.baseURL
                let defaultModel = decision.useIncomingDefaultModel
                    ? incomingModel : current.defaultModel
                var models = current.models
                if !models.contains(defaultModel) {
                    models.append(defaultModel)
                }
                let endpointChanged = baseURL != current.baseURL
                profile = CodexRelayProfile(
                    id: current.id,
                    providerID: current.providerID,
                    name: name,
                    baseURL: baseURL,
                    wireProtocol: .responses,
                    models: models,
                    defaultModel: defaultModel,
                    contextWindow: endpointChanged
                        ? nil : current.contextWindow,
                    autoCompactTokenLimit: endpointChanged
                        ? nil : current.autoCompactTokenLimit,
                    reasoningEffort: current.reasoningEffort,
                    localGatewayConfirmed: endpointChanged
                        ? nil : current.localGatewayConfirmed,
                    catalogEntryID: endpointChanged
                        ? nil : current.catalogEntryID,
                    capabilityProfile: endpointChanged
                        ? nil : current.capabilityProfile,
                    additionalFields: endpointChanged
                        ? [:] : current.additionalFields
                )
            } else {
                guard decision.useIncomingDisplayName,
                    decision.useIncomingBaseURL,
                    decision.useIncomingDefaultModel,
                    !state.relayProfiles.contains(where: {
                        normalizedName($0.name)
                                == normalizedName(source.displayName)
                            || canonicalEndpoint($0.baseURL)
                                == canonicalEndpoint(incomingURL)
                    })
                else {
                    throw PortableContinuityApplyError.invalidDecision
                }
                profile = try importedProfile(
                    source,
                    state: state
                )
            }
            state.upsert(profile)
            if state.lastVerifiedProviderID
                == profile.v011ProviderID {
                state.lastVerifiedProviderID = nil
                state.lastVerifiedConfigHash = nil
                state.lastVerifiedAt = nil
            }
            credentials.append((profile, secret))
        }

        var labels = baseline.workspace.labels ?? [:]
        let paths = baseline.workspace.paths
        var mappedPaths = Set<String>()
        for decision in request.workspaceDecisions {
            guard let source = request.session.manifest.workspaceLabels
                .first(where: { $0.id == decision.sourceID }),
                paths.contains(decision.targetPath),
                mappedPaths.insert(decision.targetPath).inserted
            else {
                throw PortableContinuityApplyError.invalidWorkspaceTarget
            }
            labels[decision.targetPath] = source.label
        }

        let targetStateData: Data?
        if request.relayDecisions.isEmpty {
            targetStateData = baseline.stateData
        } else {
            targetStateData = try stateStore.preparedData(for: state)
        }
        let targetWorkspaceData: Data?
        if request.workspaceDecisions.isEmpty {
            targetWorkspaceData = baseline.workspaceData
        } else {
            targetWorkspaceData = try workspaceStore.preparedData(
                paths: paths,
                labels: labels
            )
        }
        return PortableContinuityPreparedApply(
            targetState: state,
            targetStateData: targetStateData,
            targetWorkspaceData: targetWorkspaceData,
            targetWorkspace: PortableContinuityWorkspaceDocument(
                schemaVersion: 2,
                paths: paths,
                labels: labels
            ),
            credentials: credentials,
            importedRelayCount: request.relayDecisions.count,
            mappedWorkspaceCount: request.workspaceDecisions.count
        )
    }

    private func requireImportable(
        _ profile: CodexRelayProfile,
        state: V011ManagedState,
        protectedProviderID: String?
    ) throws {
        guard profile.v011ProviderID != protectedProviderID,
            state.activeProfileID != profile.id
        else {
            throw PortableContinuityApplyError.activeProfile
        }
        guard state.activeCutoverConfiguration?.profileID
                != profile.id,
            state.activeCutoverConfiguration?.providerID
                != profile.v011ProviderID,
            state.lastKnownGoodCutoverConfiguration?.profileID
                != profile.id,
            state.lastKnownGoodCutoverConfiguration?.providerID
                != profile.v011ProviderID
        else {
            throw PortableContinuityApplyError.referencedProfile
        }
    }

    private func importedProfile(
        _ source: PortableAccessProfile,
        state: V011ManagedState
    ) throws -> CodexRelayProfile {
        guard let baseURL = source.baseURL,
            let defaultModel = source.defaultModel
        else {
            throw PortableContinuityApplyError.invalidDecision
        }
        let seed = "\(source.id.uuidString.lowercased())|\(baseURL)"
        let suffix = String(
            SecureProfileVault.sha256(Data(seed.utf8)).prefix(12)
        )
        let id = "relay-import-\(suffix)"
        let providerID = PreservingTOMLEditor.providerIdentifier(
            source.displayName
        ) + "_" + suffix
        guard !state.relayProfiles.contains(where: {
            $0.id == id || $0.v011ProviderID == providerID
        }) else {
            throw PortableContinuityApplyError.invalidDecision
        }
        return CodexRelayProfile(
            id: id,
            providerID: providerID,
            name: source.displayName,
            baseURL: baseURL,
            wireProtocol: .responses,
            models: [defaultModel],
            defaultModel: defaultModel,
            contextWindow: nil,
            autoCompactTokenLimit: nil,
            reasoningEffort: .medium
        )
    }

    private func validatedCredential(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let data = Data(normalized.utf8)
        guard !data.isEmpty,
            data.count <= FableMacOSKeychainCredentialStore
                .maximumSecretBytes,
            !normalized.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            })
        else {
            throw PortableContinuityApplyError.credentialRequired
        }
        return normalized
    }

    private func canonicalEndpoint(_ value: String) -> String {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme,
            let host = components.host
        else {
            return value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }

    private func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private struct CredentialMaterial {
        let records: [PortableContinuityCredentialJournal]
        let incomingByStagingReference: [String: String]
        let previousByBackupReference: [String: String]
    }

    private func credentialMaterial(
        _ credentials: [(profile: CodexRelayProfile, secret: String)],
        transactionID: String
    ) throws -> CredentialMaterial {
        var records: [PortableContinuityCredentialJournal] = []
        var incoming: [String: String] = [:]
        var previous: [String: String] = [:]
        for (index, item) in credentials.enumerated() {
            let final = item.profile.v011CredentialReference
            let stage = "portable-import/\(transactionID)/stage/\(index)"
            let backup = "portable-import/\(transactionID)/backup/\(index)"
            let old = try credentialStore.secret(reference: final)
            records.append(
                PortableContinuityCredentialJournal(
                    finalReference: final,
                    stagingReference: stage,
                    backupReference: backup,
                    previousExisted: old != nil,
                    previousSHA256: old.map {
                        SecureProfileVault.sha256(Data($0.utf8))
                    },
                    incomingSHA256: SecureProfileVault.sha256(
                        Data(item.secret.utf8)
                    )
                )
            )
            incoming[stage] = item.secret
            if let old { previous[backup] = old }
        }
        return CredentialMaterial(
            records: records,
            incomingByStagingReference: incoming,
            previousByBackupReference: previous
        )
    }

    private func snapshotInputs(
        baseline: PortableContinuityApplyBaseline,
        prepared: PortableContinuityPreparedApply
    ) -> [SnapshotInput] {
        [
            SnapshotInput(
                relativePath: "state-before.json",
                data: baseline.stateData ?? Data(),
                permissions: 0o600
            ),
            SnapshotInput(
                relativePath: "state-after.json",
                data: prepared.targetStateData ?? Data(),
                permissions: 0o600
            ),
            SnapshotInput(
                relativePath: "workspace-before.json",
                data: baseline.workspaceData ?? Data(),
                permissions: 0o600
            ),
            SnapshotInput(
                relativePath: "workspace-after.json",
                data: prepared.targetWorkspaceData ?? Data(),
                permissions: 0o600
            ),
        ]
    }

    private func stageCredentials(_ material: CredentialMaterial) throws {
        for record in material.records {
            if let previous = material.previousByBackupReference[
                record.backupReference
            ] {
                try credentialStore.store(
                    previous,
                    reference: record.backupReference
                )
            }
            guard let incoming = material.incomingByStagingReference[
                record.stagingReference
            ] else {
                throw PortableContinuityApplyError.invalidDecision
            }
            try credentialStore.store(
                incoming,
                reference: record.stagingReference
            )
            try requireCredentialHash(
                record.incomingSHA256,
                reference: record.stagingReference
            )
            if let previousHash = record.previousSHA256 {
                try requireCredentialHash(
                    previousHash,
                    reference: record.backupReference
                )
            }
        }
    }

    private func applyFinalCredentials(
        _ material: CredentialMaterial
    ) throws {
        for record in material.records {
            guard let incoming = try credentialStore.secret(
                reference: record.stagingReference
            ),
                SecureProfileVault.sha256(Data(incoming.utf8))
                    == record.incomingSHA256
            else {
                throw PortableContinuityApplyError.invalidJournal
            }
            try credentialStore.store(
                incoming,
                reference: record.finalReference
            )
            try requireCredentialHash(
                record.incomingSHA256,
                reference: record.finalReference
            )
        }
    }

    private func requireCredentialHash(
        _ expected: String,
        reference: String
    ) throws {
        guard let value = try credentialStore.secret(
            reference: reference
        ),
            SecureProfileVault.sha256(Data(value.utf8)) == expected
        else {
            throw PortableContinuityApplyError.stateChanged
        }
    }

    private func writeTargetState(
        _ data: Data?,
        sourceHash: String?,
        targetHash: String?
    ) throws {
        guard sourceHash != targetHash else { return }
        guard let data, SecureProfileVault.sha256(data) == targetHash else {
            throw PortableContinuityApplyError.invalidJournal
        }
        try stateStore.writePrepared(
            data,
            expectedCurrentHash: sourceHash
        )
        guard SessionSyncFileSafety.hashIfPresent(stateURL)
                == targetHash else {
            throw PortableContinuityApplyError.stateChanged
        }
    }

    private func writeTargetWorkspace(
        _ data: Data?,
        sourceHash: String?,
        targetHash: String?
    ) throws {
        guard sourceHash != targetHash else { return }
        guard let data, SecureProfileVault.sha256(data) == targetHash else {
            throw PortableContinuityApplyError.invalidJournal
        }
        try workspaceStore.writePrepared(
            data,
            expectedHash: sourceHash
        )
        guard SessionSyncFileSafety.hashIfPresent(workspaceStore.fileURL)
                == targetHash else {
            throw PortableContinuityApplyError.stateChanged
        }
    }

    private func update(
        _ journal: inout PortableContinuityApplyJournal,
        phase: PortableContinuityApplyPhase,
        message: String
    ) throws {
        journal.phase = phase
        journal.updatedAt = Date()
        journal.message = message
        try journalStore.save(journal)
    }

    private func rollback(
        _ journal: inout PortableContinuityApplyJournal
    ) throws {
        let files = try snapshotFiles(journal)
        try restoreCredentials(journal.credentialChanges)
        try restoreFile(
            source: files["workspace-before.json"],
            sourceExisted: journal.sourceWorkspaceExisted,
            sourceHash: journal.sourceWorkspaceSHA256,
            targetHash: journal.targetWorkspaceSHA256,
            store: .workspace
        )
        try restoreFile(
            source: files["state-before.json"],
            sourceExisted: journal.sourceStateExisted,
            sourceHash: journal.sourceStateSHA256,
            targetHash: journal.targetStateSHA256,
            store: .state
        )
        try cleanupTemporaryCredentials(journal.credentialChanges)
        try update(
            &journal,
            phase: .rolledBack,
            message: "未完成导入已恢复到写入前状态"
        )
        try? vault.deleteSnapshot(journal.snapshot)
    }

    private enum RestoreStore: Equatable {
        case state
        case workspace
    }

    private func restoreFile(
        source: Data?,
        sourceExisted: Bool,
        sourceHash: String?,
        targetHash: String?,
        store: RestoreStore
    ) throws {
        let url = store == .state ? stateURL : workspaceStore.fileURL
        let current = SessionSyncFileSafety.hashIfPresent(url)
        if current == sourceHash { return }
        guard current == targetHash else {
            throw PortableContinuityApplyError.stateChanged
        }
        let restored = sourceExisted ? source : nil
        if sourceExisted {
            guard let restored,
                SecureProfileVault.sha256(restored) == sourceHash
            else {
                throw PortableContinuityApplyError.invalidJournal
            }
        }
        switch store {
        case .state:
            try stateStore.restore(
                restored,
                expectedCurrentHash: targetHash
            )
        case .workspace:
            try workspaceStore.restore(
                restored,
                expectedCurrentHash: targetHash
            )
        }
        guard SessionSyncFileSafety.hashIfPresent(url) == sourceHash else {
            throw PortableContinuityApplyError.stateChanged
        }
    }

    private func restoreCredentials(
        _ records: [PortableContinuityCredentialJournal]
    ) throws {
        for record in records {
            let current = try credentialStore.secret(
                reference: record.finalReference
            )
            let currentHash = current.map {
                SecureProfileVault.sha256(Data($0.utf8))
            }
            if record.previousExisted {
                if currentHash == record.previousSHA256 { continue }
                guard let backup = try credentialStore.secret(
                    reference: record.backupReference
                ),
                    SecureProfileVault.sha256(Data(backup.utf8))
                        == record.previousSHA256
                else {
                    throw PortableContinuityApplyError.invalidJournal
                }
                try credentialStore.store(
                    backup,
                    reference: record.finalReference
                )
                try requireCredentialHash(
                    record.previousSHA256!,
                    reference: record.finalReference
                )
            } else if current != nil {
                try credentialStore.delete(
                    reference: record.finalReference
                )
                guard try credentialStore.secret(
                    reference: record.finalReference
                ) == nil else {
                    throw PortableContinuityApplyError.stateChanged
                }
            }
        }
    }

    private func finalizeApplied(
        _ journal: inout PortableContinuityApplyJournal
    ) throws {
        for record in journal.credentialChanges {
            try requireCredentialHash(
                record.incomingSHA256,
                reference: record.finalReference
            )
        }
        try cleanupTemporaryCredentials(journal.credentialChanges)
        try update(
            &journal,
            phase: .committed,
            message: "迁移导入已提交，临时凭据已清理"
        )
        try? vault.deleteSnapshot(journal.snapshot)
    }

    private func cleanupTemporaryCredentials(
        _ records: [PortableContinuityCredentialJournal]
    ) throws {
        for record in records {
            try credentialStore.delete(
                reference: record.stagingReference
            )
            try credentialStore.delete(
                reference: record.backupReference
            )
            guard try credentialStore.secret(
                reference: record.stagingReference
            ) == nil,
                try credentialStore.secret(
                    reference: record.backupReference
                ) == nil
            else {
                throw PortableContinuityApplyError.recoveryRequired
            }
        }
    }

    private func snapshotFiles(
        _ journal: PortableContinuityApplyJournal
    ) throws -> [String: Data] {
        let inputs = try vault.loadSnapshot(journal.snapshot)
        let values = Dictionary(
            uniqueKeysWithValues: inputs.map {
                ($0.relativePath, $0.data)
            }
        )
        guard values.count == 4,
            values["state-before.json"] != nil,
            values["state-after.json"] != nil,
            values["workspace-before.json"] != nil,
            values["workspace-after.json"] != nil
        else {
            throw PortableContinuityApplyError.invalidJournal
        }
        return values
    }
}
