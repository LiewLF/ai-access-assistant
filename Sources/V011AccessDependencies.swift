import AppKit
import Foundation

struct V011AccessDependencies: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let keyProvider: @Sendable () throws -> Data
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let currentConnectionRuntimeVerifier:
        any FableRuntimeVerifier
    let agentLoopVerifier:
        any V011AgentLoopVerifying
    let officialUsageReader:
        any V011OfficialUsageReading
    let savedRelayReadinessVerifier:
        any V011SavedRelayReadinessVerifying
    let allowsUnpromptedRefresh: Bool
    let atomicWriter: FableAtomicConfigWriter
    let versionDiscovery: any FableCodexVersionDiscovering
    let sessionCore: any V011SessionCoreOperating
    let now: @Sendable () -> Date
    let codexRuntimeObservation:
        @Sendable () -> V011CodexRuntimeObservation
    let beforeConnectionReceiptSave:
        @Sendable () throws -> Void
    let afterConnectionReceiptSave:
        @Sendable () throws -> Void
    let beforeOfficialRecoverySave:
        @Sendable () throws -> Void
    let adoptionFaultInjector:
        @Sendable (V011AdoptionFaultPoint) throws -> Void
    let verifyDraft: @Sendable
        (CodexRelayProfile, String) async throws -> String
    let verifyCurrentRelay: @Sendable
        (CodexRelayProfile, String) async throws -> String

    static let live: V011AccessDependencies = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        let codexHome: URL
        if let override = ProcessInfo.processInfo
            .environment["CODEX_HOME"],
           !override.isEmpty {
            codexHome = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        } else {
            codexHome = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".codex",
                    isDirectory: true
                )
        }
        let credentialStore =
            FableMacOSKeychainCredentialStore()
        let versionDiscovery =
            FableCodexVersionDiscovery()
        return V011AccessDependencies(
            codexHome: codexHome,
            controlRoot: support
                .appendingPathComponent(
                    "AI接入助手",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "ControlPlane",
                    isDirectory: true
                ),
            keyProvider: {
                try AppVaultKeyStore.loadOrCreate()
            },
            credentialStore: credentialStore,
            processController:
                FableMacOSProcessController(),
            runtimeVerifier: FableLiveRuntimeVerifier(
                codexHome: codexHome,
                credentialStore: credentialStore,
                versionDiscovery: versionDiscovery
            ),
            currentConnectionRuntimeVerifier:
                FableLiveRuntimeVerifier(
                    codexHome: codexHome,
                    credentialStore: credentialStore,
                    versionDiscovery: versionDiscovery,
                    commandTimeout: 20
                ),
            agentLoopVerifier:
                V011LiveAgentLoopVerifier(
                    codexHome: codexHome,
                    versionDiscovery: versionDiscovery
                ),
            officialUsageReader:
                V011LiveOfficialUsageReader(
                    versionDiscovery: versionDiscovery
                ),
            savedRelayReadinessVerifier:
                V011LiveSavedRelayReadinessVerifier(
                    codexHome: codexHome,
                    versionDiscovery: versionDiscovery
                ),
            allowsUnpromptedRefresh: false,
            atomicWriter: FableAtomicConfigWriter(),
            versionDiscovery: versionDiscovery,
            sessionCore: SessionCoreClient(),
            now: { Date() },
            codexRuntimeObservation: {
                let applications = NSWorkspace.shared
                    .runningApplications
                    .filter {
                        $0.bundleIdentifier
                            == FableMacOSProcessController
                                .codexBundleIdentifier
                    }
                guard !applications.isEmpty else {
                    return .notRunning
                }
                let launchDates = applications.compactMap {
                    $0.launchDate
                }
                guard launchDates.count == applications.count,
                      let earliest = launchDates.min() else {
                    return .runningUnknown
                }
                return .running(
                    earliestLaunchDate: earliest
                )
            },
            beforeConnectionReceiptSave: {},
            afterConnectionReceiptSave: {},
            beforeOfficialRecoverySave: {},
            adoptionFaultInjector: { _ in },
            verifyDraft: { profile, apiKey in
                try await RelayConnectionVerifier.verify(
                    profile: profile,
                    apiKey: apiKey,
                    confirmedLocalGateway:
                        profile.localGatewayConfirmed == true
                )
            },
            verifyCurrentRelay: { profile, apiKey in
                try await RelayConnectionVerifier.verify(
                    profile: profile,
                    apiKey: apiKey,
                    confirmedLocalGateway:
                        profile.localGatewayConfirmed == true,
                    verifyModelCatalog: false
                )
            }
        )
    }()
}
