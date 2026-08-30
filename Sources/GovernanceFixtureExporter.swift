import Foundation

enum GovernanceFixtureExportError: LocalizedError, Equatable {
    case authorizationRequired
    case unsafeSource
    case sourceTooLarge
    case unsafeDestination
    case emptyConfiguration

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "必须先确认本次只读所选TOML并导出脱敏结构"
        case .unsafeSource:
            return "源配置必须是普通文件且不能是符号链接"
        case .sourceTooLarge:
            return "源配置超过2 MB安全上限"
        case .unsafeDestination:
            return "脱敏证据不能覆盖源文件或写入源配置目录"
        case .emptyConfiguration:
            return "源配置没有可导出的语义叶子"
        }
    }
}

struct GovernanceLeafShape: Codable, Equatable {
    let pathShape: String
    let valueKind: String
    let providerManaged: Bool
}

struct GovernanceStructuralFixture: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let marker: String
    let generatedAt: Date
    let sourceSHA256: String
    let sourceByteCount: Int
    let semanticSchemaFingerprint: String
    let totalLeafCount: Int
    let nonProviderLeafCount: Int
    let providerCount: Int
    let leaves: [GovernanceLeafShape]
    let secretsIncluded: Bool
}

enum GovernanceFixtureExporter {
    static func export(
        sourceURL: URL,
        destinationURL: URL,
        userAuthorized: Bool,
        now: Date = Date()
    ) throws -> GovernanceStructuralFixture {
        guard userAuthorized else {
            throw GovernanceFixtureExportError.authorizationRequired
        }
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw GovernanceFixtureExportError.unsafeSource
        }
        guard (values.fileSize ?? 0) <= 2_000_000 else {
            throw GovernanceFixtureExportError.sourceTooLarge
        }
        guard source.path != destination.path,
              source.deletingLastPathComponent().path
                != destination.deletingLastPathComponent().path else {
            throw GovernanceFixtureExportError.unsafeDestination
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let document = try TOMLSemanticEngine.parse(
            String(decoding: data, as: UTF8.self)
        )
        guard !document.leaves.isEmpty else {
            throw GovernanceFixtureExportError.emptyConfiguration
        }
        let policy = TOMLChangePolicy(
            managedProviderIDs: Set(document.providerIDs)
        )
        var aliases: [String: String] = [:]
        var nextAlias = 1
        let leaves = document.leaves.keys.sorted().map {
            encodedPath -> GovernanceLeafShape in
            let components = TOMLSemanticEngine.decodePath(encodedPath)
            let sanitized = components.enumerated().map {
                index, component -> String in
                if index == 0 || isStructuralComponent(component) {
                    return component
                }
                if let alias = aliases[component] {
                    return alias
                }
                let alias = String(
                    format: "<id-%03d>",
                    nextAlias
                )
                nextAlias += 1
                aliases[component] = alias
                return alias
            }
            let value = document.leaves[encodedPath] ?? "unknown:"
            return GovernanceLeafShape(
                pathShape: TOMLSemanticEngine.path(sanitized),
                valueKind: valueKind(value),
                providerManaged: policy.allows(path: encodedPath)
            )
        }
        let nonProviderCount =
            OfficialOverlayCandidateFactory.nonProviderLeaves(document)
                .count
        let canonical = leaves.map {
            "\($0.pathShape)|\($0.valueKind)|\($0.providerManaged)"
        }.joined(separator: "\n")
        let fixture = GovernanceStructuralFixture(
            schemaVersion:
                GovernanceStructuralFixture.currentSchemaVersion,
            marker: "AI_ACCESS_ASSISTANT_STRUCTURAL_FIXTURE_V1",
            generatedAt: now,
            sourceSHA256: TOMLSemanticEngine.sha256(data),
            sourceByteCount: data.count,
            semanticSchemaFingerprint:
                TOMLSemanticEngine.sha256(Data(canonical.utf8)),
            totalLeafCount: document.leaves.count,
            nonProviderLeafCount: nonProviderCount,
            providerCount: document.providerIDs.count,
            leaves: leaves,
            secretsIncluded: false
        )
        try write(fixture, to: destination)
        return fixture
    }

    static func decode(_ data: Data) throws
        -> GovernanceStructuralFixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(
            GovernanceStructuralFixture.self,
            from: data
        )
        guard fixture.schemaVersion
            == GovernanceStructuralFixture.currentSchemaVersion,
        fixture.marker
            == "AI_ACCESS_ASSISTANT_STRUCTURAL_FIXTURE_V1",
        !fixture.secretsIncluded else {
            throw GovernanceFixtureExportError.unsafeSource
        }
        return fixture
    }

    private static func write(
        _ fixture: GovernanceStructuralFixture,
        to destination: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(
            to: destination,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func valueKind(_ value: String) -> String {
        if value.hasPrefix("<"), value.hasSuffix(">") {
            return value
        }
        return value.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? "unknown"
    }

    private static func isStructuralComponent(
        _ component: String
    ) -> Bool {
        if component.hasPrefix("["),
           component.hasSuffix("]") {
            return true
        }
        return structuralComponents.contains(component)
    }

    private static let structuralComponents: Set<String> = [
        "name", "enabled", "command", "args", "env", "url",
        "trust_level", "mode", "permissions", "network", "roots",
        "approval_policy", "sandbox_mode", "base_url", "wire_api",
        "env_key", "model", "model_provider",
        "model_reasoning_effort", "model_context_window",
        "model_auto_compact_token_limit", "http_headers",
        "env_http_headers", "query_params", "features",
    ]
}
