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

@MainActor
protocol ConfigWorkspaceSourceAcquisitionControllerDelegate:
    AnyObject {
    var documentTitle: String { get set }
    var documentText: String { get set }
    var documentStatus: String { get set }
    var isRefreshingDocument: Bool { get set }
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
    private weak var delegate:
        (any ConfigWorkspaceSourceAcquisitionControllerDelegate)?

    init(
        delegate:
            any ConfigWorkspaceSourceAcquisitionControllerDelegate
    ) {
        self.delegate = delegate
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

    func acquireModels(
        baseURL: String,
        apiKey: String,
        wireProtocol: RelayWireProtocol,
        confirmedLocalGateway: Bool
    ) {
        Task { [weak self] in
            let outcome: ConfigWorkspaceModelAcquisitionOutcome
            do {
                outcome = .success(
                    try await ModelCatalogService.fetch(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        wireProtocol: wireProtocol,
                        confirmedLocalGateway:
                            confirmedLocalGateway
                    )
                )
            } catch ModelCatalogError.emptyModels {
                outcome = .empty
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            self?.applyModels(outcome)
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
            delegate.evidence.removeAll {
                $0.field == "模型"
                    && $0.source == "中转 /models 接口"
            }
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
        case let .failure(message):
            delegate.modelFetchStatus = "模型拉取失败"
            delegate.errorMessage = message
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
