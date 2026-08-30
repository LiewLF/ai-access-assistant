// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Owns read-only config evidence for opening a historical session. Provider
/// policy remains in SessionOpenSafetyGate.
struct ConfigWorkspaceSessionOpenSafetyService {
    let configURL: URL

    func blockReason(
        sessionProvider: String?,
        currentProvider: String,
        runtimeTruth: RuntimeTruth?
    ) throws -> String? {
        let data = FileManager.default.fileExists(
            atPath: configURL.path
        )
            ? try Data(contentsOf: configURL)
            : Data()
        let document = try TOMLSemanticEngine.parse(
            String(decoding: data, as: UTF8.self)
        )
        return SessionOpenSafetyGate.blockReason(
            sessionProvider: sessionProvider,
            currentProvider: currentProvider,
            definedProviderIDs: Set(document.providerIDs),
            runtimeProvider: runtimeTruth?.activeProviderID,
            runtimeVerified:
                runtimeTruth?.state == .verified
        )
    }
}
