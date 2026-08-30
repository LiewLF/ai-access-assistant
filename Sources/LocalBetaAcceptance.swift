// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LocalBetaAcceptanceJourney:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case firstUse = "first_use"
    case officialAccess = "official_access"
    case relayAccess = "relay_access"
    case modeSwitch = "mode_switch"
    case recovery = "recovery"
    case capabilityCompatibility = "capability_compatibility"
    case continuity = "continuity"
    case sessionHistory = "session_history"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .firstUse:
            return "首次使用"
        case .officialAccess:
            return "官方接入"
        case .relayAccess:
            return "中转接入"
        case .modeSwitch:
            return "模式切换"
        case .recovery:
            return "失败恢复"
        case .capabilityCompatibility:
            return "扩展能力"
        case .continuity:
            return "迁移设置"
        case .sessionHistory:
            return "历史会话"
        }
    }
}

enum LocalBetaAcceptanceOutcome:
    String, Codable, CaseIterable, Sendable {
    case passed
    case needsAttention = "needs_attention"

    var displayName: String {
        switch self {
        case .passed:
            return "可正常使用"
        case .needsAttention:
            return "遇到问题"
        }
    }

    var symbolName: String {
        switch self {
        case .passed:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum LocalBetaCrashSignal:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case notReported = "not_reported"
    case notObserved = "not_observed"
    case userObserved = "user_observed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notReported:
            return "未说明"
        case .notObserved:
            return "未发生异常退出"
        case .userObserved:
            return "发生过异常退出"
        }
    }
}

enum LocalBetaFailureStage:
    String, Codable, CaseIterable, Sendable {
    case none
    case firstUse = "first_use"
    case officialUsage = "official_usage"
    case connection
    case realTask = "real_task"
    case modeSwitch = "mode_switch"
    case recovery
    case capabilityCompatibility = "capability_compatibility"
    case continuity
    case sessionHistory = "session_history"
    case unknown

    var displayName: String {
        switch self {
        case .none:
            return "无失败"
        case .firstUse:
            return "首次使用"
        case .officialUsage:
            return "官方额度"
        case .connection:
            return "基础连接"
        case .realTask:
            return "真实任务"
        case .modeSwitch:
            return "模式切换"
        case .recovery:
            return "失败恢复"
        case .capabilityCompatibility:
            return "扩展能力"
        case .continuity:
            return "迁移设置"
        case .sessionHistory:
            return "历史会话"
        case .unknown:
            return "尚未归类"
        }
    }

    static func fallback(
        for journey: LocalBetaAcceptanceJourney
    ) -> LocalBetaFailureStage {
        switch journey {
        case .firstUse:
            return .firstUse
        case .officialAccess:
            return .officialUsage
        case .relayAccess:
            return .connection
        case .modeSwitch:
            return .modeSwitch
        case .recovery:
            return .recovery
        case .capabilityCompatibility:
            return .capabilityCompatibility
        case .continuity:
            return .continuity
        case .sessionHistory:
            return .sessionHistory
        }
    }
}

enum LocalBetaRecoveryResult:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case notReported = "not_reported"
    case notAttempted = "not_attempted"
    case succeeded
    case failed
    case pending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notReported:
            return "未说明"
        case .notAttempted:
            return "没有尝试恢复"
        case .succeeded:
            return "恢复后可用"
        case .failed:
            return "恢复后仍有问题"
        case .pending:
            return "仍在等待恢复"
        }
    }
}

enum LocalBetaPerformanceBoundary:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case notReported = "not_reported"
    case userObservedWithinExpected =
        "user_observed_within_expected"
    case userObservedDegraded = "user_observed_degraded"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notReported:
            return "未说明"
        case .userObservedWithinExpected:
            return "没有明显卡顿"
        case .userObservedDegraded:
            return "明显卡顿或超时"
        }
    }
}

struct LocalBetaStructuredSignals:
    Codable, Equatable, Sendable {
    let crash: LocalBetaCrashSignal
    let failureStage: LocalBetaFailureStage
    let recoveryResult: LocalBetaRecoveryResult
    let performanceBoundary: LocalBetaPerformanceBoundary

    static let notReported = LocalBetaStructuredSignals(
        crash: .notReported,
        failureStage: .none,
        recoveryResult: .notReported,
        performanceBoundary: .notReported
    )

    func resolved(
        journey: LocalBetaAcceptanceJourney,
        outcome: LocalBetaAcceptanceOutcome,
        detectedFailureStage: LocalBetaFailureStage
    ) -> LocalBetaStructuredSignals {
        let stage: LocalBetaFailureStage
        switch outcome {
        case .passed:
            stage = .none
        case .needsAttention:
            if detectedFailureStage != .none {
                stage = detectedFailureStage
            } else if failureStage != .none {
                stage = failureStage
            } else {
                stage = .fallback(for: journey)
            }
        }
        return LocalBetaStructuredSignals(
            crash: crash,
            failureStage: stage,
            recoveryResult: recoveryResult,
            performanceBoundary: performanceBoundary
        )
    }

    var displaySummary: String {
        "阶段：\(failureStage.displayName) · "
            + "异常退出：\(crash.displayName) · "
            + "恢复：\(recoveryResult.displayName) · "
            + "性能：\(performanceBoundary.displayName)"
    }

    enum CodingKeys: String, CodingKey {
        case crash
        case failureStage = "failure_stage"
        case recoveryResult = "recovery_result"
        case performanceBoundary = "performance_boundary"
    }
}

enum LocalBetaAcceptanceRecordOrigin:
    String, Codable, Sendable {
    case userAction = "user_action"
}

struct LocalBetaAcceptanceRecord:
    Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let productVersion: String
    let productBuild: String
    let journey: LocalBetaAcceptanceJourney
    let outcome: LocalBetaAcceptanceOutcome
    let origin: LocalBetaAcceptanceRecordOrigin
    let signals: LocalBetaStructuredSignals

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAt = "recorded_at"
        case productVersion = "product_version"
        case productBuild = "product_build"
        case journey
        case outcome
        case origin
        case signals
    }
}

struct LocalBetaAcceptanceDocument:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let participationEnabled: Bool
    let records: [LocalBetaAcceptanceRecord]

    static var disabled: LocalBetaAcceptanceDocument {
        LocalBetaAcceptanceDocument(
            schemaVersion: currentSchemaVersion,
            participationEnabled: false,
            records: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case participationEnabled = "participation_enabled"
        case records
    }
}

private struct LocalBetaAcceptanceRecordV1:
    Codable, Sendable {
    let id: UUID
    let recordedAt: Date
    let productVersion: String
    let productBuild: String
    let journey: LocalBetaAcceptanceJourney
    let outcome: LocalBetaAcceptanceOutcome
    let origin: LocalBetaAcceptanceRecordOrigin

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAt = "recorded_at"
        case productVersion = "product_version"
        case productBuild = "product_build"
        case journey
        case outcome
        case origin
    }

    var migrated: LocalBetaAcceptanceRecord {
        LocalBetaAcceptanceRecord(
            id: id,
            recordedAt: recordedAt,
            productVersion: productVersion,
            productBuild: productBuild,
            journey: journey,
            outcome: outcome,
            origin: origin,
            signals: .notReported
        )
    }
}

private struct LocalBetaAcceptanceDocumentV1:
    Codable, Sendable {
    let schemaVersion: Int
    let participationEnabled: Bool
    let records: [LocalBetaAcceptanceRecordV1]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case participationEnabled = "participation_enabled"
        case records
    }

    var migrated: LocalBetaAcceptanceDocument {
        LocalBetaAcceptanceDocument(
            schemaVersion:
                LocalBetaAcceptanceDocument.currentSchemaVersion,
            participationEnabled: participationEnabled,
            records: records.map(\.migrated)
        )
    }
}

enum LocalBetaAcceptanceStoreError:
    Error, LocalizedError {
    case unsafePath
    case invalidDocument
    case participationRequired
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "本机Beta记录位置不安全；未读取或改写。"
        case .invalidDocument:
            return "本机Beta记录格式无效；未覆盖原文件。"
        case .participationRequired:
            return "请先明确开启本机Beta验收，再手动记录。"
        case .writeFailed:
            return "本机Beta记录写入失败；请检查磁盘与目录权限。"
        }
    }
}

struct LocalBetaAcceptanceStore {
    static let maximumDocumentBytes = 256 * 1024
    static let maximumRecords = 200

    private static let rootKeys: Set<String> = [
        "schema_version",
        "participation_enabled",
        "records",
    ]
    private static let recordV1Keys: Set<String> = [
        "id",
        "recorded_at",
        "product_version",
        "product_build",
        "journey",
        "outcome",
        "origin",
    ]
    private static let recordV2Keys = recordV1Keys.union([
        "signals",
    ])
    private static let signalKeys: Set<String> = [
        "crash",
        "failure_stage",
        "recovery_result",
        "performance_boundary",
    ]

    let rootURL: URL
    let documentURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL,
        fileManager: FileManager = .default
    ) {
        let normalized = URL(
            fileURLWithPath: rootURL.standardizedFileURL.path,
            isDirectory: true
        ).standardizedFileURL
        self.rootURL = normalized
        documentURL = normalized.appendingPathComponent(
            "acceptance.json",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    static func production(
        fileManager: FileManager = .default
    ) -> LocalBetaAcceptanceStore {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return LocalBetaAcceptanceStore(
            rootURL: applicationSupport
                .appendingPathComponent(
                    "AI接入助手",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "BetaAcceptance",
                    isDirectory: true
                ),
            fileManager: fileManager
        )
    }

    func load() throws -> LocalBetaAcceptanceDocument {
        guard entryExists(rootURL) else {
            return .disabled
        }
        try requireSafeRoot()
        guard entryExists(documentURL) else {
            return .disabled
        }
        try requireRegularDocument()

        let attributes = try fileManager.attributesOfItem(
            atPath: documentURL.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumDocumentBytes else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        let data = try Data(
            contentsOf: documentURL,
            options: .mappedIfSafe
        )
        let schemaVersion = try validateJSONShape(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: LocalBetaAcceptanceDocument?
        switch schemaVersion {
        case 1:
            document = try? decoder.decode(
                LocalBetaAcceptanceDocumentV1.self,
                from: data
            ).migrated
        case LocalBetaAcceptanceDocument.currentSchemaVersion:
            document = try? decoder.decode(
                LocalBetaAcceptanceDocument.self,
                from: data
            )
        default:
            document = nil
        }
        guard let document, isValid(document) else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        return document
    }

    @discardableResult
    func enableParticipation() throws
        -> LocalBetaAcceptanceDocument {
        let existing = try load()
        if existing.participationEnabled {
            return existing
        }
        return try save(
            LocalBetaAcceptanceDocument(
                schemaVersion:
                    LocalBetaAcceptanceDocument.currentSchemaVersion,
                participationEnabled: true,
                records: []
            )
        )
    }

    @discardableResult
    func append(
        journey: LocalBetaAcceptanceJourney,
        outcome: LocalBetaAcceptanceOutcome,
        productVersion: String,
        productBuild: String,
        signals: LocalBetaStructuredSignals = .notReported,
        recordedAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> LocalBetaAcceptanceDocument {
        let existing = try load()
        guard existing.participationEnabled else {
            throw LocalBetaAcceptanceStoreError.participationRequired
        }
        guard !existing.records.contains(where: { $0.id == id }) else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        let persistedRecordedAt = Date(
            timeIntervalSince1970:
                recordedAt.timeIntervalSince1970.rounded(.down)
        )
        let record = LocalBetaAcceptanceRecord(
            id: id,
            recordedAt: persistedRecordedAt,
            productVersion: productVersion,
            productBuild: productBuild,
            journey: journey,
            outcome: outcome,
            origin: .userAction,
            signals: signals
        )
        var records = existing.records + [record]
        records.sort {
            if $0.recordedAt == $1.recordedAt {
                return $0.id.uuidString > $1.id.uuidString
            }
            return $0.recordedAt > $1.recordedAt
        }
        records = Array(records.prefix(Self.maximumRecords))
        return try save(
            LocalBetaAcceptanceDocument(
                schemaVersion:
                    LocalBetaAcceptanceDocument.currentSchemaVersion,
                participationEnabled: true,
                records: records
            )
        )
    }

    @discardableResult
    func deleteAllRecords() throws
        -> LocalBetaAcceptanceDocument {
        let existing = try load()
        guard existing.participationEnabled else {
            throw LocalBetaAcceptanceStoreError.participationRequired
        }
        guard !existing.records.isEmpty else { return existing }
        return try save(
            LocalBetaAcceptanceDocument(
                schemaVersion:
                    LocalBetaAcceptanceDocument.currentSchemaVersion,
                participationEnabled: true,
                records: []
            )
        )
    }

    func disableParticipationAndDelete() throws {
        guard entryExists(rootURL) else { return }
        try requireSafeRoot()
        if entryExists(documentURL) {
            try requireRegularDocument()
            try fileManager.removeItem(at: documentURL)
        }
        let remaining = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        if remaining.isEmpty {
            try fileManager.removeItem(at: rootURL)
        }
    }

    private func save(
        _ document: LocalBetaAcceptanceDocument
    ) throws -> LocalBetaAcceptanceDocument {
        guard isValid(document), document.participationEnabled else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        try prepareRootForWrite()
        if entryExists(documentURL) {
            try requireRegularDocument()
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document),
              !data.isEmpty,
              data.count <= Self.maximumDocumentBytes else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        do {
            try data.write(to: documentURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: documentURL.path
            )
            let reread = try load()
            guard reread == document else {
                throw LocalBetaAcceptanceStoreError.invalidDocument
            }
            return reread
        } catch let error as LocalBetaAcceptanceStoreError {
            throw error
        } catch {
            throw LocalBetaAcceptanceStoreError.writeFailed
        }
    }

    private func prepareRootForWrite() throws {
        if entryExists(rootURL) {
            try requireSafeRoot()
        } else {
            do {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw LocalBetaAcceptanceStoreError.writeFailed
            }
            try requireSafeRoot()
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
        } catch {
            throw LocalBetaAcceptanceStoreError.writeFailed
        }
    }

    private func requireSafeRoot() throws {
        guard let values = try? rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true,
        values.isSymbolicLink != true else {
            throw LocalBetaAcceptanceStoreError.unsafePath
        }
    }

    private func requireRegularDocument() throws {
        guard documentURL.deletingLastPathComponent().standardizedFileURL
                == rootURL,
              let values = try? documentURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ), values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LocalBetaAcceptanceStoreError.unsafePath
        }
    }

    private func entryExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    }

    private func validateJSONShape(_ data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == Self.rootKeys,
              let schemaVersion = root["schema_version"] as? Int,
              schemaVersion == 1
                || schemaVersion
                    == LocalBetaAcceptanceDocument.currentSchemaVersion,
              let records = root["records"] as? [Any] else {
            throw LocalBetaAcceptanceStoreError.invalidDocument
        }
        for value in records {
            guard let record = value as? [String: Any] else {
                throw LocalBetaAcceptanceStoreError.invalidDocument
            }
            if schemaVersion == 1 {
                guard Set(record.keys) == Self.recordV1Keys else {
                    throw LocalBetaAcceptanceStoreError.invalidDocument
                }
                continue
            }
            guard Set(record.keys) == Self.recordV2Keys,
                  let signals = record["signals"]
                    as? [String: Any],
                  Set(signals.keys) == Self.signalKeys else {
                throw LocalBetaAcceptanceStoreError.invalidDocument
            }
        }
        return schemaVersion
    }

    private func isValid(
        _ document: LocalBetaAcceptanceDocument
    ) -> Bool {
        guard document.schemaVersion
                == LocalBetaAcceptanceDocument.currentSchemaVersion,
              document.participationEnabled,
              document.records.count <= Self.maximumRecords,
              Set(document.records.map(\.id)).count
                == document.records.count else {
            return false
        }
        return document.records.allSatisfy { record in
            record.origin == .userAction
                && isSafeVersion(record.productVersion)
                && isSafeBuild(record.productBuild)
        }
    }

    private func isSafeVersion(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#,
            options: .regularExpression
        ) != nil
    }

    private func isSafeBuild(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]{1,7}$"#,
            options: .regularExpression
        ) != nil
    }
}

@MainActor
final class LocalBetaAcceptanceModel: ObservableObject {
    @Published private(set) var document:
        LocalBetaAcceptanceDocument = .disabled
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let store: LocalBetaAcceptanceStore

    init(
        store: LocalBetaAcceptanceStore = .production()
    ) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            document = try store.load()
            statusMessage = nil
            statusIsError = false
        } catch let error as LocalBetaAcceptanceStoreError {
            document = .disabled
            statusMessage = error.localizedDescription
            statusIsError = true
        } catch {
            document = .disabled
            statusMessage = LocalBetaAcceptanceStoreError
                .invalidDocument.localizedDescription
            statusIsError = true
        }
    }

    func enableParticipation() {
        perform(success: "已开启；仍只在你点击记录时写入本机。") {
            try store.enableParticipation()
        }
    }

    func record(
        journey: LocalBetaAcceptanceJourney,
        outcome: LocalBetaAcceptanceOutcome,
        signals: LocalBetaStructuredSignals,
        detectedFailureStage: LocalBetaFailureStage
    ) {
        let resolvedSignals = signals.resolved(
            journey: journey,
            outcome: outcome,
            detectedFailureStage: detectedFailureStage
        )
        perform(success: "已记录结构化结果；没有保存内容正文。") {
            try store.append(
                journey: journey,
                outcome: outcome,
                productVersion: AppReleaseMetadata.version,
                productBuild: AppReleaseMetadata.build,
                signals: resolvedSignals
            )
        }
    }

    func deleteAllRecords() {
        perform(success: "已删除全部本机Beta记录；参与状态保持开启。") {
            try store.deleteAllRecords()
        }
    }

    func disableParticipationAndDelete() {
        do {
            try store.disableParticipationAndDelete()
            document = .disabled
            statusMessage = "已停止参与并删除全部本机Beta记录。"
            statusIsError = false
        } catch let error as LocalBetaAcceptanceStoreError {
            statusMessage = error.localizedDescription
            statusIsError = true
        } catch {
            statusMessage = LocalBetaAcceptanceStoreError
                .writeFailed.localizedDescription
            statusIsError = true
        }
    }

    private func perform(
        success: String,
        operation: () throws -> LocalBetaAcceptanceDocument
    ) {
        do {
            document = try operation()
            statusMessage = success
            statusIsError = false
        } catch let error as LocalBetaAcceptanceStoreError {
            statusMessage = error.localizedDescription
            statusIsError = true
        } catch {
            statusMessage = LocalBetaAcceptanceStoreError
                .writeFailed.localizedDescription
            statusIsError = true
        }
    }
}

struct LocalBetaAcceptanceCenterView: View {
    @StateObject private var model = LocalBetaAcceptanceModel()
    @State private var selectedJourney:
        LocalBetaAcceptanceJourney = .firstUse
    @State private var selectedCrash:
        LocalBetaCrashSignal = .notReported
    @State private var selectedRecovery:
        LocalBetaRecoveryResult = .notReported
    @State private var selectedPerformance:
        LocalBetaPerformanceBoundary = .notReported
    @State private var issueExportStatus: String?
    @State private var confirmsRecordDeletion = false
    @State private var confirmsDisable = false

    let detectedFailureStage: LocalBetaFailureStage

    init(
        detectedFailureStage: LocalBetaFailureStage = .none
    ) {
        self.detectedFailureStage = detectedFailureStage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本机 Beta 验收", systemImage: "checklist")
                .font(.headline)
            Text(
                "默认不参与。只有你开启并点击记录时才写入；不会后台收集或上传。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(
                "只保存时间、版本、场景和固定结果代码；不保存提示词、响应正文、工具内容、密钥、地址或路径。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.document.participationEnabled {
                Picker("本次场景", selection: $selectedJourney) {
                    ForEach(LocalBetaAcceptanceJourney.allCases) { journey in
                        Text(journey.displayName).tag(journey)
                    }
                }
                .pickerStyle(.menu)

                DisclosureGroup("补充问题线索（可选）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "失败阶段来自当前脱敏状态；没有可用状态时按本次场景归类。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Picker("异常退出", selection: $selectedCrash) {
                            ForEach(LocalBetaCrashSignal.allCases) { signal in
                                Text(signal.displayName).tag(signal)
                            }
                        }
                        Picker("恢复结果", selection: $selectedRecovery) {
                            ForEach(LocalBetaRecoveryResult.allCases) { result in
                                Text(result.displayName).tag(result)
                            }
                        }
                        Picker("性能体验", selection: $selectedPerformance) {
                            ForEach(
                                LocalBetaPerformanceBoundary.allCases
                            ) { boundary in
                                Text(boundary.displayName).tag(boundary)
                            }
                        }
                        Text(
                            "性能项只表示你的观察，不冒充安装态 p95 测量。未选择时保持未说明。"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Button("记录本次可用") {
                        model.record(
                            journey: selectedJourney,
                            outcome: .passed,
                            signals: selectedSignals,
                            detectedFailureStage:
                                detectedFailureStage
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    Button("记录遇到问题") {
                        model.record(
                            journey: selectedJourney,
                            outcome: .needsAttention,
                            signals: selectedSignals,
                            detectedFailureStage:
                                detectedFailureStage
                        )
                    }
                }

                Text("本机记录：\(model.document.records.count) 条，最多保留 200 条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "遇到问题的记录可逐条导出；只在你选择文件后写入，不会自动上传或打开。"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                ForEach(model.document.records.prefix(5)) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(
                                    record.outcome.displayName,
                                    systemImage: record.outcome.symbolName
                                )
                                .font(.caption.weight(.semibold))
                                Text(record.journey.displayName)
                                    .font(.caption)
                                Spacer()
                                Text(
                                    record.recordedAt,
                                    format: .dateTime
                                        .year().month().day()
                                        .hour().minute()
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Text(record.signals.displaySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)

                        if record.outcome == .needsAttention {
                            Button("导出这个问题") {
                                exportIssue(record)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint(
                                "只导出这条记录的固定代码和固定复现步骤"
                            )
                        }
                    }
                }

                if let issueExportStatus {
                    Text(issueExportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(issueExportStatus)
                }

                HStack {
                    Button("删除全部记录", role: .destructive) {
                        confirmsRecordDeletion = true
                    }
                    .confirmationDialog(
                        "删除全部本机Beta记录？",
                        isPresented: $confirmsRecordDeletion
                    ) {
                        Button("确认删除全部记录", role: .destructive) {
                            model.deleteAllRecords()
                        }
                    } message: {
                        Text("参与状态继续开启；以后仍只在你点击记录时写入。")
                    }

                    Button("停止参与并删除全部记录", role: .destructive) {
                        confirmsDisable = true
                    }
                    .confirmationDialog(
                        "停止参与并删除全部记录？",
                        isPresented: $confirmsDisable
                    ) {
                        Button("确认停止并删除", role: .destructive) {
                            model.disableParticipationAndDelete()
                        }
                    } message: {
                        Text("删除后不保留参与状态或验收记录。")
                    }
                }
            } else {
                Button("参与本机 Beta 验收") {
                    model.enableParticipation()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(
                    "只开启本机记录能力；不会立即生成记录或联网"
                )
            }

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(
                        model.statusIsError ? Color.red : Color.secondary
                    )
                    .accessibilityLabel(statusMessage)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor)
                .opacity(0.7)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
        )
        .onAppear { model.reload() }
    }

    private var selectedSignals: LocalBetaStructuredSignals {
        LocalBetaStructuredSignals(
            crash: selectedCrash,
            failureStage: .none,
            recoveryResult: selectedRecovery,
            performanceBoundary: selectedPerformance
        )
    }

    private func exportIssue(
        _ record: LocalBetaAcceptanceRecord
    ) {
        let document: LocalBetaIssueExportDocument
        do {
            document = try LocalBetaIssueExportBuilder.make(
                record: record
            )
        } catch {
            issueExportStatus =
                "这条记录不能导出；本机记录和其他文件未改动。"
            return
        }

        let panel = NSSavePanel()
        panel.title = "保存单个Beta问题"
        panel.nameFieldStringValue =
            "AI接入助手-Beta问题-\(record.journey.displayName)-Build\(record.productBuild).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK,
              let destinationURL = panel.url else {
            issueExportStatus = "已取消问题导出；未写入文件。"
            return
        }
        do {
            try LocalBetaIssueAtomicExporter.write(
                document,
                to: destinationURL,
                userConfirmed: true
            )
            issueExportStatus =
                "已导出这个问题的脱敏证据和固定复现步骤；未联网、未上传。"
        } catch {
            issueExportStatus =
                "问题导出失败；目标位置未留下半成品。"
        }
    }
}
