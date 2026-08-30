// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011CutoverPromotionRecorder {
    static func record(
        state: inout V011ManagedState,
        providerID: String,
        profileID: String?,
        modelID: String?,
        configHash: String,
        capabilityContract: String,
        transactionID: String,
        verifiedAt: Date
    ) throws {
        let promotion = try FableCutoverPromotionPolicy.promote(
            providerID: providerID,
            profileID: profileID,
            modelID: modelID,
            configHash: configHash,
            capabilityContract: capabilityContract,
            transactionID: transactionID,
            evidence: FableCutoverPromotionEvidence(
                transactionApplied: true,
                casMatched: true,
                runtimeCoreVerified: true
            ),
            now: verifiedAt
        )
        state.activeCutoverConfiguration = promotion.active
        state.lastKnownGoodCutoverConfiguration =
            promotion.lastKnownGood
    }
}
