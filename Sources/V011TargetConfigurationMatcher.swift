// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011TargetConfigurationMatcher {
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore

    private var currentRouteResolver: V011CurrentRouteResolver {
        V011CurrentRouteResolver(
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore
        )
    }

    func matches(
        journal: V011SwitchJournal,
        live: LiveCodexState,
        managedState: V011ManagedState,
        versionContractID: String
    ) throws -> Bool {
        guard live.versionSupport.allowsWrites,
              FileManager.default.fileExists(
                atPath: live.configURL.path
              ) else {
            return false
        }
        try SessionSyncFileSafety.requireRegularFile(
            live.configURL
        )
        let document = try TOMLSemanticEngine.parse(
            String(
                decoding: try Data(contentsOf: live.configURL),
                as: UTF8.self
            )
        )
        let allManagedProviderIDs =
            managedProviderIDs.union(
                managedState.managedProviderIDSet
            )

        if let profileID = journal.targetProfileID {
            guard let profile = managedState.relayProfiles
                .first(where: {
                    $0.id == profileID
                        && $0.v011ProviderID
                            == journal.targetProvider
                }),
                V011RelaySemanticMatcher.matches(
                    live: live,
                    profile: profile
                ),
                live.provider?.displayName
                    == profile.fableProfile
                        .providerConfigurationName,
                let expectedSecret = try credentialStore.secret(
                    reference:
                        profile.v011CredentialReference
                ),
                !expectedSecret.isEmpty,
                document.string(at: [
                    "model_providers",
                    journal.targetProvider,
                    "experimental_bearer_token",
                ]) == expectedSecret,
                currentRouteResolver.credentialsAreScrubbed(
                    in: document,
                    managedProviderIDs:
                        allManagedProviderIDs,
                    activeProviderID:
                        journal.targetProvider
                ) else {
                return false
            }
            return true
        }

        guard journal.targetProvider == "openai",
              case .official = live.mode,
              let overlay = managedState
                .officialRootOverlay?
                .trustedOverlay(
                    forAny: CodexVersionContract
                        .compatibleSchemaIDs(
                            for: versionContractID
                        )
                ),
              officialRootsMatch(
                document: document,
                overlay: overlay
              ),
              currentRouteResolver.credentialsAreScrubbed(
                in: document,
                managedProviderIDs:
                    allManagedProviderIDs,
                activeProviderID: nil
              ) else {
            return false
        }
        return true
    }

    func currentConfigurationHash(
        _ url: URL
    ) throws -> String {
        try SessionSyncFileSafety.requireRegularFile(url)
        return TOMLSemanticEngine.sha256(
            try Data(
                contentsOf: url,
                options: .mappedIfSafe
            )
        )
    }

    private func officialRootsMatch(
        document: TOMLSemanticDocument,
        overlay: FableOfficialRootOverlay
    ) -> Bool {
        guard document.leaves[
            TOMLSemanticEngine.path(["model_provider"])
        ] == nil else {
            return false
        }
        return rootValueMatches(
            document: document,
            key: "model",
            isPresent: overlay.hasModel,
            stringValue: overlay.model
        )
            && rootIntegerMatches(
                document: document,
                key: "model_context_window",
                isPresent: overlay.hasContextWindow,
                expected: overlay.contextWindow
            )
            && rootIntegerMatches(
                document: document,
                key: "model_auto_compact_token_limit",
                isPresent:
                    overlay.hasAutoCompactTokenLimit,
                expected:
                    overlay.autoCompactTokenLimit
            )
            && rootValueMatches(
                document: document,
                key: "model_reasoning_effort",
                isPresent: overlay.hasReasoningEffort,
                stringValue: overlay.reasoningEffort
            )
            && capabilityRootsMatch(
                document: document,
                overlay: overlay
            )
    }

    private func rootValueMatches(
        document: TOMLSemanticDocument,
        key: String,
        isPresent: Bool,
        stringValue: String?
    ) -> Bool {
        let exists = document.leaves[
            TOMLSemanticEngine.path([key])
        ] != nil
        guard exists == isPresent else { return false }
        return !isPresent
            || document.rootString(key) == stringValue
    }

    private func rootIntegerMatches(
        document: TOMLSemanticDocument,
        key: String,
        isPresent: Bool,
        expected: Int?
    ) -> Bool {
        let exists = document.leaves[
            TOMLSemanticEngine.path([key])
        ] != nil
        guard exists == isPresent else { return false }
        return !isPresent
            || document.rootInteger(key) == expected
    }

    private func capabilityRootsMatch(
        document: TOMLSemanticDocument,
        overlay: FableOfficialRootOverlay
    ) -> Bool {
        if let values = overlay.capabilityRootValues {
            for key in FableOfficialRootOverlay.capabilityRootKeys {
                guard let expected = values[key],
                      managedValueMatches(
                          document: document,
                          path: [key],
                          expected: expected
                      ) else {
                    return false
                }
            }
        }
        if let expectedFastMode = overlay.featuresFastMode {
            return managedValueMatches(
                document: document,
                path: ["features", "fast_mode"],
                expected: expectedFastMode
            )
        }
        return true
    }

    private func managedValueMatches(
        document: TOMLSemanticDocument,
        path: [String],
        expected: FableManagedValue
    ) -> Bool {
        guard expected.isStructurallyValid else { return false }
        let exists = document.leaves[
            TOMLSemanticEngine.path(path)
        ] != nil
        guard exists == expected.isPresent else { return false }
        guard let value = expected.value else { return true }
        switch value {
        case let .string(expectedValue):
            return document.string(at: path) == expectedValue
        case let .integer(expectedValue):
            return document.integer(at: path) == expectedValue
        case let .bool(expectedValue):
            return document.boolean(at: path) == expectedValue
        }
    }
}
