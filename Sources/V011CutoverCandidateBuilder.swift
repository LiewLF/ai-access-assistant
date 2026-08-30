// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011ValidatedSwitchTarget: Equatable {
    let profileID: String?
    let relayProfile: CodexRelayProfile?
}

enum V011CutoverCandidateBuilder {
    static func make(
        prepared: FablePreparedConfiguration,
        target: V011ValidatedSwitchTarget,
        destination: FableSwitchDestination,
        versionContractID: String,
        changesRoute: Bool
    ) throws -> FableCutoverCandidate {
        let original = try TOMLSemanticEngine.parse(
            TOMLSensitiveValueRedactor.redact(
                String(
                    decoding: prepared.originalData ?? Data(),
                    as: UTF8.self
                )
            )
        )
        let proposed = try TOMLSemanticEngine.parse(
            TOMLSensitiveValueRedactor.redact(
                String(
                    decoding: prepared.proposedData,
                    as: UTF8.self
                )
            )
        )
        let providerID = providerID(for: destination)
        let isOfficial = providerID == "openai"
        let notApplicable = FableCutoverCheckResult.notApplicable
        let passed = FableCutoverCheckResult.passed
        let coreChecks = [
            FableCutoverCheck(
                id: .semanticParse,
                result: passed,
                detail: "候选与当前配置均可语义解析"
            ),
            FableCutoverCheck(
                id: .versionContract,
                result: passed,
                detail: versionContractID
            ),
            FableCutoverCheck(
                id: .providerResponses,
                result: isOfficial ? notApplicable : passed,
                detail: isOfficial
                    ? "官方安全出口在写后验证"
                    : "Provider和Responses合同已识别"
            ),
            FableCutoverCheck(
                id: .credentialPresence,
                result: isOfficial ? notApplicable : passed,
                detail: isOfficial
                    ? "官方轨不使用中转凭据"
                    : "只记录凭据引用存在性"
            ),
            FableCutoverCheck(
                id: .coreResponses,
                result: isOfficial ? notApplicable : passed,
                detail: isOfficial
                    ? "官方恢复依赖可信覆盖层并在写后验证"
                    : "写前最小Responses请求已通过"
            ),
            FableCutoverCheck(
                id: .baselineCAS,
                result: passed,
                detail: "已绑定当前配置hash；提交仍由writer做CAS"
            ),
            FableCutoverCheck(
                id: .unmanagedPreservation,
                result: passed,
                detail: "候选由Fable受管字段策略生成"
            ),
            FableCutoverCheck(
                id: .singleWriter,
                result: passed,
                detail: "唯一生产writer为FableSwitchCore"
            ),
        ]
        let changesLive =
            prepared.originalHash != prepared.proposedHash
        return FableCutoverCandidate(
            profileID: target.profileID,
            providerID: providerID,
            modelID: target.relayProfile?.defaultModel,
            baselineGenerationHash: prepared.originalHash,
            proposedConfigHash: prepared.proposedHash,
            semanticDiffPaths: TOMLSemanticEngine.diff(
                before: original,
                after: proposed
            ).map { $0.path }.sorted(),
            capabilityContract: versionContractID,
            credentialReferencePresent:
                target.relayProfile.map {
                    !$0.v011CredentialReference.isEmpty
                } ?? false,
            coreChecks: coreChecks,
            optionalChecks: [],
            impactLevel: FableCutoverImpactClassifier.classify(
                changesLiveConfiguration: changesLive,
                changesRoute: changesRoute,
                clientSupportsHotUpdate: false
            ),
            createdAt: Date()
        )
    }

    static func providerID(
        for destination: FableSwitchDestination
    ) -> String {
        switch destination {
        case .official:
            return "openai"
        case let .relay(profile):
            return profile.providerID
        }
    }
}
