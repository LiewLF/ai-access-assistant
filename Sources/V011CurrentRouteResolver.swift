// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011CurrentVerificationRoute {
    case official
    case relay(RelayProfile, String, String?, String?)

    var providerID: String {
        switch self {
        case .official:
            return "openai"
        case let .relay(profile, _, _, _):
            return profile.providerID
        }
    }

    var endpointHost: String? {
        switch self {
        case .official:
            return nil
        case let .relay(_, host, _, _):
            return host
        }
    }

    var savedProfileID: String? {
        switch self {
        case .official:
            return nil
        case let .relay(_, _, profileID, _):
            return profileID
        }
    }

    /// The inline key of the live route, when the configuration itself holds
    /// one. `nil` means this is a local gateway: the app has no credential to
    /// send, so the route is proven by the bounded local runtime check instead
    /// of an authenticated HTTP probe.
    var inlineSecret: String? {
        switch self {
        case .official:
            return nil
        case let .relay(_, _, _, secret):
            return secret
        }
    }

    var identity: String {
        switch self {
        case .official:
            return "official|openai"
        case let .relay(profile, host, _, _):
            return [
                "relay",
                profile.providerID,
                profile.baseURL,
                profile.providerConfigurationName,
                profile.model,
                Self.optionalIdentity(
                    profile.contextWindow
                ),
                Self.optionalIdentity(
                    profile.autoCompactTokenLimit
                ),
                profile.reasoningEffort,
                profile.requiresOpenAIAuth ? "openai-auth" : "no-openai-auth",
                Self.intentIdentity(
                    profile.modelVerbosity
                ),
                Self.intentIdentity(
                    profile.serviceTier
                ),
                Self.intentIdentity(
                    profile.modelCatalogJSON
                ),
                Self.intentIdentity(
                    profile.webSearch
                ),
                Self.intentIdentity(
                    profile.disableResponseStorage
                ),
                Self.intentIdentity(
                    profile.fastMode
                ),
                Self.intentIdentity(
                    profile.supportsWebSockets
                ),
                Self.intentIdentity(
                    profile.supportsStandaloneWebSearch
                ),
                host,
            ].joined(separator: "|")
        }
    }

    private static func optionalIdentity<Value>(
        _ value: Value?
    ) -> String {
        value.map { "set:\(String(reflecting: $0))" }
            ?? "missing"
    }

    private static func intentIdentity<Value>(
        _ intent: FableFieldIntent<Value>
    ) -> String where Value: Equatable {
        switch intent {
        case .preserve:
            return "preserve"
        case .remove:
            return "remove"
        case let .set(value):
            return "set:\(String(reflecting: value))"
        }
    }
}

struct V011CurrentRouteResolver {
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore

    func resolve(
        live: LiveCodexState,
        managedState: V011ManagedState,
        requireSavedRelayProfile: Bool = false
    ) throws -> V011CurrentVerificationRoute {
        switch live.mode {
        case .official:
            if requireSavedRelayProfile {
                throw V011CurrentConnectionVerificationError
                    .savedProfileMissing
            }
            return .official
        case let .relay(providerID):
            try SessionSyncFileSafety.requireRegularFile(
                live.configURL
            )
            let document = try TOMLSemanticEngine.parse(
                String(
                    decoding: try Data(
                        contentsOf: live.configURL,
                        options: .mappedIfSafe
                    ),
                    as: UTF8.self
                )
            )
            guard let provider = live.provider,
                  provider.providerID == providerID,
                  provider.wireAPI?.lowercased()
                    == "responses",
                  !provider.hasEnvKey,
                  !provider.hasCommandAuth,
                  let requiresOpenAIAuth =
                    provider.requiresOpenAIAuth,
                  let baseURL = provider.baseURL,
                  let components = URLComponents(
                      string: baseURL
                  ),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  let rawHost = components.host,
                  !rawHost.isEmpty,
                  let model = live.model?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                  !model.isEmpty else {
                throw V011CurrentConnectionVerificationError
                    .savedProfileMismatch
            }
            let inlineSecret = document.string(at: [
                "model_providers",
                providerID,
                "experimental_bearer_token",
            ]).flatMap { $0.isEmpty ? nil : $0 }
            // Two live shapes can be verified, and they must not borrow
            // each other's assumptions. A saved relay keeps its own key in
            // config.toml and stays HTTPS. A local gateway is plain HTTP on
            // this Mac only, carries no key, and is bounded by the same
            // address rules the relay was saved with.
            let savedRelayShape =
                provider.hasBearerToken
                    && components.scheme?.lowercased() == "https"
                    && inlineSecret != nil
            let localGatewayShape =
                !provider.hasBearerToken
                    && inlineSecret == nil
                    && components.scheme?.lowercased() == "http"
                    && V011RelayEndpointPolicy
                        .isLoopbackGatewayAddress(baseURL)
            guard savedRelayShape || localGatewayShape else {
                throw V011CurrentConnectionVerificationError
                    .savedProfileMismatch
            }
            let allManagedProviderIDs = managedProviderIDs.union(
                managedState.managedProviderIDSet
            )
            guard credentialsAreScrubbed(
                      in: document,
                      managedProviderIDs:
                        allManagedProviderIDs,
                      activeProviderID: providerID,
                      requireActiveInlineSecret:
                        inlineSecret != nil
                  ) else {
                throw V011CurrentConnectionVerificationError
                    .savedProfileMismatch
            }

            // A saved profile is useful only when every route semantic
            // matches. A stale profile with the same generic Provider ID
            // (commonly `custom`) must never redirect this read-only probe.
            let matchedProfiles = managedState.relayProfiles
                .filter {
                    V011RelaySemanticMatcher.matches(
                        live: live,
                        profile: $0
                    )
                }
            let matchedProfile: CodexRelayProfile?
            if requireSavedRelayProfile {
                guard matchedProfiles.count == 1,
                      let only = matchedProfiles.first,
                      provider.displayName
                        == only.fableProfile
                            .providerConfigurationName else {
                    throw V011CurrentConnectionVerificationError
                        .savedProfileMismatch
                }
                matchedProfile = only
            } else {
                matchedProfile = matchedProfiles.first
            }
            // A route without an inline key has nothing to compare against a
            // stored secret. Reading that secret here would decide nothing,
            // so the comparison stays tied to the shape that carries one.
            if let matchedProfile, let inlineSecret {
                guard let expectedSecret = try credentialStore
                        .secret(
                            reference: matchedProfile
                                .v011CredentialReference
                        ),
                      !expectedSecret.isEmpty,
                      inlineSecret == expectedSecret else {
                    throw V011CurrentConnectionVerificationError
                        .savedProfileMismatch
                }
            }
            let host = components.port.map {
                "\(rawHost.lowercased()):\($0)"
            } ?? rawHost.lowercased()
            let profile = RelayProfile(
                id: matchedProfile?.id
                    ?? "current-route-\(providerID)",
                providerID: providerID,
                displayName: matchedProfile?.name
                    ?? provider.displayName
                    ?? "当前中转",
                baseURL: baseURL,
                model: model,
                contextWindow: live.contextWindow,
                autoCompactTokenLimit:
                    live.autoCompactTokenLimit,
                reasoningEffort:
                    Self.normalizedReasoning(
                        live.reasoningEffort
                    ),
                credentialReference:
                    matchedProfile?
                        .v011CredentialReference
                        ?? "current-route/\(providerID)",
                requiresOpenAIAuth:
                    requiresOpenAIAuth,
                upstreamName: provider.displayName,
                modelVerbosity:
                    live.modelVerbosity.map {
                        .set($0)
                    } ?? .remove,
                serviceTier:
                    live.serviceTier.map {
                        .set($0)
                    } ?? .remove,
                modelCatalogJSON:
                    live.modelCatalogJSON.map {
                        .set($0)
                    } ?? .remove,
                webSearch:
                    live.webSearch.map {
                        .set($0)
                    } ?? .remove,
                disableResponseStorage:
                    live.disableResponseStorage.map {
                        .set($0)
                    } ?? .remove,
                fastMode:
                    live.fastMode.map {
                        .set($0)
                    } ?? .remove,
                supportsWebSockets:
                    provider.supportsWebSockets.map {
                        .set($0)
                    } ?? .remove,
                supportsStandaloneWebSearch:
                    provider.supportsStandaloneWebSearch.map {
                        .set($0)
                    } ?? .remove
            )
            return .relay(
                profile,
                host,
                matchedProfile?.id,
                inlineSecret
            )
        }
    }

    func credentialsAreScrubbed(
        in document: TOMLSemanticDocument,
        managedProviderIDs: Set<String>,
        activeProviderID: String?,
        requireActiveInlineSecret: Bool = true
    ) -> Bool {
        for providerID in managedProviderIDs {
            let fields = [
                "experimental_bearer_token",
                "env_key",
                "auth",
            ]
            for field in fields {
                let prefix = TOMLSemanticEngine.path([
                    "model_providers",
                    providerID,
                    field,
                ])
                let exists = document.leaves.keys.contains {
                    $0 == prefix || $0.hasPrefix(prefix + "/")
                }
                if providerID == activeProviderID,
                   field == "experimental_bearer_token",
                   requireActiveInlineSecret {
                    guard exists else { return false }
                } else if exists {
                    return false
                }
            }
        }
        return true
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
