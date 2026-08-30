// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum PortableContinuityMigrationSourceRelation:
    String,
    Equatable,
    Sendable {
    case older
    case current
    case newer
    case differentKnownSchema
}

enum PortableContinuityPostImportAction:
    String,
    Equatable,
    Sendable {
    case reviewImportedAccess
    case continueCurrentAccess
}

struct PortableContinuityContinuation: Equatable, Sendable {
    let sourceRelation: PortableContinuityMigrationSourceRelation
    let postImportAction: PortableContinuityPostImportAction
    let currentAccessPreserved: Bool
    let credentialsVerified: Bool

    var userMessage: String {
        switch postImportAction {
        case .reviewImportedAccess:
            return "迁移资料已保存，当前接入未切换。要使用新中转，请到“接入与切换”手动选择并验证；不会自动产生任务费用。"
        case .continueCurrentAccess:
            return "迁移资料已保存，当前接入未切换；可以继续使用当前接入。"
        }
    }
}

enum PortableContinuityMigrationContractError:
    LocalizedError,
    Equatable {
    case importedProfileMissing
    case currentAccessChanged
    case verificationStateChanged

    var errorDescription: String? {
        switch self {
        case .importedProfileMissing:
            return "迁移结果与所选中转不一致，已停止导入"
        case .currentAccessChanged:
            return "迁移将改变当前接入，已停止导入"
        case .verificationStateChanged:
            return "迁移将产生或覆盖验证状态，已停止导入"
        }
    }
}

enum PortableContinuityMigrationContract {
    static func evaluate(
        manifest: PortableContinuityManifest,
        targetVersion: String,
        targetBuild: String,
        before: V011ManagedState,
        after: V011ManagedState,
        importedProfiles: [CodexRelayProfile],
        importedRelayCount: Int
    ) throws -> PortableContinuityContinuation {
        guard importedProfiles.count == importedRelayCount,
            Set(importedProfiles.map(\.id)).count
                == importedProfiles.count,
            importedProfiles.allSatisfy({ profile in
                after.relayProfiles.contains(profile)
                    && after.activeProfileID != profile.id
            })
        else {
            throw PortableContinuityMigrationContractError
                .importedProfileMissing
        }
        guard preservesCurrentAccess(before: before, after: after) else {
            throw PortableContinuityMigrationContractError
                .currentAccessChanged
        }
        try requireNoVerificationAdoption(
            before: before,
            after: after,
            importedProfiles: importedProfiles
        )
        return PortableContinuityContinuation(
            sourceRelation: sourceRelation(
                manifest: manifest,
                targetVersion: targetVersion,
                targetBuild: targetBuild
            ),
            postImportAction: importedProfiles.isEmpty
                ? .continueCurrentAccess : .reviewImportedAccess,
            currentAccessPreserved: true,
            credentialsVerified: false
        )
    }

    private static func preservesCurrentAccess(
        before: V011ManagedState,
        after: V011ManagedState
    ) -> Bool {
        before.activeProfileID == after.activeProfileID
            && before.sessionSyncAuthorized
                == after.sessionSyncAuthorized
            && before.didMigrateFrom0103
                == after.didMigrateFrom0103
            && before.lastSessionJournalPath
                == after.lastSessionJournalPath
            && before.lastSuccessfulSwitchID
                == after.lastSuccessfulSwitchID
            && before.officialBaseline == after.officialBaseline
            && before.officialRootOverlay
                == after.officialRootOverlay
            && before.activeCutoverConfiguration
                == after.activeCutoverConfiguration
            && before.lastKnownGoodCutoverConfiguration
                == after.lastKnownGoodCutoverConfiguration
    }

    private static func requireNoVerificationAdoption(
        before: V011ManagedState,
        after: V011ManagedState,
        importedProfiles: [CodexRelayProfile]
    ) throws {
        let importedProviderIDs = Set(
            importedProfiles.map(\.v011ProviderID)
        )
        if let previousProvider = before.lastVerifiedProviderID,
            importedProviderIDs.contains(previousProvider)
        {
            guard after.lastVerifiedProviderID == nil,
                after.lastVerifiedConfigHash == nil,
                after.lastVerifiedAt == nil
            else {
                throw PortableContinuityMigrationContractError
                    .verificationStateChanged
            }
            return
        }
        guard before.lastVerifiedProviderID
                == after.lastVerifiedProviderID,
            before.lastVerifiedConfigHash
                == after.lastVerifiedConfigHash,
            before.lastVerifiedAt == after.lastVerifiedAt,
            !importedProviderIDs.contains(
                after.lastVerifiedProviderID ?? ""
            )
        else {
            throw PortableContinuityMigrationContractError
                .verificationStateChanged
        }
    }

    private static func sourceRelation(
        manifest: PortableContinuityManifest,
        targetVersion: String,
        targetBuild: String
    ) -> PortableContinuityMigrationSourceRelation {
        if manifest.sourceVersion == targetVersion,
            let sourceBuild = Int(manifest.sourceBuild),
            let currentBuild = Int(targetBuild)
        {
            if sourceBuild < currentBuild { return .older }
            if sourceBuild > currentBuild { return .newer }
            return .current
        }
        guard let source = semanticCore(manifest.sourceVersion),
            let target = semanticCore(targetVersion)
        else {
            return .differentKnownSchema
        }
        let comparison = compare(source, target)
        if comparison < 0 { return .older }
        if comparison > 0 { return .newer }
        return .differentKnownSchema
    }

    private static func semanticCore(_ value: String) -> [Int]? {
        let withoutBuildMetadata = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? Substring(value)
        let core = withoutBuildMetadata.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? withoutBuildMetadata
        let parts = core.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        return values
    }

    private static func compare(
        _ lhs: [Int],
        _ rhs: [Int]
    ) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }
}
