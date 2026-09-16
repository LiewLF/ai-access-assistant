// SPDX-License-Identifier: AGPL-3.0-only

enum V016RuntimeEvidenceDrift {
    static func detected(
        receipt: V011AgentLoopReceipt?,
        live: LiveCodexState?
    ) -> Bool {
        guard let receipt, let live,
              receipt.isStructurallyValid,
              receipt.outcome == .passed,
              let currentRoute =
                V011AgentLoopRouteIdentity(live: live),
              receipt.routeIdentity == currentRoute else {
            return false
        }
        return !receipt.runtimeIdentity.matches(live.version)
    }
}
