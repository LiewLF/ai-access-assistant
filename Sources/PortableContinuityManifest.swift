// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum PortableContinuityError: Error, Equatable {
    case malformedDocument
    case unsupportedSchema
    case unknownField
    case forbiddenSensitiveField
    case invalidSourceIdentity
    case invalidEndpoint
    case invalidProfileShape
    case invalidWorkspaceLabel
    case duplicateIdentifier
    case invalidBoundary
    case invalidImportPolicy
    case invalidSelection
    case tooManyRecords
}

enum PortableAccessKind: String, Codable, Equatable, Sendable {
    case official
    case relay
}

enum PortableAPIProtocol: String, Codable, Equatable, Sendable {
    case responses
}

enum PortableSourcePlatform: String, Codable, Equatable, Sendable {
    case macOS
    case windows
}

enum PortableStartDestination: String, Codable, Equatable, Sendable {
    case start
    case access
    case history
}

enum PortableHistoryGrouping: String, Codable, Equatable, Sendable {
    case recent
    case workspace
    case recovery
}

struct PortableAccessProfile: Codable, Equatable, Sendable {
    let id: UUID
    let kind: PortableAccessKind
    let displayName: String
    let baseURL: String?
    let defaultModel: String?
    let apiProtocol: PortableAPIProtocol?

    init(
        id: UUID,
        kind: PortableAccessKind,
        displayName: String,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        apiProtocol: PortableAPIProtocol? = nil
    ) throws {
        let normalizedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard Self.isSafeText(normalizedName, maximumLength: 80) else {
            throw PortableContinuityError.invalidProfileShape
        }

        switch kind {
        case .official:
            guard baseURL == nil,
                defaultModel == nil,
                apiProtocol == nil
            else {
                throw PortableContinuityError.invalidProfileShape
            }
        case .relay:
            guard let baseURL,
                let defaultModel,
                apiProtocol == .responses,
                Self.isSafeEndpoint(baseURL),
                Self.isSafeText(
                    defaultModel.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    maximumLength: 128
                )
            else {
                if let baseURL, !Self.isSafeEndpoint(baseURL) {
                    throw PortableContinuityError.invalidEndpoint
                }
                throw PortableContinuityError.invalidProfileShape
            }
        }

        self.id = id
        self.kind = kind
        self.displayName = normalizedName
        self.baseURL = baseURL
        self.defaultModel = defaultModel?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.apiProtocol = apiProtocol
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case baseURL = "base_url"
        case defaultModel = "default_model"
        case apiProtocol = "api_protocol"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            kind: values.decode(PortableAccessKind.self, forKey: .kind),
            displayName: values.decode(String.self, forKey: .displayName),
            baseURL: values.decodeIfPresent(String.self, forKey: .baseURL),
            defaultModel: values.decodeIfPresent(
                String.self,
                forKey: .defaultModel
            ),
            apiProtocol: values.decodeIfPresent(
                PortableAPIProtocol.self,
                forKey: .apiProtocol
            )
        )
    }

    private static func isSafeEndpoint(_ value: String) -> Bool {
        guard value.count <= 2_048,
            !containsControlCharacter(value),
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func isSafeText(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && !containsControlCharacter(value)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

struct PortableWorkspaceLabel: Codable, Equatable, Sendable {
    let id: UUID
    let label: String

    init(id: UUID, label: String) throws {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.count <= 40,
            !normalized.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw PortableContinuityError.invalidWorkspaceLabel
        }
        self.id = id
        self.label = normalized
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            label: values.decode(String.self, forKey: .label)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
    }
}

struct PortableContinuitySelection: Codable, Equatable, Sendable {
    var accessProfiles: Bool
    var workspaceLabels: Bool
    var startDestination: Bool
    var historyGrouping: Bool

    static let all = PortableContinuitySelection(
        accessProfiles: true,
        workspaceLabels: true,
        startDestination: true,
        historyGrouping: true
    )

    var hasSelectedField: Bool {
        accessProfiles
            || workspaceLabels
            || startDestination
            || historyGrouping
    }

    private enum CodingKeys: String, CodingKey {
        case accessProfiles = "access_profiles"
        case workspaceLabels = "workspace_labels"
        case startDestination = "start_destination"
        case historyGrouping = "history_grouping"
    }
}

struct PortableContinuityPreferences: Codable, Equatable, Sendable {
    let startDestination: PortableStartDestination?
    let historyGrouping: PortableHistoryGrouping?

    init(
        startDestination: PortableStartDestination?,
        historyGrouping: PortableHistoryGrouping?
    ) {
        self.startDestination = startDestination
        self.historyGrouping = historyGrouping
    }

    private enum CodingKeys: String, CodingKey {
        case startDestination = "start_destination"
        case historyGrouping = "history_grouping"
    }
}

struct PortableContinuityBoundary: Codable, Equatable, Sendable {
    let credentialsIncluded: Bool
    let authFilesIncluded: Bool
    let sessionContentIncluded: Bool
    let workspacePathsIncluded: Bool
    let configurationFilesIncluded: Bool
    let keychainReferencesIncluded: Bool

    static let nonSensitive = PortableContinuityBoundary(
        credentialsIncluded: false,
        authFilesIncluded: false,
        sessionContentIncluded: false,
        workspacePathsIncluded: false,
        configurationFilesIncluded: false,
        keychainReferencesIncluded: false
    )

    private enum CodingKeys: String, CodingKey {
        case credentialsIncluded = "credentials_included"
        case authFilesIncluded = "auth_files_included"
        case sessionContentIncluded = "session_content_included"
        case workspacePathsIncluded = "workspace_paths_included"
        case configurationFilesIncluded = "configuration_files_included"
        case keychainReferencesIncluded = "keychain_references_included"
    }
}

struct PortableContinuityImportPolicy: Codable, Equatable, Sendable {
    let previewRequired: Bool
    let fieldSelectionRequired: Bool
    let credentialReentryRequired: Bool
    let writesAllowed: Bool

    static let previewOnly = PortableContinuityImportPolicy(
        previewRequired: true,
        fieldSelectionRequired: true,
        credentialReentryRequired: true,
        writesAllowed: false
    )

    private enum CodingKeys: String, CodingKey {
        case previewRequired = "preview_required"
        case fieldSelectionRequired = "field_selection_required"
        case credentialReentryRequired = "credential_reentry_required"
        case writesAllowed = "writes_allowed"
    }
}

struct PortableContinuityManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let product: String
    let sourceVersion: String
    let sourceBuild: String
    let platform: PortableSourcePlatform
    let boundary: PortableContinuityBoundary
    let importPolicy: PortableContinuityImportPolicy
    let selection: PortableContinuitySelection
    let accessProfiles: [PortableAccessProfile]
    let workspaceLabels: [PortableWorkspaceLabel]
    let preferences: PortableContinuityPreferences

    init(
        sourceVersion: String,
        sourceBuild: String,
        platform: PortableSourcePlatform,
        selection: PortableContinuitySelection = .all,
        accessProfiles: [PortableAccessProfile],
        workspaceLabels: [PortableWorkspaceLabel],
        preferences: PortableContinuityPreferences
    ) throws {
        try self.init(
            schemaVersion: 1,
            product: "AI接入助手",
            sourceVersion: sourceVersion,
            sourceBuild: sourceBuild,
            platform: platform,
            boundary: .nonSensitive,
            importPolicy: .previewOnly,
            selection: selection,
            accessProfiles: accessProfiles,
            workspaceLabels: workspaceLabels,
            preferences: preferences
        )
    }

    func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(self)
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PortableContinuityError.malformedDocument
        }
        guard let root = value as? [String: Any] else {
            throw PortableContinuityError.malformedDocument
        }

        if containsForbiddenSensitiveKey(value) {
            throw PortableContinuityError.forbiddenSensitiveField
        }
        try validateKnownFields(root)
        guard let schemaVersion = root["schema_version"] as? Int else {
            throw PortableContinuityError.malformedDocument
        }
        guard schemaVersion == 1 else {
            throw PortableContinuityError.unsupportedSchema
        }

        do {
            let manifest = try JSONDecoder().decode(Self.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as PortableContinuityError {
            throw error
        } catch {
            throw PortableContinuityError.malformedDocument
        }
    }

    private init(
        schemaVersion: Int,
        product: String,
        sourceVersion: String,
        sourceBuild: String,
        platform: PortableSourcePlatform,
        boundary: PortableContinuityBoundary,
        importPolicy: PortableContinuityImportPolicy,
        selection: PortableContinuitySelection,
        accessProfiles: [PortableAccessProfile],
        workspaceLabels: [PortableWorkspaceLabel],
        preferences: PortableContinuityPreferences
    ) throws {
        self.schemaVersion = schemaVersion
        self.product = product
        self.sourceVersion = sourceVersion
        self.sourceBuild = sourceBuild
        self.platform = platform
        self.boundary = boundary
        self.importPolicy = importPolicy
        self.selection = selection
        self.accessProfiles = accessProfiles
        self.workspaceLabels = workspaceLabels
        self.preferences = preferences
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case sourceVersion = "source_version"
        case sourceBuild = "source_build"
        case platform
        case boundary
        case importPolicy = "import_policy"
        case selection
        case accessProfiles = "access_profiles"
        case workspaceLabels = "workspace_labels"
        case preferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            product: values.decode(String.self, forKey: .product),
            sourceVersion: values.decode(String.self, forKey: .sourceVersion),
            sourceBuild: values.decode(String.self, forKey: .sourceBuild),
            platform: values.decode(
                PortableSourcePlatform.self,
                forKey: .platform
            ),
            boundary: values.decode(
                PortableContinuityBoundary.self,
                forKey: .boundary
            ),
            importPolicy: values.decode(
                PortableContinuityImportPolicy.self,
                forKey: .importPolicy
            ),
            selection: try values.decodeIfPresent(
                PortableContinuitySelection.self,
                forKey: .selection
            ) ?? .all,
            accessProfiles: values.decode(
                [PortableAccessProfile].self,
                forKey: .accessProfiles
            ),
            workspaceLabels: values.decode(
                [PortableWorkspaceLabel].self,
                forKey: .workspaceLabels
            ),
            preferences: values.decode(
                PortableContinuityPreferences.self,
                forKey: .preferences
            )
        )
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw PortableContinuityError.unsupportedSchema
        }
        guard product == "AI接入助手",
            Self.isValidSourceVersion(sourceVersion),
            Self.isValidSourceBuild(sourceBuild)
        else {
            throw PortableContinuityError.invalidSourceIdentity
        }
        guard boundary == .nonSensitive else {
            throw PortableContinuityError.invalidBoundary
        }
        guard importPolicy == .previewOnly else {
            throw PortableContinuityError.invalidImportPolicy
        }
        guard selection.hasSelectedField,
            selection.accessProfiles || accessProfiles.isEmpty,
            selection.workspaceLabels || workspaceLabels.isEmpty,
            selection.startDestination
                == (preferences.startDestination != nil),
            selection.historyGrouping
                == (preferences.historyGrouping != nil)
        else {
            throw PortableContinuityError.invalidSelection
        }
        guard accessProfiles.count <= 1_000,
            workspaceLabels.count <= 20
        else {
            throw PortableContinuityError.tooManyRecords
        }
        let profileIDs = Set(accessProfiles.map(\.id))
        let workspaceIDs = Set(workspaceLabels.map(\.id))
        guard profileIDs.count == accessProfiles.count,
            workspaceIDs.count == workspaceLabels.count,
            profileIDs.isDisjoint(with: workspaceIDs),
            accessProfiles.filter({ $0.kind == .official }).count <= 1
        else {
            throw PortableContinuityError.duplicateIdentifier
        }
    }

    private static func isValidSourceVersion(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "0123456789.-+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        return !value.isEmpty
            && value.count <= 32
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidSourceBuild(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 12
            && value.allSatisfy(\.isNumber)
    }

    private static func containsForbiddenSensitiveKey(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if forbiddenSensitiveKeys.contains(normalizeKey(key))
                    || containsForbiddenSensitiveKey(child)
                {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsForbiddenSensitiveKey)
        }
        return false
    }

    private static func normalizeKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static let forbiddenSensitiveKeys: Set<String> = [
        "apikey",
        "authorization",
        "password",
        "token",
        "secret",
        "credentialreference",
        "authjson",
        "sessiontext",
        "prompt",
        "responsebody",
        "tooloutput",
        "workspacepath",
        "filepath",
        "configtoml",
        "headers",
        "cookies",
    ]

    private static func validateKnownFields(
        _ root: [String: Any]
    ) throws {
        try requireExactKeys(
            root,
            allowed: [
                "schema_version",
                "product",
                "source_version",
                "source_build",
                "platform",
                "boundary",
                "import_policy",
                "selection",
                "access_profiles",
                "workspace_labels",
                "preferences",
            ]
        )
        try validateObject(
            root["boundary"],
            allowed: [
                "credentials_included",
                "auth_files_included",
                "session_content_included",
                "workspace_paths_included",
                "configuration_files_included",
                "keychain_references_included",
            ]
        )
        try validateObject(
            root["import_policy"],
            allowed: [
                "preview_required",
                "field_selection_required",
                "credential_reentry_required",
                "writes_allowed",
            ]
        )
        if root["selection"] != nil {
            try validateObject(
                root["selection"],
                allowed: [
                    "access_profiles",
                    "workspace_labels",
                    "start_destination",
                    "history_grouping",
                ]
            )
        }
        try validateArrayObjects(
            root["access_profiles"],
            allowed: [
                "id",
                "kind",
                "display_name",
                "base_url",
                "default_model",
                "api_protocol",
            ]
        )
        try validateArrayObjects(
            root["workspace_labels"],
            allowed: ["id", "label"]
        )
        try validateObject(
            root["preferences"],
            allowed: ["start_destination", "history_grouping"]
        )
    }

    private static func validateObject(
        _ value: Any?,
        allowed: Set<String>
    ) throws {
        guard let object = value as? [String: Any] else {
            throw PortableContinuityError.malformedDocument
        }
        try requireExactKeys(object, allowed: allowed)
    }

    private static func validateArrayObjects(
        _ value: Any?,
        allowed: Set<String>
    ) throws {
        guard let array = value as? [Any] else {
            throw PortableContinuityError.malformedDocument
        }
        for value in array {
            guard let object = value as? [String: Any] else {
                throw PortableContinuityError.malformedDocument
            }
            try requireExactKeys(object, allowed: allowed)
        }
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        allowed: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw PortableContinuityError.unknownField
        }
    }
}
