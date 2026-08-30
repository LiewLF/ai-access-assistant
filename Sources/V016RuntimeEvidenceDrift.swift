// SPDX-License-Identifier: AGPL-3.0-only

enum V016RuntimeEvidenceDrift {
    static func detected(
        receipt: V011AgentLoopReceipt?,
        live: LiveCodexState?
    ) -> Bool {
        guard let receipt, let live,
              receipt.isStructurallyValid,
              receipt.outcome == .passed,
              receipt.configHash == live.configHash,
              receipt.providerID
                == V011AgentLoopReceipt.providerID(live),
              receipt.endpointHost
                == V011AgentLoopReceipt.endpointHost(live),
              receipt.modelID == live.model else {
            return false
        }
        return receipt.codexAppVersion != live.version.appVersion
            || receipt.codexAppBuild != live.version.appBuild
            || receipt.codexCLIVersion != live.version.cliVersion
    }
}
