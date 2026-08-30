// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct CodexRelayProfile: Codable, Equatable, Identifiable {
    let id: String
    let providerID: String?
    let name: String
    let baseURL: String
    let wireProtocol: RelayWireProtocol
    let models: [String]
    let defaultModel: String
    let contextWindow: Int?
    let autoCompactTokenLimit: Int?
    let reasoningEffort: ReasoningEffort
    let localGatewayConfirmed: Bool?
    let catalogEntryID: String?
    let capabilityProfile: ProviderCapabilityProfile?
    let additionalFields: [String: JSONValue]

    init(
        id: String,
        providerID: String? = nil,
        name: String,
        baseURL: String,
        wireProtocol: RelayWireProtocol,
        models: [String],
        defaultModel: String,
        contextWindow: Int?,
        autoCompactTokenLimit: Int?,
        reasoningEffort: ReasoningEffort,
        localGatewayConfirmed: Bool? = nil,
        catalogEntryID: String? = nil,
        capabilityProfile: ProviderCapabilityProfile? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.baseURL = baseURL
        self.wireProtocol = wireProtocol
        self.models = models
        self.defaultModel = defaultModel
        self.contextWindow = contextWindow
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.reasoningEffort = reasoningEffort
        self.localGatewayConfirmed = localGatewayConfirmed
        self.catalogEntryID = catalogEntryID
        self.capabilityProfile = capabilityProfile
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: DynamicCodingKey.self
        )
        id = try container.decode(
            String.self,
            forKey: DynamicCodingKey("id")
        )
        providerID = try container.decodeIfPresent(
            String.self,
            forKey: DynamicCodingKey("providerID")
        )
        name = try container.decode(
            String.self,
            forKey: DynamicCodingKey("name")
        )
        baseURL = try container.decode(
            String.self,
            forKey: DynamicCodingKey("baseURL")
        )
        wireProtocol = try container.decode(
            RelayWireProtocol.self,
            forKey: DynamicCodingKey("wireProtocol")
        )
        models = try container.decode(
            [String].self,
            forKey: DynamicCodingKey("models")
        )
        defaultModel = try container.decode(
            String.self,
            forKey: DynamicCodingKey("defaultModel")
        )
        contextWindow = try container.decodeIfPresent(
            Int.self,
            forKey: DynamicCodingKey("contextWindow")
        )
        autoCompactTokenLimit = try container.decodeIfPresent(
            Int.self,
            forKey: DynamicCodingKey("autoCompactTokenLimit")
        )
        reasoningEffort = try container.decode(
            ReasoningEffort.self,
            forKey: DynamicCodingKey("reasoningEffort")
        )
        localGatewayConfirmed = try container.decodeIfPresent(
            Bool.self,
            forKey: DynamicCodingKey("localGatewayConfirmed")
        )
        catalogEntryID = try container.decodeIfPresent(
            String.self,
            forKey: DynamicCodingKey("catalogEntryID")
        )
        capabilityProfile = try container.decodeIfPresent(
            ProviderCapabilityProfile.self,
            forKey: DynamicCodingKey("capabilityProfile")
        )
        additionalFields = try Dictionary(
            uniqueKeysWithValues: container.allKeys.compactMap { key in
                guard !Self.knownKeys.contains(key.stringValue) else {
                    return nil
                }
                return (
                    key.stringValue,
                    try container.decode(JSONValue.self, forKey: key)
                )
            }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: DynamicCodingKey.self
        )
        try container.encode(id, forKey: DynamicCodingKey("id"))
        try container.encodeIfPresent(
            providerID,
            forKey: DynamicCodingKey("providerID")
        )
        try container.encode(name, forKey: DynamicCodingKey("name"))
        try container.encode(
            baseURL,
            forKey: DynamicCodingKey("baseURL")
        )
        try container.encode(
            wireProtocol,
            forKey: DynamicCodingKey("wireProtocol")
        )
        try container.encode(
            models,
            forKey: DynamicCodingKey("models")
        )
        try container.encode(
            defaultModel,
            forKey: DynamicCodingKey("defaultModel")
        )
        try container.encodeIfPresent(
            contextWindow,
            forKey: DynamicCodingKey("contextWindow")
        )
        try container.encodeIfPresent(
            autoCompactTokenLimit,
            forKey: DynamicCodingKey("autoCompactTokenLimit")
        )
        try container.encode(
            reasoningEffort,
            forKey: DynamicCodingKey("reasoningEffort")
        )
        try container.encodeIfPresent(
            localGatewayConfirmed,
            forKey: DynamicCodingKey("localGatewayConfirmed")
        )
        try container.encodeIfPresent(
            catalogEntryID,
            forKey: DynamicCodingKey("catalogEntryID")
        )
        try container.encodeIfPresent(
            capabilityProfile,
            forKey: DynamicCodingKey("capabilityProfile")
        )
        for (key, value) in additionalFields
            where !Self.knownKeys.contains(key) {
            try container.encode(
                value,
                forKey: DynamicCodingKey(key)
            )
        }
    }

    var effectiveCapabilityProfile: ProviderCapabilityProfile {
        capabilityProfile ?? ProviderCapabilityProfile.legacy(
            providerID: providerID
                ?? PreservingTOMLEditor.providerIdentifier(id),
            displayName: name,
            baseURL: baseURL,
            models: models,
            defaultModel: defaultModel,
            contextWindow: contextWindow,
            localAutoCompactLimit: autoCompactTokenLimit,
            reasoningEffort: Self.reasoningValue(reasoningEffort)
        )
    }

    func updatingCapabilityProfile(
        _ profile: ProviderCapabilityProfile?
    ) -> CodexRelayProfile {
        updatingCapabilities(
            profile,
            contextWindow: contextWindow,
            autoCompactTokenLimit: autoCompactTokenLimit,
            reasoningEffort: reasoningEffort
        )
    }

    func updatingCapabilities(
        _ profile: ProviderCapabilityProfile?,
        contextWindow: Int?,
        autoCompactTokenLimit: Int?,
        reasoningEffort: ReasoningEffort
    ) -> CodexRelayProfile {
        CodexRelayProfile(
            id: id,
            providerID: providerID,
            name: name,
            baseURL: baseURL,
            wireProtocol: wireProtocol,
            models: models,
            defaultModel: defaultModel,
            contextWindow: contextWindow,
            autoCompactTokenLimit: autoCompactTokenLimit,
            reasoningEffort: reasoningEffort,
            localGatewayConfirmed: localGatewayConfirmed,
            catalogEntryID: catalogEntryID,
            capabilityProfile: profile,
            additionalFields: additionalFields
        )
    }

    func updatingRelaySettings(
        name: String,
        baseURL: String,
        defaultModel: String
    ) -> CodexRelayProfile {
        var updatedModels = models
        if !updatedModels.contains(defaultModel) {
            updatedModels.append(defaultModel)
        }
        let updatedCapability = effectiveCapabilityProfile
            .updatingRelaySettings(
                displayName: name,
                baseURL: baseURL,
                models: updatedModels,
                defaultModel: defaultModel
            )
        return CodexRelayProfile(
            id: id,
            providerID: providerID,
            name: name,
            baseURL: baseURL,
            wireProtocol: wireProtocol,
            models: updatedModels,
            defaultModel: defaultModel,
            contextWindow: contextWindow,
            autoCompactTokenLimit:
                autoCompactTokenLimit,
            reasoningEffort: reasoningEffort,
            localGatewayConfirmed: localGatewayConfirmed,
            catalogEntryID: catalogEntryID,
            capabilityProfile: updatedCapability,
            additionalFields: additionalFields
        )
    }

    private static let knownKeys: Set<String> = [
        "id",
        "providerID",
        "name",
        "baseURL",
        "wireProtocol",
        "models",
        "defaultModel",
        "contextWindow",
        "autoCompactTokenLimit",
        "reasoningEffort",
        "localGatewayConfirmed",
        "catalogEntryID",
        "capabilityProfile",
    ]

    private static func reasoningValue(
        _ value: ReasoningEffort
    ) -> String? {
        switch value {
        case .automatic:
            return nil
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            return "xhigh"
        case .max:
            return "max"
        case .ultra:
            return "ultra"
        }
    }
}
