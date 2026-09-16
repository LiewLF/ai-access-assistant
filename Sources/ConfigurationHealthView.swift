// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

private struct Build65CatalogResolutionPresentation {
    let action: Build65WarningAction
    let dialog: Build65ManagedCatalogDialog
    let item: ConfigurationHealthItem
    let semanticHash: String?
    let context: Build65CatalogResolutionContext
    let inspection: Build65CatalogInspection

    var dismissalFingerprint: Build65CatalogDismissalFingerprint {
        Build65CatalogDismissalFingerprint(
            profileID: context.profileID,
            providerID: context.providerID,
            catalogPathIdentity: inspection.catalogPathIdentity,
            catalogPayloadHash: inspection.payloadSHA256,
            contractID: context.codexContractID
                ?? inspection.codexContractID,
            schemaVersion: inspection.schemaVersion,
            selectedModelID: context.selectedModelID,
            configurationSemanticHash: semanticHash
        )
    }

    var copyRequest: Build65CatalogCopyRequest? {
        guard let path = context.catalogPath,
              let profileID = context.profileID,
              let providerID = context.providerID,
              let contractID = context.codexContractID,
              !inspection.managed,
              inspection.catalogPathPresent,
              inspection.failureCode == .catalogExternalUnverified
                || inspection.failureCode == .catalogModelMissing else {
            return nil
        }
        return Build65CatalogCopyRequest(
            sourceURL: URL(fileURLWithPath: path),
            payloadSHA256: inspection.payloadSHA256,
            profileID: profileID,
            providerID: providerID,
            codexContractID: contractID,
            selectedModelID: context.selectedModelID
        )
    }
}

/// 通俗处理窗口：回答“这是什么、是否影响现在、为什么提示、推荐动作、
/// 会改什么、如何退出”，只派发既有只读/受管动作。
private struct Build65CatalogResolutionSheet: View {
    let content: Build65CatalogResolutionPresentation
    let onRecheck: () -> Void
    let onCopyAsManaged: (Build65CatalogCopyRequest) -> Void
    let onKeepCurrent: () -> Void
    let onClose: () -> Void

    @State private var showingTechnicalDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(content.dialog.title)
                .font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                Text("这是什么")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(content.dialog.whatIsThis)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("是否影响现在")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(content.dialog.affectsNow)
                    .font(.callout)
                    .foregroundStyle(
                        content.action.impact == .currentOperation
                            || content.action.impact == .currentRuntime
                            ? .orange : .primary
                    )
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("为什么提示")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(content.dialog.whyPrompted)
                    .font(.callout)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("会改什么")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(content.dialog.whatChanges)
                    .font(.callout)
                Text("如何退出")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(content.dialog.howToExit)
                    .font(.callout)
            }
            HStack(spacing: 10) {
                Button(content.dialog.recommendedActionTitle) {
                    switch content.dialog.recommendedAction {
                    case .recheck:
                        onRecheck()
                    case .copyAsManaged:
                        if let request = content.copyRequest {
                            onCopyAsManaged(request)
                        } else {
                            onClose()
                        }
                    case .exportDiagnostic:
                        showingTechnicalDetail = true
                    case .keepCurrent:
                        onKeepCurrent()
                    default:
                        showingTechnicalDetail = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("build65.catalog-primary")
                if content.action.dismissable {
                    Button(
                        Build65CatalogControlLabel.keepCurrent.rawValue
                    ) {
                        onKeepCurrent()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        "继续使用当前配置，不改变 Provider 或模型"
                    )
                    .accessibilityIdentifier(
                        "build65.catalog-keep-current"
                    )
                }
                Button(
                    Build65CatalogControlLabel.technicalDetail.rawValue
                ) {
                    showingTechnicalDetail.toggle()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    "build65.catalog-technical"
                )
                Button(
                    Build65CatalogControlLabel.cancel.rawValue,
                    role: .cancel
                ) {
                    onClose()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(
                    "build65.catalog-cancel"
                )
            }
            if showingTechnicalDetail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("技术详情")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(content.item.detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let code = content.dialog.failureCode {
                        Text("问题码：\(code)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ConfigurationHealthView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    let refreshAction: () -> Void
    let onOpenExtensions: (() -> Void)?
    let onCopyAsManaged: ((Build65CatalogCopyRequest) -> Void)?
    let onOpenGuide: (() -> Void)?
    let onOpenRecovery: (() -> Void)?

    @State private var catalogResolutionPresented = false
    @State private var catalogResolutionContent:
        Build65CatalogResolutionPresentation?
    @State private var catalogDismissalError: String?
    @State private var catalogWarningLifecycle:
        B68WarningLifecycleSnapshot?

    init(
        model: ConfigWorkspaceModel,
        refreshAction: @escaping () -> Void,
        onOpenExtensions: (() -> Void)? = nil,
        onCopyAsManaged: ((Build65CatalogCopyRequest) -> Void)? = nil,
        onOpenGuide: (() -> Void)? = nil,
        onOpenRecovery: (() -> Void)? = nil
    ) {
        self.model = model
        self.refreshAction = refreshAction
        self.onOpenExtensions = onOpenExtensions
        self.onCopyAsManaged = onCopyAsManaged
        self.onOpenGuide = onOpenGuide
        self.onOpenRecovery = onOpenRecovery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置体检")
                        .font(.system(size: 28, weight: .bold))
                    Text("配置存在不等于能够运行。安全、常用参数、成本、结构和真实请求分开判断。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新体检") { refreshAction() }
                    .buttonStyle(.borderedProminent)
            }

            if let report = model.configurationHealth {
                let managedModelCatalogBlocker = report.items.contains {
                    $0.title == "受管模型目录"
                        && $0.state == .blocked
                }
                let managedModelCatalogIssue = report.items.contains {
                    $0.title == "受管模型目录"
                        && ($0.state == .blocked || $0.state == .warning)
                }
                let catalogDismissed = managedModelCatalogIssue
                    && isCatalogDismissed(report)
                capabilitySummaryCard(
                    report.capabilitySummary
                )
                Label(
                    report.hasBlocker ? "存在阻断项，不执行自动写入" : "没有发现已知阻断项",
                    systemImage: report.hasBlocker ? "xmark.octagon.fill" : "checkmark.shield.fill"
                )
                .foregroundStyle(report.hasBlocker ? Color.red : Color.green)
                .font(.headline)
                if let lifecycle = catalogWarningLifecycle {
                    Text(warningLifecycleSummary(lifecycle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.hasBlocker,
                   onOpenExtensions != nil
                    || onOpenGuide != nil
                    || onOpenRecovery != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这些阻断项都有真入口可处理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if let onOpenExtensions {
                                Button(
                                    managedModelCatalogBlocker
                                        ? "处理受管模型目录"
                                        : "打开扩展能力"
                                ) {
                                    if managedModelCatalogBlocker {
                                        presentCatalogResolution(report)
                                    } else {
                                        onOpenExtensions()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            if let onOpenGuide {
                                Button("打开使用说明") {
                                    onOpenGuide()
                                }
                                .buttonStyle(.bordered)
                            }
                            if let onOpenRecovery {
                                Button("打开恢复入口") {
                                    onOpenRecovery()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if managedModelCatalogBlocker {
                            Text(
                                "处理入口：软件与能力 > 扩展能力 > 导入受管模型目录。"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if managedModelCatalogIssue,
                   !catalogDismissed,
                   !report.hasBlocker {
                    HStack(spacing: 8) {
                        Text("受管模型目录需要核对。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("处理受管模型目录") {
                            presentCatalogResolution(report)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                DisclosureGroup("查看技术详情") {
                    technicalDetails(
                        report,
                        onOpenExtensions: onOpenExtensions
                    )
                        .padding(.top, 10)
                }
            } else {
                ContentUnavailableView(
                    "尚未体检",
                    systemImage: "stethoscope",
                    description: Text("点击“重新体检”。只读取白名单配置并先遮挡敏感字段。")
                )
            }
        }
        .padding(28)
        .frame(maxWidth: 1_000, alignment: .leading)
        .frame(maxWidth: .infinity)
        .onAppear {
            if model.configurationHealth == nil {
                refreshAction()
            } else {
                refreshWarningLifecycle()
            }
        }
        .onChange(of: model.configurationHealth?.semanticHash) {
            _, _ in
            refreshWarningLifecycle()
        }
        .sheet(isPresented: $catalogResolutionPresented) {
            if let content = catalogResolutionContent {
                Build65CatalogResolutionSheet(
                    content: content,
                    onRecheck: {
                        recheckCatalogResolution()
                    },
                    onCopyAsManaged: { request in
                        catalogResolutionPresented = false
                        if let onCopyAsManaged {
                            onCopyAsManaged(request)
                        } else {
                            onOpenExtensions?()
                        }
                    },
                    onKeepCurrent: {
                        dismissCatalogResolution()
                    },
                    onClose: {
                        catalogResolutionPresented = false
                    }
                )
            }
        }
        .alert(
            "无法保存忽略记录",
            isPresented: Binding(
                get: { catalogDismissalError != nil },
                set: { if !$0 { catalogDismissalError = nil } }
            )
        ) {
            Button("关闭", role: .cancel) { catalogDismissalError = nil }
        } message: {
            Text(catalogDismissalError ?? "请重新核对目录后再试。")
        }
    }

    private func presentCatalogResolution(
        _ report: ConfigurationHealthReport
    ) {
        guard let item = report.items.first(where: {
            $0.title == "受管模型目录"
                && ($0.state == .blocked || $0.state == .warning)
        }) else {
            return
        }
        guard let context = report.catalogContext else {
            return
        }
        let inspection = inspectCatalog(context)
        let resolved = Build65HealthActionResolver.resolveCatalog(
            itemState: item.state,
            inspection: inspection,
            connectionHealthy: !report.hasBlocker
        )
        let dialog = Build65ManagedCatalogDialog.build(
            action: resolved,
            inspection: inspection
        )
        catalogResolutionContent = Build65CatalogResolutionPresentation(
            action: resolved,
            dialog: dialog,
            item: item,
            semanticHash: report.semanticHash,
            context: context,
            inspection: inspection
        )
        catalogResolutionPresented = true
    }

    private func recheckCatalogResolution() {
        guard let content = catalogResolutionContent else {
            catalogResolutionPresented = false
            refreshAction()
            return
        }
        let inspection = inspectCatalog(content.context)
        let action = Build65HealthActionResolver.resolveCatalog(
            itemState: content.item.state,
            inspection: inspection,
            connectionHealthy: true
        )
        catalogResolutionContent = Build65CatalogResolutionPresentation(
            action: action,
            dialog: Build65ManagedCatalogDialog.build(
                action: action,
                inspection: inspection
            ),
            item: content.item,
            semanticHash: content.semanticHash,
            context: content.context,
            inspection: inspection
        )
        refreshAction()
    }

    private func inspectCatalog(
        _ context: Build65CatalogResolutionContext
    ) -> Build65CatalogInspection {
        let store = ManagedModelCatalogStore(
            rootURL: managedCatalogRootURL
        )
        return Build65CatalogInspector.inspect(
            catalogPath: context.catalogPath,
            store: store,
            configProviderID: context.providerID,
            configContractID: context.codexContractID,
            selectedModelID: context.selectedModelID
        )
    }

    private func isCatalogDismissed(
        _ report: ConfigurationHealthReport
    ) -> Bool {
        guard let context = report.catalogContext else { return false }
        let inspection = inspectCatalog(context)
        let fingerprint = Build65CatalogDismissalFingerprint(
            profileID: context.profileID,
            providerID: context.providerID,
            catalogPathIdentity: inspection.catalogPathIdentity,
            catalogPayloadHash: inspection.payloadSHA256,
            contractID: context.codexContractID
                ?? inspection.codexContractID,
            schemaVersion: inspection.schemaVersion,
            selectedModelID: context.selectedModelID,
            configurationSemanticHash: report.semanticHash
        )
        guard fingerprint.isComplete,
              let dismissal = try? dismissalStore.read(),
              dismissal.fingerprint == fingerprint else {
            return false
        }
        let lifecycle = B68WarningLifecycleEvaluator.evaluate(
            previous: catalogWarningLifecycle,
            input: B68WarningLifecycleInput(
                severity: .warning,
                evidenceFingerprint:
                    fingerprint.configurationSemanticHash,
                observedAt: Date(),
                dismissedFingerprint: dismissal.fingerprint
                    .configurationSemanticHash,
                dismissedAt: dismissal.dismissedAt,
                cooldown: 86_400
            )
        )
        return lifecycle.status == .coolingDown
    }

    private func refreshWarningLifecycle() {
        let report = model.configurationHealth
        let item = report?.items.first(where: {
            $0.title == "受管模型目录"
                && ($0.state == .blocked || $0.state == .warning)
        })
        let severity: B68WarningLifecycleSeverity?
        switch item?.state {
        case .blocked:
            severity = .blocking
        case .warning:
            severity = .warning
        default:
            severity = nil
        }
        let dismissal = try? dismissalStore.read()
        catalogWarningLifecycle = B68WarningLifecycleEvaluator.evaluate(
            previous: catalogWarningLifecycle,
            input: B68WarningLifecycleInput(
                severity: severity,
                evidenceFingerprint: item == nil
                    ? nil : report?.semanticHash,
                observedAt: Date(),
                dismissedFingerprint: dismissal?.fingerprint
                    .configurationSemanticHash,
                dismissedAt: dismissal?.dismissedAt,
                cooldown: 86_400
            )
        )
    }

    private func warningLifecycleSummary(
        _ lifecycle: B68WarningLifecycleSnapshot
    ) -> String {
        switch lifecycle.status {
        case .resolved:
            return "提示生命周期：resolved"
        case .active:
            return "提示生命周期：active"
        case .coolingDown:
            return "提示生命周期：cooldown；技术详情仍保留"
        case .evidenceChanged:
            return "提示生命周期：evidence changed；旧忽略记录已失效"
        case .recurrence:
            return "提示生命周期：recurrence #\(lifecycle.recurrenceCount)"
        }
    }

    private var dismissalStore: Build65CatalogDismissalStore {
        Build65CatalogDismissalStore(
            url: controlRootURL.appendingPathComponent(
                "Build65/CatalogDismissal.json"
            )
        )
    }

    private var controlRootURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        return support
            .appendingPathComponent("AI接入助手", isDirectory: true)
            .appendingPathComponent("ControlPlane", isDirectory: true)
    }

    private var managedCatalogRootURL: URL {
        controlRootURL
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent(
                "ManagedModelCatalogs",
                isDirectory: true
            )
    }

    private func dismissCatalogResolution() {
        guard let content = catalogResolutionContent else {
            catalogResolutionPresented = false
            return
        }
        let fingerprint = content.dismissalFingerprint
        guard fingerprint.isComplete else {
            catalogDismissalError =
                "当前目录证据不完整，无法安全保存忽略记录；请重新核对目录。"
            return
        }
        do {
            try dismissalStore.dismiss(fingerprint)
            catalogResolutionPresented = false
        } catch {
            catalogDismissalError = error.localizedDescription
        }
    }

    private func parsedDetail(
        _ report: ConfigurationHealthReport,
        title: String,
        pattern: String
    ) -> String? {
        guard let item = report.items.first(where: {
            $0.title == title
        }) else {
            return nil
        }
        guard let regex = try? NSRegularExpression(
            pattern: pattern
        ),
        let match = regex.firstMatch(
            in: item.detail,
            range: NSRange(
                item.detail.startIndex..<item.detail.endIndex,
                in: item.detail
            )
        ),
        let range = Range(
            match.range(at: 1),
            in: item.detail
        ) else {
            return nil
        }
        return String(item.detail[range])
    }

    private func capabilitySummaryCard(
        _ summary: ConfigurationCapabilitySummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: verdictIcon(summary.verdict))
                    .foregroundStyle(
                        verdictColor(summary.verdict)
                    )
                Text("与官方能力：\(summary.verdict.rawValue)")
                    .font(.title3.bold())
            }
            if !summary.available.isEmpty {
                summaryRows(
                    title: "可用",
                    items: summary.available,
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            }
            if !summary.differences.isEmpty {
                summaryRows(
                    title: "差异",
                    items: summary.differences,
                    icon: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            if !summary.unverified.isEmpty {
                summaryRows(
                    title: "待验证",
                    items: summary.unverified,
                    icon: "questionmark.circle",
                    color: .secondary
                )
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func summaryRows(
        title: String,
        items: [ConfigurationHealthItem],
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                Label(item.title, systemImage: icon)
                    .font(.callout)
                    .foregroundStyle(color)
            }
        }
    }

    private func technicalDetails(
        _ report: ConfigurationHealthReport,
        onOpenExtensions: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hash = report.semanticHash {
                Text("语义指纹：\(hash)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(
                ConfigurationHealthCategory.allCases,
                id: \.rawValue
            ) { category in
                let items = report.items.filter {
                    $0.category == category
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(category.rawValue).font(.headline)
                        ForEach(items) { item in
                            HStack(
                                alignment: .top,
                                spacing: 10
                            ) {
                                Image(
                                    systemName:
                                        healthIcon(item.state)
                                )
                                .foregroundStyle(
                                    healthColor(item.state)
                                )
                                .frame(width: 20)
                                VStack(
                                    alignment: .leading,
                                    spacing: 3
                                ) {
                                    HStack {
                                        Text(item.title)
                                            .fontWeight(.semibold)
                                        Text(item.state.rawValue)
                                            .font(.caption.bold())
                                            .foregroundStyle(
                                                healthColor(
                                                    item.state
                                                )
                                            )
                                    }
                                    Text(item.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if (item.state == .blocked
                                        || item.state == .warning),
                                       item.title == "受管模型目录",
                                       onOpenExtensions != nil {
                                        VStack(
                                            alignment: .leading,
                                            spacing: 4
                                        ) {
                                            Text(
                                                "处理入口：软件与能力 > 扩展能力 > 导入受管模型目录"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            Button("打开受管模型目录") {
                                                onOpenExtensions?()
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        Color(
                            nsColor:
                                .controlBackgroundColor
                        ),
                        in: RoundedRectangle(
                            cornerRadius: 12
                        )
                    )
                }
            }
        }
    }

    private func verdictColor(
        _ verdict: ConfigurationCapabilityVerdict
    ) -> Color {
        switch verdict {
        case .consistent: return .green
        case .different: return .orange
        case .unverified: return .secondary
        }
    }

    private func verdictIcon(
        _ verdict: ConfigurationCapabilityVerdict
    ) -> String {
        switch verdict {
        case .consistent: return "checkmark.circle.fill"
        case .different:
            return "exclamationmark.triangle.fill"
        case .unverified: return "questionmark.circle"
        }
    }

    private func healthColor(_ state: ConfigurationHealthState) -> Color {
        switch state {
        case .passed: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .unverified: return .secondary
        case .notEnabled: return .secondary
        }
    }

    private func healthIcon(_ state: ConfigurationHealthState) -> String {
        switch state {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unverified: return "questionmark.circle"
        case .notEnabled: return "minus.circle"
        }
    }
}
