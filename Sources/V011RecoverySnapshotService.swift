// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011PreparedConfigurationRecovery {
    let core: FableSwitchCore
    let prepared: FablePreparedRecoveryConfiguration
}

enum V011PreparedFileRecovery {
    case preserve
    case verify(
        url: URL,
        expectedHash: String?,
        expectedExisted: Bool
    )
    case restore(
        url: URL,
        sourceData: Data?,
        expectedCurrentHash: String
    )
}

struct V011PreparedRecoverySnapshot {
    let configuration: V011PreparedConfigurationRecovery
    let managedState: V011PreparedFileRecovery
    let originLedger: V011PreparedFileRecovery
}

enum V011ConfigurationRestorePreflight: Equatable {
    case alreadySource
    case targetUntouched
    case conflict(actualHash: String)

    var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}

struct V011RecoverySnapshotService {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let versionContract: CodexVersionContract
    let keyProvider: () throws -> Data

    func appendSnapshotInputIfPresent(
        url: URL,
        relativePath: String,
        inputs: inout [SnapshotInput]
    ) throws {
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return
        }
        try SessionSyncFileSafety.requireRegularFile(url)
        inputs.append(
            SnapshotInput(
                relativePath: relativePath,
                data: try Data(contentsOf: url),
                permissions: filePermissions(url)
            )
        )
    }

    func prepare(
        journal: V011SwitchJournal,
        vault: SecureProfileVault
    ) throws -> V011PreparedRecoverySnapshot {
        let inputs = try vault.loadSnapshot(
            journal.configSnapshot
        )
        let sourceConfig = try snapshotData(
            "config.toml",
            in: inputs
        )
        let targetConfig = try snapshotData(
            "assistant/v011-target-config.toml",
            in: inputs
        )
        guard journal.sourceConfigExisted
                == (sourceConfig != nil),
              TOMLSemanticEngine.sha256(
                sourceConfig ?? Data()
              ) == journal.sourceConfigHash else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if let targetConfig,
           TOMLSemanticEngine.sha256(targetConfig)
            != journal.targetConfigHash {
            throw V011SwitchError.invalidRecoveryJournal
        }

        let configuration = try prepareConfigurationRecovery(
            journal: journal,
            sourceData: sourceConfig,
            targetData: targetConfig
        )
        let managedState = try prepareManagedStateRecovery(
            journal: journal,
            sourceData: try snapshotData(
                "assistant/v011-state.json",
                in: inputs
            )
        )
        let originLedger = try prepareOriginLedgerRecovery(
            journal: journal,
            sourceData: try snapshotData(
                "assistant/session-origin-ledger.vault",
                in: inputs
            )
        )
        return V011PreparedRecoverySnapshot(
            configuration: configuration,
            managedState: managedState,
            originLedger: originLedger
        )
    }

    func apply(
        _ recovery: V011PreparedRecoverySnapshot
    ) throws {
        try recovery.configuration.core
            .applyPreparedRecoveryConfiguration(
                recovery.configuration.prepared
            )
        try applyPreparedFileRecovery(
            recovery.managedState
        )
        try applyPreparedFileRecovery(
            recovery.originLedger
        )
    }

    func configurationRestorePreflight(
        journal: V011SwitchJournal
    ) throws -> V011ConfigurationRestorePreflight {
        let configURL = codexHome
            .appendingPathComponent("config.toml")
        let currentData: Data?
        if FileManager.default.fileExists(
            atPath: configURL.path
        ) {
            try SessionSyncFileSafety.requireRegularFile(
                configURL
            )
            currentData = try Data(
                contentsOf: configURL,
                options: .mappedIfSafe
            )
        } else {
            currentData = nil
        }
        let currentHash = TOMLSemanticEngine.sha256(
            currentData ?? Data()
        )
        if currentHash == journal.sourceConfigHash,
           (currentData != nil)
            == journal.sourceConfigExisted {
            return .alreadySource
        }
        if currentData != nil,
           currentHash == journal.targetConfigHash {
            return .targetUntouched
        }
        return .conflict(actualHash: currentHash)
    }

    func filePermissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        return (
            attributes?[.posixPermissions] as? NSNumber
        )?.intValue ?? 0o600
    }

    private var managedStateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent("state.json")
        )
    }

    private var originLedgerStore:
        V011SessionOriginLedgerStore {
        V011SessionOriginLedgerStore(
            rootURL: controlRoot.appendingPathComponent(
                "SessionOriginLedger",
                isDirectory: true
            ),
            keyProvider: keyProvider
        )
    }

    private func prepareConfigurationRecovery(
        journal: V011SwitchJournal,
        sourceData: Data?,
        targetData: Data?
    ) throws -> V011PreparedConfigurationRecovery {
        let recoveryProviderIDs = try
            recoveryManagedProviderIDs(
                journal: journal,
                sourceData: sourceData,
                targetData: targetData
            )
        let core = makeCore(
            managedProviderIDs: recoveryProviderIDs
        )
        if let targetData {
            return V011PreparedConfigurationRecovery(
                core: core,
                prepared: try core
                    .prepareRecoveryConfiguration(
                        sourceData: sourceData,
                        targetData: targetData
                    )
            )
        }

        let configURL = codexHome.appendingPathComponent(
            "config.toml"
        )
        let current = try recoveryFileState(configURL)
        let currentContentHash = TOMLSemanticEngine.sha256(
            current.data ?? Data()
        )
        let isSource = current.existed
            == journal.sourceConfigExisted
            && currentContentHash == journal.sourceConfigHash
        let isTarget = current.existed
            && currentContentHash == journal.targetConfigHash
        guard isSource || isTarget else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        return V011PreparedConfigurationRecovery(
            core: core,
            prepared: FablePreparedRecoveryConfiguration(
                configURL: configURL,
                expectedCurrentHash: current.hash,
                expectedCurrentExisted: current.existed,
                recoveredData: isSource ? current.data : sourceData,
                requiresWrite: isTarget && !isSource
            )
        )
    }

    private func recoveryManagedProviderIDs(
        journal: V011SwitchJournal,
        sourceData: Data?,
        targetData: Data?
    ) throws -> Set<String> {
        var providerIDs = managedProviderIDs
        if journal.targetProvider != "openai" {
            providerIDs.insert(journal.targetProvider)
        }
        guard let targetData else { return providerIDs }
        let sourceDocument = try TOMLSemanticEngine.parse(
            String(
                decoding: sourceData ?? Data(),
                as: UTF8.self
            )
        )
        let targetDocument = try TOMLSemanticEngine.parse(
            String(decoding: targetData, as: UTF8.self)
        )
        for document in [sourceDocument, targetDocument] {
            if let selected = document.rootString(
                "model_provider"
            ), selected != "openai" {
                providerIDs.insert(selected)
            }
        }
        for change in TOMLSemanticEngine.diff(
            before: sourceDocument,
            after: targetDocument
        ) {
            let path = TOMLSemanticEngine.decodePath(
                change.path
            )
            if path.count >= 2,
               path[0] == "model_providers" {
                providerIDs.insert(path[1])
            }
        }
        return providerIDs
    }

    private func prepareManagedStateRecovery(
        journal: V011SwitchJournal,
        sourceData: Data?
    ) throws -> V011PreparedFileRecovery {
        let targetHashes = managedStateTargetHashes(journal)
        guard journal.stateCASManaged == true,
              !targetHashes.isEmpty else {
            return .preserve
        }
        let url = managedStateStore.fileURL
        let current = try recoveryFileState(url)
        if current.existed == journal.stateExisted,
           current.hash == journal.sourceManagedStateHash {
            return .verify(
                url: url,
                expectedHash: current.hash,
                expectedExisted: current.existed
            )
        }
        guard current.existed,
              let currentHash = current.hash,
              targetHashes.contains(currentHash) else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        return .restore(
            url: url,
            sourceData: sourceData,
            expectedCurrentHash: currentHash
        )
    }

    private func prepareOriginLedgerRecovery(
        journal: V011SwitchJournal,
        sourceData: Data?
    ) throws -> V011PreparedFileRecovery {
        guard journal.originLedgerExisted
                == (sourceData != nil) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let url = originLedgerStore.fileURL
        let sourceHash = sourceData.map(
            TOMLSemanticEngine.sha256
        )
        let current = try recoveryFileState(url)
        if current.existed == journal.originLedgerExisted,
           current.hash == sourceHash {
            return .verify(
                url: url,
                expectedHash: current.hash,
                expectedExisted: current.existed
            )
        }
        guard let targetHash =
                journal.targetOriginLedgerHash,
              current.existed,
              current.hash == targetHash else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        return .restore(
            url: url,
            sourceData: sourceData,
            expectedCurrentHash: targetHash
        )
    }

    private func applyPreparedFileRecovery(
        _ recovery: V011PreparedFileRecovery
    ) throws {
        switch recovery {
        case .preserve:
            return
        case let .verify(url, expectedHash, expectedExisted):
            let current = try recoveryFileState(url)
            guard current.existed == expectedExisted,
                  current.hash == expectedHash else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }
        case let .restore(url, sourceData, expectedCurrentHash):
            try V011ManagedStateStore(fileURL: url).restore(
                sourceData,
                expectedCurrentHash: expectedCurrentHash
            )
        }
    }

    private func recoveryFileState(
        _ url: URL
    ) throws -> (existed: Bool, data: Data?, hash: String?) {
        let existed = FileManager.default.fileExists(
            atPath: url.path
        )
        guard existed else {
            return (false, nil, nil)
        }
        try SessionSyncFileSafety.requireRegularFile(url)
        let data = try Data(
            contentsOf: url,
            options: .mappedIfSafe
        )
        return (
            true,
            data,
            TOMLSemanticEngine.sha256(data)
        )
    }

    private func snapshotData(
        _ relativePath: String,
        in inputs: [SnapshotInput]
    ) throws -> Data? {
        let matches = inputs.filter {
            $0.relativePath == relativePath
        }
        guard matches.count <= 1 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return matches.first?.data
    }

    private func managedStateTargetHashes(
        _ journal: V011SwitchJournal
    ) -> Set<String> {
        Set([
            journal.targetManagedStateHash,
            journal.forwardManagedStateHash,
        ].compactMap { $0 })
    }

    private func makeCore(
        managedProviderIDs: Set<String>
    ) -> FableSwitchCore {
        FableSwitchCore(
            codexHome: codexHome,
            versionContract: versionContract,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            managedProviderIDs: managedProviderIDs
        )
    }
}
