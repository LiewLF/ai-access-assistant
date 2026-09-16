// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011CurrentConnectionVerifier: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let versionDiscovery: any FableCodexVersionDiscovering
    let sessionCore: any V011SessionCoreOperating
    let versionContract: CodexVersionContract

    func verify(
        now: @Sendable () -> Date = { Date() },
        requireSavedRelayProfile: Bool = false,
        relayVerifier: (@Sendable (
            RelayProfile,
            String
        ) async throws -> Void)? = nil
    ) async throws -> V011CurrentConnectionVerification {
        let installation = try versionDiscovery.discover()
        guard let resolvedContractEntry =
                installation.contractEntry,
              resolvedContractEntry.matches(
                  installation.identity
              ),
              case let .verified(discoveredSchemaID) =
                installation.support,
              discoveredSchemaID
                == resolvedContractEntry.schemaID else {
            throw FableSwitchError.unsupportedVersion
        }

        let beforeManaged = try managedStateStore.load()
        let beforeCore = makeCore(
            managedProviderIDs:
                managedProviderIDs.union(
                    beforeManaged.managedProviderIDSet
                ),
            resolvedContractEntry:
                resolvedContractEntry
        )
        let before = try beforeCore.inspect(
            version: installation.identity
        )
        guard try currentConfigurationHash(before.configURL)
                == before.configHash else {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
        let route = try routeResolver.resolve(
            live: before,
            managedState: beforeManaged,
            requireSavedRelayProfile:
                requireSavedRelayProfile
        )

        var verificationFailure: Error?
        do {
            switch route {
            case .official:
                try runtimeVerifier.verifyOfficial()
            case let .relay(profile, _, _, secret):
                if let secret, let relayVerifier {
                    try await relayVerifier(profile, secret)
                } else {
                    // A local gateway holds no inline key, so an HTTP probe
                    // could only send an unauthenticated request. The bounded
                    // runtime check is the proof that stays available.
                    try runtimeVerifier.verifyRelay(profile)
                }
            }
        } catch {
            verificationFailure = error
        }

        let sessionProviderCheck: V011SessionProviderCheck
        do {
            sessionProviderCheck = try await sessionInspector
                .sessionsMatchTarget(
                    providerID: route.providerID
                ) ? .synchronized : .drifted
        } catch {
            sessionProviderCheck = .unavailable
        }

        // SessionCore is asynchronous. Re-inspect only after it has
        // completed so a configuration change during that await cannot be
        // committed as a successful verification receipt.
        let afterManaged = try managedStateStore.load()
        let afterCore = makeCore(
            managedProviderIDs:
                managedProviderIDs.union(
                    afterManaged.managedProviderIDSet
                ),
            resolvedContractEntry:
                resolvedContractEntry
        )
        let after = try afterCore.inspect(
            version: installation.identity
        )
        guard before.configHash == after.configHash,
              try currentConfigurationHash(after.configURL)
                == after.configHash else {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
        let afterRoute: V011CurrentVerificationRoute
        do {
            afterRoute = try routeResolver.resolve(
                live: after,
                managedState: afterManaged,
                requireSavedRelayProfile:
                    requireSavedRelayProfile
            )
        } catch {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
        guard route.identity == afterRoute.identity,
              route.savedProfileID
                == afterRoute.savedProfileID else {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
        if let verificationFailure {
            let diagnosis = V011ConnectionHealthProbeDiagnosis
                .classify(verificationFailure)
            throw V011CurrentConnectionProbeFailure(
                state: after,
                providerID: afterRoute.providerID,
                configHash: after.configHash,
                endpointHost: afterRoute.endpointHost,
                sessionProviderCheck: sessionProviderCheck,
                failureCategory: diagnosis.category,
                httpStatus: diagnosis.httpStatus,
                safeMessage: V011RecoveryErrorText.safeDetail(
                    verificationFailure
                )
            )
        }

        return V011CurrentConnectionVerification(
            state: after,
            providerID: afterRoute.providerID,
            configHash: after.configHash,
            routeIdentity: afterRoute.identity,
            verifiedAt: now(),
            endpointHost: afterRoute.endpointHost,
            sessionProviderCheck: sessionProviderCheck,
            savedProfileID: afterRoute.savedProfileID
        )
    }

    /// Re-checks the exact route immediately before/after committing a
    /// detached verification receipt. This method is intentionally
    /// read-only and never trusts the previously loaded managed-state cache.
    func validate(
        _ verification: V011CurrentConnectionVerification,
        requireSavedRelayProfile: Bool = false
    ) throws {
        let installation = try versionDiscovery.discover()
        guard let resolvedContractEntry =
                installation.contractEntry,
              resolvedContractEntry.matches(
                  installation.identity
              ),
              case let .verified(discoveredSchemaID) =
                installation.support,
              discoveredSchemaID
                == resolvedContractEntry.schemaID else {
            throw FableSwitchError.unsupportedVersion
        }
        let managed = try managedStateStore.load()
        let core = makeCore(
            managedProviderIDs:
                managedProviderIDs.union(
                    managed.managedProviderIDSet
                ),
            resolvedContractEntry: resolvedContractEntry
        )
        let live = try core.inspect(
            version: installation.identity
        )
        guard live.configHash == verification.configHash,
              try currentConfigurationHash(live.configURL)
                == verification.configHash else {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
        let route = try routeResolver.resolve(
            live: live,
            managedState: managed,
            requireSavedRelayProfile:
                requireSavedRelayProfile
        )
        guard route.providerID == verification.providerID,
              route.identity == verification.routeIdentity,
              route.endpointHost == verification.endpointHost,
              route.savedProfileID
                == verification.savedProfileID else {
            throw V011CurrentConnectionVerificationError
                .configurationChangedDuringCheck
        }
    }

    private var managedStateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent("state.json")
        )
    }

    private var routeResolver: V011CurrentRouteResolver {
        V011CurrentRouteResolver(
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore
        )
    }

    private var configurationMatcher:
        V011TargetConfigurationMatcher {
        V011TargetConfigurationMatcher(
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore
        )
    }

    private var sessionInspector: V011SessionRecoveryInspector {
        V011SessionRecoveryInspector(
            codexHome: codexHome,
            sessionRecoveryRoot: controlRoot
                .appendingPathComponent(
                    "SessionCoreRecovery",
                    isDirectory: true
                ),
            sessionCore: sessionCore
        )
    }

    private func currentConfigurationHash(
        _ url: URL
    ) throws -> String {
        try configurationMatcher.currentConfigurationHash(url)
    }

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry:
            CodexVersionContract.Entry? = nil
    ) -> FableSwitchCore {
        FableSwitchCore(
            codexHome: codexHome,
            versionContract: versionContract,
            resolvedContractEntry:
                resolvedContractEntry,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            managedProviderIDs: managedProviderIDs
        )
    }
}
