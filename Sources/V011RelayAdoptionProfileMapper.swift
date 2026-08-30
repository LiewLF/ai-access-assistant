import Foundation

enum V011RelayAdoptionProfileMapper {
    static func reasoningEffort(
        _ value: String?
    ) -> ReasoningEffort {
        switch value?.lowercased() {
        case "low":
            return .low
        case "high":
            return .high
        case "xhigh":
            return .xhigh
        case "max":
            return .max
        case "ultra":
            return .ultra
        default:
            return .medium
        }
    }

    static func adoptedCapabilityProfile(
        live: LiveCodexState,
        providerID: String,
        profileName: String,
        baseURL: String,
        model: String
    ) -> ProviderCapabilityProfile {
        let configuredTier = adoptedServiceTier(
            live.serviceTier
        )
        let providerName = live.provider?.displayName
        let remoteCompaction:
            ProviderRemoteCompactionCapability
        if providerName?.caseInsensitiveCompare("OpenAI")
            == .orderedSame {
            remoteCompaction =
                ProviderRemoteCompactionCapability(
                    status: .requested,
                    activation: .providerName,
                    requiredUpstreamName: "OpenAI",
                    evidenceID: nil
                )
        } else {
            remoteCompaction =
                ProviderRemoteCompactionCapability(
                    status: .unknown,
                    activation: .unknown,
                    requiredUpstreamName: nil,
                    evidenceID: nil
                )
        }
        return ProviderCapabilityProfile(
            providerID: providerID,
            displayName: profileName,
            upstreamName: providerName,
            baseURL: baseURL,
            models: [
                ProviderModelCapability(
                    modelID: model,
                    contextWindow: live.contextWindow,
                    localAutoCompactLimit:
                        live.autoCompactTokenLimit,
                    serviceTiers: live.serviceTier.map {
                        [$0]
                    } ?? [],
                    defaultServiceTier: live.serviceTier,
                    reasoningEfforts:
                        live.reasoningEffort.map {
                            [$0]
                        } ?? [],
                    inputModalities: ["text"]
                ),
            ],
            defaultModel: model,
            modelCatalogPath: live.modelCatalogJSON,
            serviceTier: ProviderServiceTierCapability(
                requested: configuredTier,
                emittedValue: live.serviceTier,
                accepted:
                    live.serviceTier == nil
                        ? .unknown : .requested,
                actual: nil,
                fallback: nil,
                evidenceID: nil
            ),
            fastModeEnabled: live.fastMode,
            remoteCompaction: remoteCompaction,
            webSearch: ProviderWebSearchCapability(
                status:
                    live.webSearch == nil
                        ? .unknown : .requested,
                mode:
                    live.webSearch == nil
                        ? .unknown : .codexLive,
                citations: .unknown,
                configuredValue: live.webSearch,
                evidenceID: nil
            ),
            textInput: .requested,
            imageInput: .unknown,
            reasoning: .requested,
            requiresOpenAIAuth:
                live.provider?.requiresOpenAIAuth,
            responseStorageDisabled:
                live.disableResponseStorage,
            modelVerbosity: live.modelVerbosity,
            supportsWebSockets:
                live.provider?.supportsWebSockets,
            supportsStandaloneWebSearch:
                live.provider?
                    .supportsStandaloneWebSearch
        )
    }

    private static func adoptedServiceTier(
        _ value: String?
    ) -> ProviderServiceTierIntent {
        guard let value = value?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
              !value.isEmpty else {
            return .inherit
        }
        switch value {
        case "standard":
            return ProviderServiceTierIntent(
                kind: .standard,
                providerValue: nil
            )
        case "fast":
            return .fast
        case "flex":
            return ProviderServiceTierIntent(
                kind: .flex,
                providerValue: nil
            )
        default:
            return ProviderServiceTierIntent(
                kind: .providerSpecific,
                providerValue: value
            )
        }
    }
}
