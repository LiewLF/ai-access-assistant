import SwiftUI

struct BeginnerRecoveryRepairPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let preview: V014RecoveryRepairPreview
    let canConfirm: Bool
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("恢复前先看影响范围", systemImage: "wrench.and.screwdriver.fill")
                .font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("本次仅处理已有的 \(preview.totalCount) 个恢复点：\(preview.operationSummary)。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("下面说明影响对象；已读到的配置字段差异列在对应恢复点内。未读取或无法显示的部分会单独说明，密钥和配置值不展示。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if preview.operationImpacts.isEmpty {
                        Label("当前恢复记录没有可展示的对象明细。请取消并重新读取状态。",
                            systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(preview.operationImpacts.enumerated()), id: \.offset) { _, impact in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(impact.title).font(.headline)
                            Text(impact.direction).font(.callout)
                            ForEach(impact.affected, id: \.self) { object in
                                Label(object, systemImage: "arrow.right.circle")
                                    .font(.callout)
                            }
                            Label(impact.preserved, systemImage: "hand.raised")
                                .font(.caption)
                            Text(impact.limitation)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(impact.title)
                    }
                    Label("执行前会重新核对恢复记录；记录变化时需要重新预览和确认。首个失败停止，并保留未完成记录。",
                        systemImage: "shield.checkered")
                        .font(.callout)
                    Label("修复可能关闭并重开 Codex，并进行基础检测及真实任务验证，消耗官方额度或产生中转费用；请求数量随恢复路径而变。",
                        systemImage: "creditcard")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if !canConfirm {
                        Text("当前不能执行恢复。关闭预览后，按当前状态提示重新读取或处理冲突。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { Spacer(); cancelButton; confirmButton }
                VStack(alignment: .trailing) { confirmButton; cancelButton }
            }
        }
        .padding(24)
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 720,
               minHeight: 440, idealHeight: 620, maxHeight: 760)
        .accessibilityIdentifier("recovery.impact-preview")
    }

    private var cancelButton: some View {
        Button("取消，不执行恢复") { dismiss() }
            .keyboardShortcut(.cancelAction)
    }

    private var confirmButton: some View {
        Button("确认范围与费用，执行恢复") {
            guard canConfirm, !preview.operationImpacts.isEmpty else { return }
            let fingerprint = preview.fingerprint
            dismiss()
            onConfirm(fingerprint)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canConfirm || preview.totalCount == 0 || preview.operationImpacts.isEmpty)
        .accessibilityIdentifier("recovery.impact-preview.confirm")
    }
}
