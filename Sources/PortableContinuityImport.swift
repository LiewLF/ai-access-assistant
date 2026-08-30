// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum PortableContinuityImportError: LocalizedError, Equatable {
    case jsonFileRequired
    case unsafeSource
    case sourceTooLarge
    case unreadableSource
    case invalidManifest(PortableContinuityError)

    var errorDescription: String? {
        switch self {
        case .jsonFileRequired:
            return "请选择扩展名为.json的迁移设置文件"
        case .unsafeSource:
            return "迁移设置必须是本机普通文件，不能是目录或符号链接"
        case .sourceTooLarge:
            return "迁移设置超过1 MB安全上限"
        case .unreadableSource:
            return "无法只读打开迁移设置文件"
        case let .invalidManifest(error):
            return "迁移设置格式不兼容：\(Self.manifestMessage(error))"
        }
    }

    private static func manifestMessage(
        _ error: PortableContinuityError
    ) -> String {
        switch error {
        case .malformedDocument:
            return "JSON不完整或不是有效对象"
        case .unsupportedSchema:
            return "文件版本尚不受支持"
        case .unknownField:
            return "文件包含当前版本不认识的字段"
        case .forbiddenSensitiveField:
            return "文件包含不允许迁移的敏感字段"
        case .invalidSourceIdentity:
            return "产品版本或Build来源无效"
        case .invalidEndpoint:
            return "中转地址不是安全的HTTPS地址"
        case .invalidProfileShape:
            return "接入资料字段组合无效"
        case .invalidWorkspaceLabel:
            return "工作区标签无效"
        case .duplicateIdentifier:
            return "文件包含重复标识"
        case .invalidBoundary:
            return "文件试图包含被固定排除的内容"
        case .invalidImportPolicy:
            return "文件试图绕过预览或启用写入"
        case .invalidSelection:
            return "文件的字段选择与内容不一致"
        case .tooManyRecords:
            return "文件中的记录数量超过安全上限"
        }
    }
}

struct PortableContinuityTargetProfile: Equatable, Sendable {
    let displayName: String
    let baseURL: String
    let defaultModel: String
    let usesResponsesAPI: Bool

    init(
        displayName: String,
        baseURL: String,
        defaultModel: String,
        usesResponsesAPI: Bool = true
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.usesResponsesAPI = usesResponsesAPI
    }
}

struct PortableContinuityTargetState: Equatable, Sendable {
    let relayProfiles: [PortableContinuityTargetProfile]
    let workspaceLabels: [String]
    let startDestination: PortableStartDestination?
    let historyGrouping: PortableHistoryGrouping?
}

enum PortableContinuityImportScope:
    String, Equatable, Sendable {
    case official
    case relay
    case workspace
    case preference

    var displayName: String {
        switch self {
        case .official:
            return "官方接入"
        case .relay:
            return "中转资料"
        case .workspace:
            return "工作区标签"
        case .preference:
            return "使用偏好"
        }
    }
}

enum PortableContinuityImportField:
    String, Equatable, Hashable, Sendable {
    case officialAccess
    case displayName
    case baseURL
    case defaultModel
    case workspaceLabel
    case startDestination
    case historyGrouping

    var displayName: String {
        switch self {
        case .officialAccess:
            return "官方登录"
        case .displayName:
            return "名称"
        case .baseURL:
            return "HTTPS地址"
        case .defaultModel:
            return "默认模型"
        case .workspaceLabel:
            return "工作区标签"
        case .startDestination:
            return "启动页"
        case .historyGrouping:
            return "历史分组"
        }
    }
}

enum PortableContinuityImportDisposition:
    String, Equatable, Sendable {
    case unchanged
    case willAdd
    case conflict
    case requiresTargetMapping
    case unsupported

    var displayName: String {
        switch self {
        case .unchanged:
            return "无需变化"
        case .willAdd:
            return "可新增"
        case .conflict:
            return "需要选择"
        case .requiresTargetMapping:
            return "需要选择工作区"
        case .unsupported:
            return "当前版本不保存"
        }
    }
}

struct PortableContinuityImportChange:
    Identifiable, Equatable, Sendable {
    let recordID: UUID
    let scope: PortableContinuityImportScope
    let recordTitle: String
    let field: PortableContinuityImportField
    let incomingValue: String
    let currentValue: String?
    let disposition: PortableContinuityImportDisposition
    let detail: String

    var id: String {
        "\(recordID.uuidString):\(field.rawValue)"
    }
}

struct PortableContinuityImportPreview: Equatable, Sendable {
    let sourceVersion: String
    let sourceBuild: String
    let sourcePlatform: PortableSourcePlatform
    let selection: PortableContinuitySelection
    let changes: [PortableContinuityImportChange]
    let warnings: [String]
    let writesAllowed: Bool

    var hasBlockingItems: Bool {
        changes.contains {
            switch $0.disposition {
            case .conflict, .requiresTargetMapping, .unsupported:
                return true
            case .unchanged, .willAdd:
                return false
            }
        }
    }

    func count(
        for disposition: PortableContinuityImportDisposition
    ) -> Int {
        changes.count { $0.disposition == disposition }
    }
}

struct PortableContinuityImportDocument: Equatable, Sendable {
    let manifest: PortableContinuityManifest
    let data: Data
}

enum PortableContinuityImportPreflight {
    static func inspect(
        manifest: PortableContinuityManifest,
        target: PortableContinuityTargetState,
        targetVersion: String,
        targetBuild: String,
        targetPlatform: PortableSourcePlatform
    ) -> PortableContinuityImportPreview {
        var changes: [PortableContinuityImportChange] = []
        for profile in manifest.accessProfiles {
            switch profile.kind {
            case .official:
                changes.append(
                    PortableContinuityImportChange(
                        recordID: profile.id,
                        scope: .official,
                        recordTitle: profile.displayName,
                        field: .officialAccess,
                        incomingValue: "使用官方登录",
                        currentValue: "当前设备支持官方登录",
                        disposition: .unchanged,
                        detail: "官方登录不携带认证资料，无需导入凭据。"
                    )
                )
            case .relay:
                changes.append(
                    contentsOf: relayChanges(
                        profile,
                        targets: target.relayProfiles
                    )
                )
            }
        }
        for label in manifest.workspaceLabels {
            let hasSameLabel = target.workspaceLabels.contains {
                normalizedName($0) == normalizedName(label.label)
            }
            changes.append(
                PortableContinuityImportChange(
                    recordID: label.id,
                    scope: .workspace,
                    recordTitle: label.label,
                    field: .workspaceLabel,
                    incomingValue: label.label,
                    currentValue:
                        hasSameLabel ? "已有同名标签" : nil,
                    disposition: .requiresTargetMapping,
                    detail:
                        "文件不含原设备路径；必须在目标设备选择具体工作区后才能绑定。"
                )
            )
        }
        if let value = manifest.preferences.startDestination {
            changes.append(
                preferenceChange(
                    recordID: preferenceStartID,
                    field: .startDestination,
                    incomingValue: value.rawValue,
                    currentValue:
                        target.startDestination?.rawValue
                )
            )
        }
        if let value = manifest.preferences.historyGrouping {
            changes.append(
                preferenceChange(
                    recordID: preferenceHistoryID,
                    field: .historyGrouping,
                    incomingValue: value.rawValue,
                    currentValue:
                        target.historyGrouping?.rawValue
                )
            )
        }

        var warnings: [String] = []
        if sourceIsNewerOrDifferent(
            manifest: manifest,
            targetVersion: targetVersion,
            targetBuild: targetBuild
        ) {
            warnings.append(
                "文件来自 \(manifest.sourceVersion) (\(manifest.sourceBuild))；当前为 \(targetVersion) (\(targetBuild))。预检不会据此自动兼容或写入。"
            )
        }
        if manifest.platform != targetPlatform {
            warnings.append(
                "文件来自 \(manifest.platform.rawValue)，当前为 \(targetPlatform.rawValue)；工作区仍需重新选择。"
            )
        }

        return PortableContinuityImportPreview(
            sourceVersion: manifest.sourceVersion,
            sourceBuild: manifest.sourceBuild,
            sourcePlatform: manifest.platform,
            selection: manifest.selection,
            changes: changes,
            warnings: warnings,
            writesAllowed: false
        )
    }

    private static func relayChanges(
        _ profile: PortableAccessProfile,
        targets: [PortableContinuityTargetProfile]
    ) -> [PortableContinuityImportChange] {
        guard let baseURL = profile.baseURL,
            let defaultModel = profile.defaultModel
        else {
            return []
        }
        let incomingEndpoint = canonicalEndpoint(baseURL)
        let incomingName = normalizedName(profile.displayName)
        let candidates = targets.enumerated().compactMap {
            index, target -> Int? in
            if canonicalEndpoint(target.baseURL) == incomingEndpoint
                || normalizedName(target.displayName) == incomingName
            {
                return index
            }
            return nil
        }
        let uniqueCandidates = Array(Set(candidates)).sorted()
        if uniqueCandidates.count > 1 {
            return relayFieldSet(
                profile: profile,
                current: nil,
                disposition: .conflict,
                detail:
                    "名称和地址分别命中不同的已保存中转；必须由用户选择，预检不会合并。"
            )
        }
        guard let index = uniqueCandidates.first else {
            return relayFieldSet(
                profile: profile,
                current: nil,
                disposition: .willAdd,
                detail:
                    "目标设备没有同名或同地址中转；凭据仍需重新录入。"
            )
        }
        let current = targets[index]
        guard current.usesResponsesAPI else {
            return relayFieldSet(
                profile: profile,
                current: current,
                disposition: .conflict,
                detail:
                    "同名或同地址资料使用不同协议；必须由用户处理，预检不会改写协议。"
            )
        }
        return [
            fieldChange(
                profile: profile,
                field: .displayName,
                incoming: profile.displayName,
                current: current.displayName,
                matches: normalizedName(profile.displayName)
                    == normalizedName(current.displayName)
            ),
            fieldChange(
                profile: profile,
                field: .baseURL,
                incoming: baseURL,
                current: current.baseURL,
                matches: incomingEndpoint
                    == canonicalEndpoint(current.baseURL)
            ),
            fieldChange(
                profile: profile,
                field: .defaultModel,
                incoming: defaultModel,
                current: current.defaultModel,
                matches: defaultModel == current.defaultModel
            ),
        ]
    }

    private static func relayFieldSet(
        profile: PortableAccessProfile,
        current: PortableContinuityTargetProfile?,
        disposition: PortableContinuityImportDisposition,
        detail: String
    ) -> [PortableContinuityImportChange] {
        guard let baseURL = profile.baseURL,
            let defaultModel = profile.defaultModel
        else {
            return []
        }
        return [
            PortableContinuityImportChange(
                recordID: profile.id,
                scope: .relay,
                recordTitle: profile.displayName,
                field: .displayName,
                incomingValue: profile.displayName,
                currentValue: current?.displayName,
                disposition: disposition,
                detail: detail
            ),
            PortableContinuityImportChange(
                recordID: profile.id,
                scope: .relay,
                recordTitle: profile.displayName,
                field: .baseURL,
                incomingValue: baseURL,
                currentValue: current?.baseURL,
                disposition: disposition,
                detail: detail
            ),
            PortableContinuityImportChange(
                recordID: profile.id,
                scope: .relay,
                recordTitle: profile.displayName,
                field: .defaultModel,
                incomingValue: defaultModel,
                currentValue: current?.defaultModel,
                disposition: disposition,
                detail: detail
            ),
        ]
    }

    private static func fieldChange(
        profile: PortableAccessProfile,
        field: PortableContinuityImportField,
        incoming: String,
        current: String,
        matches: Bool
    ) -> PortableContinuityImportChange {
        PortableContinuityImportChange(
            recordID: profile.id,
            scope: .relay,
            recordTitle: profile.displayName,
            field: field,
            incomingValue: incoming,
            currentValue: current,
            disposition: matches ? .unchanged : .conflict,
            detail: matches
                ? "文件与当前保存值一致。"
                : "文件与当前保存值不同；必须由用户选择，预检不会覆盖。"
        )
    }

    private static func preferenceChange(
        recordID: UUID,
        field: PortableContinuityImportField,
        incomingValue: String,
        currentValue: String?
    ) -> PortableContinuityImportChange {
        let disposition: PortableContinuityImportDisposition
        let detail: String
        if let currentValue {
            disposition = currentValue == incomingValue
                ? .unchanged : .conflict
            detail = disposition == .unchanged
                ? "文件与当前保存值一致。"
                : "文件与当前保存值不同；必须由用户选择。"
        } else {
            disposition = .unsupported
            detail =
                "当前版本没有单独保存这项个人偏好，不能把产品默认值冒充为用户设置。"
        }
        return PortableContinuityImportChange(
            recordID: recordID,
            scope: .preference,
            recordTitle: field.displayName,
            field: field,
            incomingValue: incomingValue,
            currentValue: currentValue,
            disposition: disposition,
            detail: detail
        )
    }

    private static func canonicalEndpoint(_ value: String) -> String {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme,
            let host = components.host
        else {
            return value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sourceIsNewerOrDifferent(
        manifest: PortableContinuityManifest,
        targetVersion: String,
        targetBuild: String
    ) -> Bool {
        if manifest.sourceVersion != targetVersion {
            return true
        }
        guard let sourceBuild = Int(manifest.sourceBuild),
            let currentBuild = Int(targetBuild)
        else {
            return true
        }
        return sourceBuild > currentBuild
    }

    private static let preferenceStartID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!
    private static let preferenceHistoryID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    )!
}

enum PortableContinuityImportFileReader {
    static let maximumByteCount = 1_048_576

    static func read(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PortableContinuityManifest {
        try document(
            from: sourceURL,
            fileManager: fileManager
        ).manifest
    }

    static func document(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PortableContinuityImportDocument {
        let data = try data(
            from: sourceURL,
            fileManager: fileManager
        )
        do {
            return PortableContinuityImportDocument(
                manifest: try PortableContinuityManifest
                    .decodeStrict(data),
                data: data
            )
        } catch let error as PortableContinuityError {
            throw PortableContinuityImportError.invalidManifest(error)
        } catch {
            throw PortableContinuityImportError.unreadableSource
        }
    }

    static func data(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard sourceURL.isFileURL else {
            throw PortableContinuityImportError.unsafeSource
        }
        let source = sourceURL.standardizedFileURL
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(
                atPath: source.path
            )
        } catch {
            throw PortableContinuityImportError.unreadableSource
        }
        guard attributes[.type] as? FileAttributeType
            == .typeRegular else {
            throw PortableContinuityImportError.unsafeSource
        }
        guard source.pathExtension.lowercased() == "json" else {
            throw PortableContinuityImportError.jsonFileRequired
        }
        guard let byteCount = attributes[.size] as? NSNumber else {
            throw PortableContinuityImportError.unsafeSource
        }
        guard byteCount.intValue <= maximumByteCount else {
            throw PortableContinuityImportError.sourceTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw PortableContinuityImportError.unreadableSource
        }
        guard data.count <= maximumByteCount else {
            throw PortableContinuityImportError.sourceTooLarge
        }
        return data
    }
}
