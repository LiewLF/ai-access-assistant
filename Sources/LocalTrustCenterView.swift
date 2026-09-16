// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct LocalTrustCenterView: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    @ObservedObject var model: LocalTrustCenterModel
    let performPrimaryAction:
        (CapabilityCompatibilityPrimaryAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        panel(displayTextSize: displayTextSize)
        .accessibilityIdentifier("build135.capability-compatibility")
        .onDisappear {
            model.cancel()
        }
    }

    func panel(displayTextSize: AppDisplayTextSize) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 620
            let rowLayout = compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("能力兼容性")
                            .font(.title2.bold())
                        Text(
                            "只读核对；不会自动安装、卸载、禁用、修复或改写第三方能力。"
                        )
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                        alignment: .leading, spacing: 10
                    ) {
                        Button("设为升级前基线") {
                            model.captureCompatibilityBaseline()
                        }
                        .disabled(
                            model.isScanning
                                || model.compatibilityReport == nil
                        )
                        .accessibilityIdentifier(
                            "build136.capability-diff-baseline"
                        )
                        Button("重新扫描") {
                            model.refresh()
                        }
                        .disabled(model.isScanning)
                        Button("关闭") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(20)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.isScanning {
                            ProgressView(model.status)
                        } else if let snapshot = model.snapshot {
                            Text(
                                "项目 \(snapshot.artifacts.count) · MCP ID \(snapshot.mcpServers.count) · Hook ID \(snapshot.hooks.count) · 风险提示 \(snapshot.riskCount)"
                            )
                            .font(.headline)

                            if let report = model.compatibilityReport {
                                trustSection("当前结论与首要动作") {
                                    ForEach(report.items) { item in
                                        let presentation =
                                            CapabilityCompatibilityPresenter
                                                .presentation(for: item)
                                        VStack(alignment: .leading, spacing: 6) {
                                            rowLayout {
                                                Text(presentation.conclusion)
                                                    .font(
                                                        .body.weight(.semibold)
                                                    )
                                                if let action =
                                                    presentation.primaryAction {
                                                    Button(action.title) {
                                                        performPrimaryAction(
                                                            action
                                                        )
                                                    }
                                                    .accessibilityIdentifier(
                                                        "build135.capability-primary-action.\(item.kind.stableID)"
                                                    )
                                                }
                                            }
                                            DisclosureGroup("查看证据") {
                                                VStack(
                                                    alignment: .leading,
                                                    spacing: 3
                                                ) {
                                                    ForEach(
                                                        Array(
                                                            presentation
                                                                .evidence
                                                                .enumerated()
                                                        ),
                                                        id: \.offset
                                                    ) { _, evidence in
                                                        Text(evidence)
                                                            .font(.caption)
                                                            .foregroundStyle(
                                                                .secondary
                                                            )
                                                            .textSelection(
                                                                .enabled
                                                            )
                                                    }
                                                }
                                                .padding(.top, 4)
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .accessibilityIdentifier(
                                            "build135.capability.\(item.kind.stableID)"
                                        )
                                    }
                                    Text(
                                        "本次核对：网络0 · 进程0 · 配置写入0 · 扩展写入0"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            if model.hasCompatibilityBaseline {
                                if let result =
                                    model.compatibilityDiffResult {
                                    switch result {
                                    case .ready(let preview):
                                        trustSection("升级前后差异预检") {
                                            Text(preview.summary)
                                                .font(.body.weight(.semibold))
                                            ForEach(preview.items) { item in
                                                let beforePresentation =
                                                    CapabilityCompatibilityPresenter
                                                        .presentation(
                                                            for: item.before
                                                        )
                                                let afterPresentation =
                                                    CapabilityCompatibilityPresenter
                                                        .presentation(
                                                            for: item.after
                                                        )
                                                VStack(
                                                    alignment: .leading,
                                                    spacing: 5
                                                ) {
                                                    Text(
                                                        "\(item.kind.rawValue)：\(item.change.title)"
                                                    )
                                                    .font(
                                                        .body.weight(.semibold)
                                                    )
                                                    Text(
                                                        "升级前：\(beforePresentation.conclusion)"
                                                    )
                                                    Text(
                                                        "升级后：\(afterPresentation.conclusion)"
                                                    )
                                                    DisclosureGroup("查看差异证据") {
                                                        VStack(
                                                            alignment: .leading,
                                                            spacing: 3
                                                        ) {
                                                            Text(
                                                                "升级前：\(item.before.verdict.rawValue) · \(item.before.freshness.rawValue) · \(item.before.detail)"
                                                            )
                                                            Text(
                                                                "升级后：\(item.after.verdict.rawValue) · \(item.after.freshness.rawValue) · \(item.after.detail)"
                                                            )
                                                        }
                                                        .padding(.top, 4)
                                                    }
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                }
                                            }
                                            Text(
                                                "这只是只读比较；不会自动安装、禁用或改写第三方能力。"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .accessibilityIdentifier(
                                            "build136.capability-diff-preview"
                                        )
                                    case .blocked(let blocker):
                                        trustSection("升级前后差异预检") {
                                            Text(blocker.message)
                                                .foregroundStyle(.orange)
                                            Text(
                                                "请重新建立完整基线；不会自动安装、禁用或改写第三方能力。"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .accessibilityIdentifier(
                                            "build136.capability-diff-preview"
                                        )
                                    }
                                } else {
                                    trustSection("升级前后差异预检") {
                                        Text(
                                            "升级前基线只在本次应用运行期间保留；完成外部升级后点“重新扫描”。不会修改配置。"
                                        )
                                        Text(
                                            "不会自动安装、禁用或改写第三方能力。"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            DisclosureGroup("查看全部本机技术证据") {
                                VStack(alignment: .leading, spacing: 12) {
                                    technicalEvidence(snapshot, rowLayout: rowLayout)
                                }
                                .padding(.top, 8)
                            }
                            .accessibilityIdentifier(
                                "build135.capability-technical-evidence"
                            )
                        } else {
                            ContentUnavailableView(
                                "尚未扫描",
                                systemImage: "checkmark.shield",
                                description: Text(
                                    "打开后点“重新扫描”生成当前本机只读快照。"
                                )
                            )
                        }
                        Text(
                            "技术详情中的内容指纹只证明本次读取内容；不证明作者可信、运行采用、MCP连接或Hook执行。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            }
        }
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 1000,
               minHeight: 440, idealHeight: 620, maxHeight: 820)
    }

    @ViewBuilder
    private func technicalEvidence(
        _ snapshot: LocalTrustSnapshot,
        rowLayout: AnyLayout
    ) -> some View {
        if !snapshot.mcpServers.isEmpty {
            trustSection("MCP配置结构") {
                ForEach(snapshot.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.serverID)
                            .font(.body.weight(.semibold))
                        Text(server.connectionState)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(
                            server.configurationFields.isEmpty
                                ? "字段：未展开"
                                : "字段：" + server.configurationFields
                                    .joined(separator: ", ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !snapshot.hooks.isEmpty {
            trustSection("Hooks配置结构") {
                ForEach(snapshot.hooks) { hook in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hook.hookID)
                            .font(.body.weight(.semibold))
                        Text(hook.executionState)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(
                            hook.configurationFields.isEmpty
                                ? "字段：未展开"
                                : "字段：" + hook.configurationFields
                                    .joined(separator: ", ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        trustSection("本地扩展核对") {
            ForEach(snapshot.artifacts) { artifact in
                artifactRow(artifact, rowLayout: rowLayout)
            }
        }

        if !snapshot.warnings.isEmpty {
            trustSection("未完成核对") {
                ForEach(
                    Array(snapshot.warnings.enumerated()),
                    id: \.offset
                ) { _, warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func trustSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func artifactRow(
        _ artifact: LocalTrustArtifact,
        rowLayout: AnyLayout
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rowLayout {
                Text("\(artifact.kind.rawValue) · \(artifact.name)")
                    .font(.body.weight(.semibold))
                if artifact.symbolicLink {
                    Text("符号链接")
                        .foregroundStyle(.red)
                }
                if artifact.duplicateName {
                    Text("重名候选")
                        .foregroundStyle(.orange)
                }
                if artifact.writableByGroupOrOthers {
                    Text("权限过宽")
                        .foregroundStyle(.red)
                }
            }
            Text("来源：\(artifact.sourceRoot)")
            if let shadowedBy = artifact.shadowedBy {
                Text("扫描顺序下的路径遮蔽候选：\(shadowedBy)")
                    .foregroundStyle(.orange)
            }
            DisclosureGroup("技术详情") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("来源根：\(artifact.rootPath)")
                    Text(
                        "相对路径：\(artifact.relativePath) · 权限：\(artifact.permissions)"
                    )
                    if let digest = artifact.sha256 {
                        Text("SHA-256：\(digest)")
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
