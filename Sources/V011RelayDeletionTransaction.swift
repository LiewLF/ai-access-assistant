// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011RelayDeletionPhase: String, Codable, CaseIterable {
    case prepared
    case stateRemoved
    case credentialRemoved
    case committed
    case rollbackRequired
    case rolledBack
    case rollbackFailed

    var isPending: Bool {
        ![.committed, .rolledBack].contains(self)
    }
}

enum V011RelayDeletionFaultPoint: String, CaseIterable, Sendable {
    case prepared
    case stateRemoved
    case credentialRemoved
    case beforeCommit
}

struct V011RelayDeletionJournal: Codable, Equatable, Identifiable {
    let version: Int
    let id: String
    let controlRootPath: String
    let profileID: String
    let providerID: String
    let credentialReference: String
    let credentialExisted: Bool
    let sourceStateHash: String
    let targetStateHash: String
    let stateSnapshot: SnapshotManifest
    let startedAt: Date
    var updatedAt: Date
    var phase: V011RelayDeletionPhase
    var message: String
}

enum V011RelayDeletionTransactionError: LocalizedError, Equatable {
    case pendingRecovery
    case activeRelay
    case profileChanged
    case profileStillReferenced
    case invalidJournal
    case stateChanged
    case credentialStillPresent
    case recoveryRequired
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .pendingRecovery:
            return "发现未完成的操作，请先完成最小恢复"
        case .activeRelay:
            return "当前正在使用这条中转。先切到官方或另一条中转，再删除。"
        case .profileChanged:
            return "中转资料已变化；请重新读取后再删除"
        case .profileStillReferenced:
            return "这条中转仍被当前恢复记录引用；请先完成一次安全切换，再删除"
        case .invalidJournal:
            return "删除中转恢复记录无法安全读取"
        case .stateChanged:
            return "删除期间受管状态被其他操作改变，已停止"
        case .credentialStillPresent:
            return "本机钥匙串密钥未删除；受管档案已恢复"
        case .recoveryRequired:
            return "删除已越过密钥清理点；请执行最小恢复完成收尾"
        case let .rollbackFailed(message):
            return "删除中转自动恢复未完成：\(message)"
        }
    }
}

struct V011RelayDeletionJournalStore {
    let rootURL: URL

    func save(_ journal: V011RelayDeletionJournal) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = url(journal.id)
        try SessionSyncAtomicFile.write(
            encoder.encode(journal),
            to: file,
            expectedHash:
                SessionSyncFileSafety.hashIfPresent(file),
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func pendingReadOnly() throws -> [V011RelayDeletionJournal] {
        try all(readOnly: true).filter(\.phase.isPending)
    }

    func pending() throws -> [V011RelayDeletionJournal] {
        try all().filter(\.phase.isPending)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func all(readOnly: Bool = false) throws -> [V011RelayDeletionJournal] {
        guard FileManager.default.fileExists(
            atPath: rootURL.path
        ) else {
            return []
        }
        try prepareRoot(readOnly: readOnly)
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
        .filter { $0.pathExtension == "json" }
        .map { file in
            try SessionSyncFileSafety.requireRegularFile(file)
            let journal = try decoder.decode(
                V011RelayDeletionJournal.self,
                from: Data(contentsOf: file)
            )
            guard journal.version == 1,
                  file.lastPathComponent
                    == "\(journal.id).json" else {
                throw V011RelayDeletionTransactionError
                    .invalidJournal
            }
            return journal
        }
    }

    private func prepareRoot(readOnly: Bool = false) throws {
        if FileManager.default.fileExists(
            atPath: rootURL.path
        ) {
            let values = try rootURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw V011RelayDeletionTransactionError
                    .invalidJournal
            }
        } else {
            guard !readOnly else { throw V011RelayDeletionTransactionError.invalidJournal }
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard !readOnly else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func url(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }
}

struct V011RelayDeletionTransactionCoordinator {
    static let statePath = "assistant/v011-state.json"

    let controlRoot: URL
    let credentialStore: any FableCredentialStore
    let keyProvider: () throws -> Data
    let verifyInactive: (String) throws -> Void
    let faultInjector:
        (V011RelayDeletionFaultPoint) throws -> Void

    init(
        controlRoot: URL,
        credentialStore: any FableCredentialStore,
        keyProvider: @escaping () throws -> Data,
        verifyInactive: @escaping (String) throws -> Void,
        faultInjector: @escaping
            (V011RelayDeletionFaultPoint) throws -> Void = { _ in }
    ) {
        self.controlRoot = controlRoot
        self.credentialStore = credentialStore
        self.keyProvider = keyProvider
        self.verifyInactive = verifyInactive
        self.faultInjector = faultInjector
    }

    var journalStore: V011RelayDeletionJournalStore {
        V011RelayDeletionJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "RelayDeletionTransactions",
                isDirectory: true
            )
        )
    }

    func delete(
        _ profile: CodexRelayProfile
    ) throws -> V011ManagedState {
        try requireNoPendingTransactions()
        try verifyInactive(profile.v011ProviderID)

        let sourceData = try loadSourceStateData()
        let sourceHash = SecureProfileVault.sha256(sourceData)
        let sourceState = try stateStore.load()
        guard SessionSyncFileSafety.hashIfPresent(
                stateStore.fileURL
              ) == sourceHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }
        try validate(
            profile: profile,
            in: sourceState
        )

        var targetState = sourceState
        targetState.relayProfiles.removeAll {
            $0.id == profile.id
        }
        if !targetState.relayProfiles.contains(where: {
            $0.v011ProviderID == profile.v011ProviderID
        }) {
            targetState.managedProviderIDs.removeAll {
                $0 == profile.v011ProviderID
            }
        }
        let targetData = try stateStore.preparedData(
            for: targetState
        )
        let targetHash = SecureProfileVault.sha256(targetData)
        guard SessionSyncFileSafety.hashIfPresent(
                stateStore.fileURL
              ) == sourceHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }

        let credentialExisted = try credentialStore.secret(
            reference: profile.v011CredentialReference
        ) != nil
        let snapshot = try vault.saveSnapshot(
            profileID: "relay-deletion-\(profile.id)",
            adapterVersion: "0.11.0",
            inputs: [
                SnapshotInput(
                    relativePath: Self.statePath,
                    data: sourceData,
                    permissions: 0o600
                ),
            ]
        )
        let now = Date()
        var journal = V011RelayDeletionJournal(
            version: 1,
            id: UUID().uuidString.lowercased(),
            controlRootPath:
                controlRoot.standardizedFileURL.path,
            profileID: profile.id,
            providerID: profile.v011ProviderID,
            credentialReference:
                profile.v011CredentialReference,
            credentialExisted: credentialExisted,
            sourceStateHash: sourceHash,
            targetStateHash: targetHash,
            stateSnapshot: snapshot,
            startedAt: now,
            updatedAt: now,
            phase: .prepared,
            message: "已建立删除恢复点"
        )
        try journalStore.save(journal)

        do {
            try faultInjector(.prepared)
            try verifyInactive(profile.v011ProviderID)
            try stateStore.writePrepared(
                targetData,
                expectedCurrentHash: sourceHash
            )
            guard SessionSyncFileSafety.hashIfPresent(
                    stateStore.fileURL
                  ) == targetHash else {
                throw V011RelayDeletionTransactionError
                    .stateChanged
            }
            try update(
                &journal,
                phase: .stateRemoved,
                message: "已移除受管档案"
            )
            try faultInjector(.stateRemoved)
            try verifyInactive(profile.v011ProviderID)
        } catch {
            try rollback(&journal)
            throw error
        }

        do {
            try credentialStore.delete(
                reference: profile.v011CredentialReference
            )
        } catch {
            try rollback(&journal)
            throw error
        }

        let credentialIsMissing: Bool
        do {
            credentialIsMissing = try credentialStore.secret(
                reference: profile.v011CredentialReference
            ) == nil
        } catch {
            throw V011RelayDeletionTransactionError
                .recoveryRequired
        }
        guard credentialIsMissing else {
            try rollback(&journal)
            throw V011RelayDeletionTransactionError
                .credentialStillPresent
        }

        do {
            try update(
                &journal,
                phase: .credentialRemoved,
                message: "已移除本机钥匙串密钥"
            )
            try faultInjector(.credentialRemoved)
            try faultInjector(.beforeCommit)
            try update(
                &journal,
                phase: .committed,
                message: "删除已完成"
            )
        } catch {
            throw V011RelayDeletionTransactionError
                .recoveryRequired
        }
        try? vault.deleteSnapshot(snapshot)
        return targetState
    }

    func recoverPending() throws -> Int {
        var resolved = 0
        for var journal in try journalStore.pending() {
            do {
                try recover(&journal)
                resolved += 1
            } catch let error as
                V011RelayDeletionTransactionError {
                if journal.phase != .rollbackFailed {
                    try? update(
                        &journal,
                        phase: .rollbackFailed,
                        message: "删除恢复尚未完成"
                    )
                }
                throw error
            } catch {
                try? update(
                    &journal,
                    phase: .rollbackFailed,
                    message: "删除恢复尚未完成"
                )
                throw V011RelayDeletionTransactionError
                    .rollbackFailed(
                        error.localizedDescription
                    )
            }
        }
        return resolved
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(fileURL: stateURL)
    }

    private var stateURL: URL {
        controlRoot
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private var vault: SecureProfileVault {
        SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "RelayDeletionVault",
                isDirectory: true
            ),
            keyProvider: keyProvider
        )
    }

    private func update(
        _ journal: inout V011RelayDeletionJournal,
        phase: V011RelayDeletionPhase,
        message: String
    ) throws {
        journal.phase = phase
        journal.updatedAt = Date()
        journal.message = message
        try journalStore.save(journal)
    }

    private func requireNoPendingTransactions() throws {
        guard try journalStore.pending().isEmpty,
              try V011SwitchJournalStore(
                rootURL: controlRoot.appendingPathComponent(
                    "SwitchTransactions",
                    isDirectory: true
                )
              ).pending().isEmpty,
              try V011AdoptionJournalStore(
                rootURL: controlRoot.appendingPathComponent(
                    "AdoptionTransactions",
                    isDirectory: true
                )
              ).pending().isEmpty else {
            throw V011RelayDeletionTransactionError
                .pendingRecovery
        }
    }

    private func validate(
        profile: CodexRelayProfile,
        in state: V011ManagedState
    ) throws {
        guard state.relayProfiles.filter({
            $0.id == profile.id && $0 == profile
        }).count == 1 else {
            throw V011RelayDeletionTransactionError
                .profileChanged
        }
        let providerID = profile.v011ProviderID
        guard state.activeProfileID != profile.id,
              state.lastVerifiedProviderID != providerID,
              state.activeCutoverConfiguration?.profileID
                != profile.id,
              state.activeCutoverConfiguration?.providerID
                != providerID,
              state.lastKnownGoodCutoverConfiguration?.profileID
                != profile.id,
              state.lastKnownGoodCutoverConfiguration?.providerID
                != providerID else {
            throw V011RelayDeletionTransactionError
                .profileStillReferenced
        }
    }

    private func loadSourceStateData() throws -> Data {
        guard FileManager.default.fileExists(
            atPath: stateURL.path
        ) else {
            throw V011RelayDeletionTransactionError
                .profileChanged
        }
        try SessionSyncFileSafety.requireRegularFile(stateURL)
        return try Data(contentsOf: stateURL)
    }

    private func rollback(
        _ journal: inout V011RelayDeletionJournal
    ) throws {
        do {
            try update(
                &journal,
                phase: .rollbackRequired,
                message: "删除未完成，正在恢复受管档案"
            )
            let credentialExists = try credentialStore.secret(
                reference: journal.credentialReference
            ) != nil
            guard credentialExists
                    == journal.credentialExisted else {
                throw V011RelayDeletionTransactionError
                    .recoveryRequired
            }
            try restoreSourceState(journal)
            try update(
                &journal,
                phase: .rolledBack,
                message: "未完成删除已恢复"
            )
            try? vault.deleteSnapshot(
                journal.stateSnapshot
            )
        } catch {
            try? update(
                &journal,
                phase: .rollbackFailed,
                message: "删除恢复尚未完成"
            )
            throw V011RelayDeletionTransactionError
                .rollbackFailed(error.localizedDescription)
        }
    }

    private func recover(
        _ journal: inout V011RelayDeletionJournal
    ) throws {
        guard journal.controlRootPath
                == controlRoot.standardizedFileURL.path,
              !journal.profileID.isEmpty,
              !journal.providerID.isEmpty,
              !journal.credentialReference.isEmpty else {
            throw V011RelayDeletionTransactionError
                .invalidJournal
        }
        let currentHash = SessionSyncFileSafety.hashIfPresent(
            stateURL
        )
        guard currentHash == journal.sourceStateHash
                || currentHash == journal.targetStateHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }
        let credentialExists = try credentialStore.secret(
            reference: journal.credentialReference
        ) != nil

        if journal.credentialExisted && credentialExists {
            try rollback(&journal)
            return
        }
        if !journal.credentialExisted && credentialExists {
            throw V011RelayDeletionTransactionError
                .stateChanged
        }
        if !journal.credentialExisted,
           currentHash == journal.sourceStateHash {
            try update(
                &journal,
                phase: .rolledBack,
                message: "未完成删除已恢复"
            )
            try? vault.deleteSnapshot(
                journal.stateSnapshot
            )
            return
        }

        try verifyInactive(journal.providerID)
        if currentHash == journal.sourceStateHash {
            let targetData = try targetStateData(
                for: journal
            )
            try stateStore.writePrepared(
                targetData,
                expectedCurrentHash:
                    journal.sourceStateHash
            )
        }
        guard SessionSyncFileSafety.hashIfPresent(stateURL)
                == journal.targetStateHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }
        try update(
            &journal,
            phase: .committed,
            message: "删除已完成"
        )
        try? vault.deleteSnapshot(journal.stateSnapshot)
    }

    private func restoreSourceState(
        _ journal: V011RelayDeletionJournal
    ) throws {
        let inputs = try vault.loadSnapshot(
            journal.stateSnapshot
        )
        guard inputs.count == 1,
              let source = inputs.first,
              source.relativePath == Self.statePath,
              SecureProfileVault.sha256(source.data)
                == journal.sourceStateHash else {
            throw V011RelayDeletionTransactionError
                .invalidJournal
        }
        let currentHash = SessionSyncFileSafety.hashIfPresent(
            stateURL
        )
        if currentHash == journal.sourceStateHash {
            return
        }
        guard currentHash == journal.targetStateHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }
        try stateStore.restore(
            source.data,
            expectedCurrentHash: journal.targetStateHash
        )
        guard SessionSyncFileSafety.hashIfPresent(stateURL)
                == journal.sourceStateHash else {
            throw V011RelayDeletionTransactionError.stateChanged
        }
    }

    private func targetStateData(
        for journal: V011RelayDeletionJournal
    ) throws -> Data {
        let inputs = try vault.loadSnapshot(
            journal.stateSnapshot
        )
        guard inputs.count == 1,
              let source = inputs.first,
              source.relativePath == Self.statePath,
              SecureProfileVault.sha256(source.data)
                == journal.sourceStateHash else {
            throw V011RelayDeletionTransactionError
                .invalidJournal
        }
        var state = try JSONDecoder().decode(
            V011ManagedState.self,
            from: source.data
        )
        guard state.relayProfiles.contains(where: {
            $0.id == journal.profileID
                && $0.v011ProviderID == journal.providerID
                && $0.v011CredentialReference
                    == journal.credentialReference
        }) else {
            throw V011RelayDeletionTransactionError
                .invalidJournal
        }
        state.relayProfiles.removeAll {
            $0.id == journal.profileID
        }
        if !state.relayProfiles.contains(where: {
            $0.v011ProviderID == journal.providerID
        }) {
            state.managedProviderIDs.removeAll {
                $0 == journal.providerID
            }
        }
        let data = try stateStore.preparedData(for: state)
        guard SecureProfileVault.sha256(data)
                == journal.targetStateHash else {
            throw V011RelayDeletionTransactionError
                .invalidJournal
        }
        return data
    }
}
