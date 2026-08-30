// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011OfficialBaselineRecord: Codable, Equatable {
    let configHash: String
    let verifiedAt: Date
    let switchTransactionID: String
    let providerID: String
    let versionContractSchemaID: String
}

struct V011OfficialRootOverlayRecord: Codable, Equatable {
    let overlay: FableOfficialRootOverlay
    let capturedFromConfigHash: String
    let capturedAt: Date
    let versionContractSchemaID: String

    func trustedOverlay(
        for schemaID: String
    ) -> FableOfficialRootOverlay? {
        trustedOverlay(forAny: [schemaID])
    }

    func trustedOverlay(
        forAny schemaIDs: Set<String>
    ) -> FableOfficialRootOverlay? {
        let isSHA256 =
            capturedFromConfigHash.count == 64
            && capturedFromConfigHash.allSatisfy {
                $0.isHexDigit
                    && !$0.isUppercase
            }
        guard isSHA256,
              !versionContractSchemaID.isEmpty,
              schemaIDs.contains(versionContractSchemaID),
              overlay.isStructurallyValid else {
            return nil
        }
        return overlay
    }
}

enum V011RelaySemanticMatcher {
    static func matches(
        live: LiveCodexState,
        profile: CodexRelayProfile
    ) -> Bool {
        let expected = profile.fableProfile
        guard profile.wireProtocol == .responses,
              !profile.models.isEmpty,
              profile.models.contains(
                  profile.defaultModel
              ),
              case let .relay(providerID) = live.mode,
              providerID == profile.v011ProviderID,
              let provider = live.provider,
              provider.providerID == providerID,
              normalizedURL(provider.baseURL)
                == normalizedURL(profile.baseURL),
              provider.wireAPI?.lowercased()
                == "responses",
              provider.hasBearerToken,
              !provider.hasEnvKey,
              !provider.hasCommandAuth,
              provider.requiresOpenAIAuth
                == expected.requiresOpenAIAuth,
              provider.displayName
                == expected.providerConfigurationName,
              live.model == profile.defaultModel,
              matchesIfManaged(
                  actual: live.contextWindow,
                  expected: expected.contextWindow
              ),
              matchesIfManaged(
                  actual: live.autoCompactTokenLimit,
                  expected:
                    expected.autoCompactTokenLimit
              ),
              normalizedReasoning(live.reasoningEffort)
                == expected.reasoningEffort,
              matches(
                  live.modelVerbosity,
                  intent: expected.modelVerbosity
              ),
              matches(
                  live.serviceTier,
                  intent: expected.serviceTier
              ),
              matches(
                  live.modelCatalogJSON,
                  intent: expected.modelCatalogJSON
              ),
              matches(
                  live.webSearch,
                  intent: expected.webSearch
              ),
              matches(
                  live.disableResponseStorage,
                  intent: expected.disableResponseStorage
              ),
              matches(
                  live.fastMode,
                  intent: expected.fastMode
              ),
              matches(
                  provider.supportsWebSockets,
                  intent: expected.supportsWebSockets
              ),
              matches(
                  provider.supportsStandaloneWebSearch,
                  intent:
                    expected.supportsStandaloneWebSearch
              ) else {
            return false
        }
        return true
    }

    private static func matchesIfManaged<Value: Equatable>(
        actual: Value?,
        expected: Value?
    ) -> Bool {
        guard let expected else { return true }
        return actual == expected
    }

    private static func matches<Value: Equatable>(
        _ actual: Value?,
        intent: FableFieldIntent<Value>
    ) -> Bool {
        switch intent {
        case .preserve:
            return true
        case .remove:
            return actual == nil
        case let .set(expected):
            return actual == expected
        }
    }

    private static func normalizedURL(
        _ value: String?
    ) -> String? {
        guard var value = value?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty else {
            return nil
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func normalizedReasoning(
        _ value: String?
    ) -> String {
        let normalized = value?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()
        guard let normalized, !normalized.isEmpty else {
            return "medium"
        }
        return normalized
    }
}
