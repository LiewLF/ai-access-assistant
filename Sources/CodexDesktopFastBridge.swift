#if canImport(AppKit)
import AppKit
#endif
import Foundation

struct CodexDesktopBuildIdentity: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let cliVersion: String
    let cliSHA256: String
    let appASARSHA256: String
}

enum CodexDesktopAuthenticationMethod: String, Codable, Sendable {
    case chatGPT = "chatgpt"
    case apiKey = "apikey"
    case amazonBedrock
    case personalAccessToken
    case unknown
}

struct CodexDesktopRunningApplication: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

enum CodexDesktopExternalControlPlaneKind:
    String, Codable, Equatable, Sendable {
    case codexPlusPlus = "codex_plus_plus"
    case codexPlusPlusManager = "codex_plus_plus_manager"
    case ccSwitch = "cc_switch"
}

struct CodexDesktopExternalControlPlane: Equatable, Sendable {
    let kind: CodexDesktopExternalControlPlaneKind
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

struct CodexDesktopExternalControlPlaneDetector: Sendable {
    private static let bundleKinds: [
        String: CodexDesktopExternalControlPlaneKind
    ] = [
        "com.bigpizzav3.codexplusplus": .codexPlusPlus,
        "com.bigpizzav3.codexplusplus.manager":
            .codexPlusPlusManager,
        "com.ccswitch.desktop": .ccSwitch,
    ]

    func detect(
        in applications: [CodexDesktopRunningApplication]
    ) -> [CodexDesktopExternalControlPlane] {
        applications.compactMap { application in
            guard let kind = kind(for: application) else {
                return nil
            }
            return CodexDesktopExternalControlPlane(
                kind: kind,
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }.sorted { left, right in
            if left.kind.rawValue != right.kind.rawValue {
                return left.kind.rawValue < right.kind.rawValue
            }
            return left.processIdentifier < right.processIdentifier
        }
    }

    private func kind(
        for application: CodexDesktopRunningApplication
    ) -> CodexDesktopExternalControlPlaneKind? {
        if let identifier = application.bundleIdentifier {
            return Self.bundleKinds[identifier]
        }
        let name = application.localizedName?
            .lowercased()
            .replacingOccurrences(of: " ", with: "") ?? ""
        switch name {
        case "codex++":
            return .codexPlusPlus
        case "codex++管理工具":
            return .codexPlusPlusManager
        case "ccswitch":
            return .ccSwitch
        default:
            return nil
        }
    }
}

#if canImport(AppKit)
struct CodexDesktopSystemRunningApplicationSource: Sendable {
    func snapshots() -> [CodexDesktopRunningApplication] {
        NSWorkspace.shared.runningApplications.map { application in
            CodexDesktopRunningApplication(
                processIdentifier: Int32(
                    application.processIdentifier
                ),
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }
    }
}
#endif

struct CodexDesktopNativeFastContract: Equatable, Sendable {
    let contractID: String
    let appVersion: String
    let appBuild: String
    let cliVersion: String
    let cliSHA256: String
    let appASARSHA256: String
    let configurationReadOperation: String
    let configurationWriteOperation: String
    let globalConfigurationKeyPath: String
    let profileConfigurationKeyPath: String
    let reloadsUserConfiguration: Bool
    let modelCatalogOperation: String
    let requestParameter: String
    let normalizedFastRequestValue: String
    let standardConfigurationValue: String
    let fastConfigurationAliases: Set<String>
    let authenticationMethod: CodexDesktopAuthenticationMethod
    let requirementKey: String
    let requestSurfaces: Set<String>
    let evidenceID: String

    static let current6067 = CodexDesktopNativeFastContract(
        contractID:
            "codex-desktop-fast-26.727.40816-6067-cli-0.146.0-alpha.9.2-v1",
        appVersion: "26.727.40816",
        appBuild: "6067",
        cliVersion: "0.146.0-alpha.9.2",
        cliSHA256:
            "68474c6192406b8a0278243c8283b87a84798a69fb498f30c3715861f8082542",
        appASARSHA256:
            "0e4f824024d0838dd7548751c02d3a7d21917c4fc3edf74c9e98d88ea9e3127d",
        configurationReadOperation: "read-config-for-host",
        configurationWriteOperation: "batch-write-config-value",
        globalConfigurationKeyPath: "service_tier",
        profileConfigurationKeyPath:
            "profiles.<profile>.service_tier",
        reloadsUserConfiguration: true,
        modelCatalogOperation: "list-models-for-host",
        requestParameter: "serviceTier",
        normalizedFastRequestValue: "priority",
        standardConfigurationValue: "default",
        fastConfigurationAliases: ["fast", "priority"],
        authenticationMethod: .chatGPT,
        requirementKey: "fast_mode",
        requestSurfaces: [
            "startThread",
            "startTurn",
            "followUpTurn",
            "resumeThread",
        ],
        evidenceID:
            "desktop-asar-26.727.40816-6067-service-tier-v1"
    )

    func matches(_ identity: CodexDesktopBuildIdentity) -> Bool {
        appVersion == identity.appVersion
            && appBuild == identity.appBuild
            && cliVersion == identity.cliVersion
            && cliSHA256 == identity.cliSHA256.lowercased()
            && appASARSHA256
                == identity.appASARSHA256.lowercased()
    }

    var isComplete: Bool {
        !contractID.isEmpty
            && !configurationReadOperation.isEmpty
            && configurationWriteOperation
                == "batch-write-config-value"
            && globalConfigurationKeyPath == "service_tier"
            && profileConfigurationKeyPath
                == "profiles.<profile>.service_tier"
            && reloadsUserConfiguration
            && modelCatalogOperation == "list-models-for-host"
            && requestParameter == "serviceTier"
            && normalizedFastRequestValue == "priority"
            && standardConfigurationValue == "default"
            && fastConfigurationAliases
                .isSuperset(of: ["fast", "priority"])
            && authenticationMethod == .chatGPT
            && requirementKey == "fast_mode"
            && requestSurfaces
                .isSuperset(of: ["startThread", "startTurn"])
            && cliSHA256.count == 64
            && appASARSHA256.count == 64
            && !evidenceID.isEmpty
    }

    func isFastAlias(_ value: String?) -> Bool {
        guard let normalized = normalized(value) else {
            return false
        }
        return fastConfigurationAliases.contains(normalized)
    }

    func modelTier(
        for intent: ProviderServiceTierIntent,
        model: ProviderModelCapability
    ) -> String? {
        let catalogValues = model.serviceTiers
            + (model.defaultServiceTier.map { [$0] } ?? [])
        switch intent.kind {
        case .fast:
            return catalogValues.first(where: isFastAlias)
        case .flex:
            return catalogValues.first(where: {
                normalized($0) == "flex"
            })
        case .providerSpecific:
            guard let requested = normalized(intent.providerValue)
            else { return nil }
            return catalogValues.first(where: {
                normalized($0) == requested
            })
        case .inherit, .followCodex, .standard:
            return nil
        }
    }

    func emittedValue(
        for intent: ProviderServiceTierIntent,
        catalogTier: String?
    ) -> String? {
        switch intent.kind {
        case .inherit, .followCodex, .standard:
            return nil
        case .fast:
            return normalizedFastRequestValue
        case .flex:
            return "flex"
        case .providerSpecific:
            guard let value = normalized(catalogTier) else {
                return nil
            }
            return isFastAlias(value)
                ? normalizedFastRequestValue : value
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct CodexDesktopServiceTierRequestObservation:
    Equatable, Sendable {
    let parameterName: String
    let value: String?
}

struct CodexDesktopFastProviderObservation: Equatable, Sendable {
    let responseTier: String?
    let fixedContractConfirmsPassthrough: Bool
    let liveRevalidationPassed: Bool

    static let none = CodexDesktopFastProviderObservation(
        responseTier: nil,
        fixedContractConfirmsPassthrough: false,
        liveRevalidationPassed: false
    )
}

enum CodexDesktopFastEvidenceLevel:
    Int, Codable, Comparable, Sendable {
    case none = 0
    case l1ModelCatalog = 1
    case l2Request = 2
    case l3Response = 3
    case l4ProviderContract = 4

    static func < (
        lhs: CodexDesktopFastEvidenceLevel,
        rhs: CodexDesktopFastEvidenceLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CodexDesktopFastConfigurationAction:
    String, Codable, Sendable {
    case preserve
    case noChange = "no_change"
    case writeViaFable = "write_via_fable"
    case removeViaFable = "remove_via_fable"
    case blocked
}

enum CodexDesktopFastBlocker: Equatable, Sendable {
    case nativeBridgeMissing
    case nativeContractMismatch
    case nativeContractIncomplete
    case externalControlPlaneActive(String)
    case chatGPTAuthenticationRequired
    case fastModeRequirementUnknown
    case fastModeDisabledByRequirement
    case modelCatalogUnavailable
    case modelDoesNotSupportTier(String)
    case invalidTierIntent
    case requestObservationMismatch
    case providerFallbackObserved(String)
}

struct CodexDesktopFastBridgeInput: Equatable, Sendable {
    let identity: CodexDesktopBuildIdentity
    let intent: ProviderServiceTierIntent
    let model: ProviderModelCapability?
    let authenticationMethod: CodexDesktopAuthenticationMethod
    let fastModeRequirement: Bool?
    let observedConfigurationValue: String?
    let requestObservation:
        CodexDesktopServiceTierRequestObservation?
    let providerObservation: CodexDesktopFastProviderObservation
    let runningApplications: [CodexDesktopRunningApplication]

    init(
        identity: CodexDesktopBuildIdentity,
        intent: ProviderServiceTierIntent,
        model: ProviderModelCapability?,
        authenticationMethod: CodexDesktopAuthenticationMethod,
        fastModeRequirement: Bool?,
        observedConfigurationValue: String?,
        requestObservation:
            CodexDesktopServiceTierRequestObservation? = nil,
        providerObservation:
            CodexDesktopFastProviderObservation = .none,
        runningApplications:
            [CodexDesktopRunningApplication] = []
    ) {
        self.identity = identity
        self.intent = intent
        self.model = model
        self.authenticationMethod = authenticationMethod
        self.fastModeRequirement = fastModeRequirement
        self.observedConfigurationValue =
            observedConfigurationValue
        self.requestObservation = requestObservation
        self.providerObservation = providerObservation
        self.runningApplications = runningApplications
    }
}

struct CodexDesktopFastBridgeAssessment: Equatable, Sendable {
    let capabilityStatus: ProviderCapabilityStatus
    let evidenceLevel: CodexDesktopFastEvidenceLevel
    let configurationAction: CodexDesktopFastConfigurationAction
    let desiredConfigurationValue: String?
    let configurationKeyPath: String?
    let requestParameter: String?
    let normalizedRequestValue: String?
    let catalogTier: String?
    let evidenceIDs: [String]
    let blockers: [CodexDesktopFastBlocker]
    let externalControlPlanes: [CodexDesktopExternalControlPlane]
    let configurationWriter: String?
    let managesThreadOverrides: Bool
}

struct CodexDesktopFastBridge: Sendable {
    let contracts: [CodexDesktopNativeFastContract]
    let controlPlaneDetector:
        CodexDesktopExternalControlPlaneDetector

    init(
        contracts: [CodexDesktopNativeFastContract] = [
            .current6067,
        ],
        controlPlaneDetector:
            CodexDesktopExternalControlPlaneDetector =
                CodexDesktopExternalControlPlaneDetector()
    ) {
        self.contracts = contracts
        self.controlPlaneDetector = controlPlaneDetector
    }

    func assess(
        _ input: CodexDesktopFastBridgeInput
    ) -> CodexDesktopFastBridgeAssessment {
        let controls = controlPlaneDetector.detect(
            in: input.runningApplications
        )
        guard !contracts.isEmpty else {
            return blocked(
                .nativeBridgeMissing,
                controls: controls
            )
        }
        guard let contract = contracts.first(where: {
            $0.matches(input.identity)
        }) else {
            return blocked(
                .nativeContractMismatch,
                controls: controls
            )
        }
        guard contract.isComplete else {
            return blocked(
                .nativeContractIncomplete,
                controls: controls
            )
        }

        switch input.intent.kind {
        case .inherit:
            return CodexDesktopFastBridgeAssessment(
                capabilityStatus: .unknown,
                evidenceLevel: .none,
                configurationAction: .preserve,
                desiredConfigurationValue: nil,
                configurationKeyPath: nil,
                requestParameter: nil,
                normalizedRequestValue: nil,
                catalogTier: nil,
                evidenceIDs: [contract.evidenceID],
                blockers: [],
                externalControlPlanes: controls,
                configurationWriter: nil,
                managesThreadOverrides: false
            )
        case .followCodex:
            return CodexDesktopFastBridgeAssessment(
                capabilityStatus: .requested,
                evidenceLevel: .none,
                configurationAction: .removeViaFable,
                desiredConfigurationValue: nil,
                configurationKeyPath:
                    contract.globalConfigurationKeyPath,
                requestParameter: contract.requestParameter,
                normalizedRequestValue: nil,
                catalogTier: nil,
                evidenceIDs: [contract.evidenceID],
                blockers: [],
                externalControlPlanes: controls,
                configurationWriter: "FableSwitchCore",
                managesThreadOverrides: false
            )
        case .standard:
            return standardAssessment(
                input: input,
                contract: contract,
                controls: controls
            )
        case .fast, .flex, .providerSpecific:
            return tierAssessment(
                input: input,
                contract: contract,
                controls: controls
            )
        }
    }

    private func standardAssessment(
        input: CodexDesktopFastBridgeInput,
        contract: CodexDesktopNativeFastContract,
        controls: [CodexDesktopExternalControlPlane]
    ) -> CodexDesktopFastBridgeAssessment {
        let normalized = input.observedConfigurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let alreadyStandard = normalized == nil
            || normalized == "default"
            || normalized == "standard"
            || normalized == "auto"
        if !alreadyStandard, !controls.isEmpty {
            return blocked(
                .externalControlPlaneActive(
                    controls.map(\.kind.rawValue)
                        .joined(separator: ",")
                ),
                controls: controls,
                desiredConfigurationValue:
                    contract.standardConfigurationValue,
                contract: contract
            )
        }
        return CodexDesktopFastBridgeAssessment(
            capabilityStatus:
                alreadyStandard ? .verified : .requested,
            evidenceLevel: .none,
            configurationAction:
                alreadyStandard ? .noChange : .writeViaFable,
            desiredConfigurationValue:
                contract.standardConfigurationValue,
            configurationKeyPath:
                contract.globalConfigurationKeyPath,
            requestParameter: contract.requestParameter,
            normalizedRequestValue: nil,
            catalogTier: nil,
            evidenceIDs: [contract.evidenceID],
            blockers: [],
            externalControlPlanes: controls,
            configurationWriter:
                alreadyStandard ? nil : "FableSwitchCore",
            managesThreadOverrides: false
        )
    }

    private func tierAssessment(
        input: CodexDesktopFastBridgeInput,
        contract: CodexDesktopNativeFastContract,
        controls: [CodexDesktopExternalControlPlane]
    ) -> CodexDesktopFastBridgeAssessment {
        guard input.authenticationMethod
                == contract.authenticationMethod else {
            return blocked(
                .chatGPTAuthenticationRequired,
                controls: controls,
                contract: contract
            )
        }
        guard let requirement = input.fastModeRequirement else {
            return blocked(
                .fastModeRequirementUnknown,
                controls: controls,
                contract: contract
            )
        }
        guard requirement else {
            return blocked(
                .fastModeDisabledByRequirement,
                controls: controls,
                contract: contract
            )
        }
        guard let model = input.model else {
            return blocked(
                .modelCatalogUnavailable,
                controls: controls,
                contract: contract
            )
        }
        guard let catalogTier = contract.modelTier(
            for: input.intent,
            model: model
        ) else {
            let requested = input.intent.configuredValue
                ?? input.intent.providerValue
                ?? input.intent.kind.rawValue
            return blocked(
                .modelDoesNotSupportTier(requested),
                controls: controls,
                status: .unsupported,
                contract: contract
            )
        }
        guard let desired = desiredConfigurationValue(
            for: input.intent
        ),
        let emitted = contract.emittedValue(
            for: input.intent,
            catalogTier: catalogTier
        ) else {
            return blocked(
                .invalidTierIntent,
                controls: controls,
                contract: contract
            )
        }

        let configurationMatches = valuesMatch(
            input.observedConfigurationValue,
            desired,
            contract: contract
        )
        if !configurationMatches, !controls.isEmpty {
            return blocked(
                .externalControlPlaneActive(
                    controls.map(\.kind.rawValue)
                        .joined(separator: ",")
                ),
                controls: controls,
                desiredConfigurationValue: desired,
                contract: contract
            )
        }

        var evidenceLevel: CodexDesktopFastEvidenceLevel =
            .l1ModelCatalog
        var status: ProviderCapabilityStatus = .requested
        var blockers: [CodexDesktopFastBlocker] = []
        var evidenceIDs = [
            contract.evidenceID,
            "model-catalog:\(model.modelID):\(catalogTier)",
        ]
        let requestWasObserved = requestMatches(
            input.requestObservation,
            emitted: emitted,
            contract: contract
        )
        if configurationMatches, requestWasObserved {
            evidenceLevel = .l2Request
            evidenceIDs.append(
                "request:\(contract.requestParameter)=\(emitted)"
            )
        } else if input.requestObservation != nil {
            status = .degraded
            blockers.append(.requestObservationMismatch)
        }

        if evidenceLevel >= .l2Request,
           let responseTier = normalized(
               input.providerObservation.responseTier
           ) {
            if valuesMatch(
                responseTier,
                emitted,
                contract: contract
            ) {
                evidenceLevel = .l3Response
                status = .verified
                evidenceIDs.append(
                    "response:service-tier=\(responseTier)"
                )
            } else {
                status = .degraded
                blockers.append(
                    .providerFallbackObserved(responseTier)
                )
            }
        }

        if evidenceLevel >= .l2Request,
           blockers.isEmpty,
           input.providerObservation
            .fixedContractConfirmsPassthrough,
           input.providerObservation.liveRevalidationPassed {
            evidenceLevel = .l4ProviderContract
            status = .verified
            evidenceIDs.append(
                "provider-contract:fixed-and-live"
            )
        }

        return CodexDesktopFastBridgeAssessment(
            capabilityStatus: status,
            evidenceLevel: evidenceLevel,
            configurationAction:
                configurationMatches
                    ? .noChange : .writeViaFable,
            desiredConfigurationValue: desired,
            configurationKeyPath:
                contract.globalConfigurationKeyPath,
            requestParameter: contract.requestParameter,
            normalizedRequestValue: emitted,
            catalogTier: catalogTier,
            evidenceIDs: evidenceIDs,
            blockers: blockers,
            externalControlPlanes: controls,
            configurationWriter:
                configurationMatches ? nil : "FableSwitchCore",
            managesThreadOverrides: false
        )
    }

    private func desiredConfigurationValue(
        for intent: ProviderServiceTierIntent
    ) -> String? {
        switch intent.kind {
        case .inherit, .followCodex:
            return nil
        case .standard:
            return "default"
        case .fast:
            return "fast"
        case .flex:
            return "flex"
        case .providerSpecific:
            return normalized(intent.providerValue)
        }
    }

    private func requestMatches(
        _ observation:
            CodexDesktopServiceTierRequestObservation?,
        emitted: String,
        contract: CodexDesktopNativeFastContract
    ) -> Bool {
        guard let observation,
              observation.parameterName == contract.requestParameter,
              let value = normalized(observation.value) else {
            return false
        }
        return valuesMatch(value, emitted, contract: contract)
    }

    private func valuesMatch(
        _ observed: String?,
        _ expected: String,
        contract: CodexDesktopNativeFastContract
    ) -> Bool {
        guard let observed = normalized(observed),
              let expected = normalized(expected) else {
            return false
        }
        if contract.isFastAlias(observed),
           contract.isFastAlias(expected) {
            return true
        }
        return observed == expected
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func blocked(
        _ blocker: CodexDesktopFastBlocker,
        controls: [CodexDesktopExternalControlPlane],
        status: ProviderCapabilityStatus = .unknown,
        desiredConfigurationValue: String? = nil,
        contract: CodexDesktopNativeFastContract? = nil
    ) -> CodexDesktopFastBridgeAssessment {
        CodexDesktopFastBridgeAssessment(
            capabilityStatus: status,
            evidenceLevel: .none,
            configurationAction: .blocked,
            desiredConfigurationValue: desiredConfigurationValue,
            configurationKeyPath:
                contract?.globalConfigurationKeyPath,
            requestParameter: contract?.requestParameter,
            normalizedRequestValue: nil,
            catalogTier: nil,
            evidenceIDs: contract.map { [$0.evidenceID] } ?? [],
            blockers: [blocker],
            externalControlPlanes: controls,
            configurationWriter: nil,
            managesThreadOverrides: false
        )
    }
}
