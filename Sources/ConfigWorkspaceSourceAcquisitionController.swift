// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConfigWorkspaceDocumentAcquisitionOutcome {
    case success(RefreshedDocument)
    case failure(String)
}

enum ConfigWorkspaceModelAcquisitionOutcome {
    case success([RemoteModelRecord])
    case empty
    case failure(String)
}

enum ConfigWorkspaceScreenshotAcquisitionOutcome {
    case success([ConfigurationSourceRecord])
    case failure(String)
}

/// LTP-130: one truth for the draft's directory discovery. Catalog evidence is
/// kept only for the latest completed read, so a later failure, empty result,
/// cancellation, or new in-flight read can never be shown as verified.
enum ConfigWorkspaceModelDirectoryState: Equatable {
    case notRead
    case reading
    case completed
    case cancelled
}

@MainActor
protocol ConfigWorkspaceSourceAcquisitionControllerDelegate:
    AnyObject {
    var documentTitle: String { get set }
    var documentText: String { get set }
    var documentStatus: String { get set }
    var isRefreshingDocument: Bool { get set }
    var baseURL: String { get }
    var apiKey: String { get }
    var wireProtocol: RelayWireProtocol { get }
    var confirmsLocalGateway: Bool { get }
    var modelNames: [String] { get set }
    var modelName: String { get set }
    var modelFetchStatus: String { get set }
    var isFetchingModels: Bool { get set }
    var configurationSources: [ConfigurationSourceRecord] {
        get set
    }
    var evidence: [FieldEvidence] { get set }
    var screenshotStatus: String { get set }
    var isReadingScreenshots: Bool { get set }
    var errorMessage: String? { get set }

    func rebuildUnifiedResult(applyValues: Bool)
    func invalidatePreview()
}

/// Owns asynchronous acquisition from public documentation, user-authorized
/// model endpoints, and local configuration screenshots, including projection
/// into ConfigWorkspaceModel's existing observable state.
@MainActor
final class ConfigWorkspaceSourceAcquisitionController {
    typealias ModelFetcher = (String, String, RelayWireProtocol, Bool) async throws -> [RemoteModelRecord]

    private struct ModelInputs: Equatable {
        let baseURL: String
        let apiKey: String
        let wireProtocol: RelayWireProtocol
        let confirmedLocalGateway: Bool

        @MainActor
        init(_ delegate: any ConfigWorkspaceSourceAcquisitionControllerDelegate) {
            baseURL = delegate.baseURL
            apiKey = delegate.apiKey
            wireProtocol = delegate.wireProtocol
            confirmedLocalGateway = delegate.confirmsLocalGateway
        }
    }

    private weak var delegate:
        (any ConfigWorkspaceSourceAcquisitionControllerDelegate)?
    private let fetchModels: ModelFetcher
    private var modelsTask: Task<Void, Never>?
    private var modelsRequestID: UUID?
    private var directoryState = ConfigWorkspaceModelDirectoryState.notRead

    init(
        delegate:
            any ConfigWorkspaceSourceAcquisitionControllerDelegate,
        fetchModels: @escaping ModelFetcher = { baseURL, apiKey, wireProtocol, confirmed in
            try await ModelCatalogService.fetch(baseURL: baseURL, apiKey: apiKey,
                wireProtocol: wireProtocol, confirmedLocalGateway: confirmed)
        }
    ) {
        self.delegate = delegate
        self.fetchModels = fetchModels
    }

    func acquireDocument(urlString: String) {
        Task { [weak self] in
            let outcome: ConfigWorkspaceDocumentAcquisitionOutcome
            do {
                outcome = .success(
                    try await DocumentRefreshService.fetch(
                        urlString: urlString
                    )
                )
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            self?.applyDocument(outcome)
        }
    }

    func acquireModels() {
        guard let delegate, modelsRequestID == nil else { return }
        let inputs = ModelInputs(delegate)
        let requestID = UUID()
        modelsRequestID = requestID
        delegate.isFetchingModels = true
        delegate.modelFetchStatus = "正在安全读取模型列表"
        delegate.errorMessage = nil
        directoryState = .reading
        let fetch = fetchModels
        modelsTask = Task { [weak self] in
            let outcome: ConfigWorkspaceModelAcquisitionOutcome
            do {
                outcome = .success(
                    try await fetch(inputs.baseURL, inputs.apiKey,
                        inputs.wireProtocol, inputs.confirmedLocalGateway)
                )
            } catch ModelCatalogError.emptyModels {
                outcome = .empty
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            guard let self, self.modelsRequestID == requestID,
                  !Task.isCancelled, let delegate = self.delegate else { return }
            guard inputs == ModelInputs(delegate) else {
                self.modelInputsDidChange()
                return
            }
            self.modelsRequestID = nil
            self.modelsTask = nil
            self.directoryState = .completed
            self.applyModels(outcome)
        }
    }

    func cancelModels() {
        guard modelsRequestID != nil else { return }
        modelsRequestID = nil
        modelsTask?.cancel()
        modelsTask = nil
        directoryState = .cancelled
        delegate?.isFetchingModels = false
        delegate?.modelFetchStatus = "已取消读取模型；草稿保留，可手动重试。"
    }

    /// LTP-130: an explicit manual model carries its own evidence. The model
    /// directory stays a separate discovery, so its outcome must remain
    /// visible as unverified instead of being reported as passed.
    func noteManualModelAdded(_ value: String) {
        guard let delegate else { return }
        let discoveredCount = delegate.evidence.filter {
            $0.field == "模型" && $0.source == "中转 /models 接口"
        }.count
        delegate.modelFetchStatus = Self.manualModelAddedStatus(
            value: value,
            directorySummary: Self.modelDirectorySummary(
                state: directoryState,
                discoveredModelCount: discoveredCount,
                errorMessage: delegate.errorMessage
            )
        )
    }

    /// Derived from the single directory state plus the latest error and the
    /// catalog evidence the latest completed read produced.
    static func modelDirectorySummary(
        state: ConfigWorkspaceModelDirectoryState,
        discoveredModelCount: Int,
        errorMessage: String?
    ) -> String {
        switch state {
        case .reading:
            return "模型目录正在读取；本次结果未出，"
                + "上次结果不再声明为已验证"
        case .cancelled:
            return "模型目录未验证：读取已取消"
        case .notRead:
            return "模型目录未读取（不影响手工模型验证）"
        case .completed:
            break
        }
        if discoveredModelCount > 0 {
            return "模型目录已读取（\(discoveredModelCount) 个）；"
                + "未核对该模型是否在列表内"
        }
        let reason = errorMessage?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard reason.isEmpty else {
            return "模型目录未验证：\(reason)"
        }
        return "模型目录未验证：接口未返回可识别的模型"
    }

    static func manualModelAddedStatus(
        value: String,
        directorySummary: String
    ) -> String {
        "已手动添加模型：\(value)；\(directorySummary)"
    }

    func modelInputsDidChange() {
        guard let delegate else { return }
        let hadEvidence = delegate.evidence.contains {
            $0.field == "模型" && $0.source == "中转 /models 接口"
        }
        guard modelsRequestID != nil
            || directoryState != .notRead || hadEvidence else { return }
        cancelModels()
        directoryState = .notRead
        removeCatalogEvidence(delegate)
        delegate.modelFetchStatus = "接入信息已变化；已有模型仅作草稿，请重新读取或手动确认。"
        delegate.invalidatePreview()
    }

    /// The catalog evidence describes the latest completed read only.
    private func removeCatalogEvidence(
        _ delegate: any ConfigWorkspaceSourceAcquisitionControllerDelegate
    ) {
        delegate.evidence.removeAll {
            $0.field == "模型" && $0.source == "中转 /models 接口"
        }
    }

    func acquireScreenshots(_ urls: [URL]) {
        Task { [weak self] in
            let outcome:
                ConfigWorkspaceScreenshotAcquisitionOutcome
            do {
                outcome = .success(
                    try await ConfigurationSourceEngine
                        .recognizeScreenshots(urls: urls)
                )
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            self?.applyScreenshots(outcome)
        }
    }

    private func applyDocument(
        _ outcome: ConfigWorkspaceDocumentAcquisitionOutcome
    ) {
        guard let delegate else { return }
        switch outcome {
        case let .success(refreshed):
            delegate.documentTitle = refreshed.title
            delegate.documentText = refreshed.text
            delegate.configurationSources.removeAll {
                $0.kind == .remoteDocument
                    && $0.location
                        == refreshed.sourceURL.absoluteString
            }
            delegate.configurationSources.append(
                ConfigurationSourceEngine.sanitizedSource(
                    kind: .remoteDocument,
                    title: refreshed.title,
                    text: refreshed.text,
                    location:
                        refreshed.sourceURL.absoluteString
                )
            )
            delegate.rebuildUnifiedResult(applyValues: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            delegate.documentStatus = refreshed.isSummaryOnly
                ? "只取得摘要 · \(formatter.string(from: refreshed.fetchedAt))"
                : "全文已整理并带入 · \(formatter.string(from: refreshed.fetchedAt))"
        case let .failure(message):
            delegate.documentStatus = "整理失败；保留原填写值"
            delegate.errorMessage = message
        }
        delegate.isRefreshingDocument = false
    }

    private func applyModels(
        _ outcome: ConfigWorkspaceModelAcquisitionOutcome
    ) {
        guard let delegate else { return }
        switch outcome {
        case let .success(records):
            for record in records
                where !delegate.modelNames.contains(record.id) {
                delegate.modelNames.append(record.id)
            }
            if delegate.modelName.isEmpty {
                delegate.modelName =
                    delegate.modelNames.first ?? ""
            }
            delegate.modelFetchStatus =
                "已拉取 \(records.count) 个模型；API Key 未写入日志或网址"
            removeCatalogEvidence(delegate)
            for record in records {
                delegate.evidence.append(
                    FieldEvidence(
                        field: "模型",
                        value: record.id,
                        source: "中转 /models 接口",
                        status: .extracted
                    )
                )
            }
            delegate.invalidatePreview()
        case .empty:
            delegate.modelFetchStatus =
                "接口已响应，但未识别到模型；可手动添加"
            delegate.errorMessage = nil
            removeCatalogEvidence(delegate)
            delegate.invalidatePreview()
        case let .failure(message):
            delegate.modelFetchStatus = "模型拉取失败"
            delegate.errorMessage = message
            removeCatalogEvidence(delegate)
            delegate.invalidatePreview()
        }
        delegate.isFetchingModels = false
    }

    private func applyScreenshots(
        _ outcome: ConfigWorkspaceScreenshotAcquisitionOutcome
    ) {
        guard let delegate else { return }
        switch outcome {
        case let .success(records):
            delegate.configurationSources.removeAll {
                $0.kind == .relayScreenshot
                    || $0.kind == .currentSettingsScreenshot
            }
            delegate.configurationSources.append(
                contentsOf: records
            )
            delegate.screenshotStatus =
                "已识别 \(records.count) 张去重截图"
            delegate.rebuildUnifiedResult(applyValues: true)
        case let .failure(message):
            delegate.screenshotStatus = "截图识别失败"
            delegate.errorMessage = "截图识别失败：\(message)"
        }
        delegate.isReadingScreenshots = false
    }
}
