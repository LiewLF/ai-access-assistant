// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

struct BeginnerCodexDoctorView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @State private var evidenceExpanded = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        "Codex官方诊断",
                        systemImage: "cross.case.fill"
                    )
                    .font(.title3.bold())
                    Text(
                        "调用Codex自己的诊断能力，核对设置和网络。原始路径、密钥、摘要和修复文本不会进入行动结果。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                guidanceView
                Toggle(
                    "允许本次只读检查并测试网络",
                    isOn: $model.confirmsCodexDoctorDiagnostic
                )
                .toggleStyle(.checkbox)
                .accessibilityHint(
                    "仅授权这一次Codex官方诊断；不会修改当前接入"
                )
                .accessibilityIdentifier(
                    "build155.doctor.network-consent"
                )
                Button(
                    model.isRunningCodexDoctorDiagnostic
                        ? "正在诊断"
                        : "开始Codex诊断"
                ) {
                    model.runCodexDoctorDiagnostic()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !model.confirmsCodexDoctorDiagnostic
                        || model.isRunningCodexDoctorDiagnostic
                )
                .accessibilityHint(
                    "运行一次用户已确认的Codex官方诊断"
                )
                .accessibilityIdentifier("build155.doctor.run")
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var guidanceView: some View {
        if let guidance = model.codexDoctorGuidance {
            Label(
                guidance.conclusion,
                systemImage: guidanceIcon(guidance.state)
            )
            .font(.headline)
            .foregroundStyle(guidanceColor(guidance.state))
            Text(guidance.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button(guidance.primaryAction.title) {
                perform(guidance.primaryAction)
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunningCodexDoctorDiagnostic)
            .accessibilityHint(guidance.explanation)
            .accessibilityIdentifier(
                "build155.doctor.primary-action"
            )
            if guidance.primaryAction == .reviewEvidence {
                if evidenceExpanded {
                    evidenceList(guidance.evidence)
                }
            } else {
                DisclosureGroup(
                    "查看安全诊断依据",
                    isExpanded: $evidenceExpanded
                ) {
                    evidenceList(guidance.evidence)
                }
            }
        } else {
            Text(model.codexDoctorStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func evidenceList(_ evidence: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(
                Array(evidence.enumerated()),
                id: \.offset
            ) { _, item in
                Text(item)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 5)
    }

    private func perform(_ action: CodexDoctorPrimaryAction) {
        actionError = nil
        switch action {
        case .openCodex, .openCodexLogin:
            actionError = BeginnerCodexLauncher.openInstalled()
        case .refreshState:
            model.refreshRuntimeTruth()
        case .reviewConfiguration:
            model.openCodexConfiguration()
        case .checkNetwork:
            model.confirmsCodexDoctorDiagnostic = true
            model.runCodexDoctorDiagnostic()
        case .updateCodex:
            if !NSWorkspace.shared.open(
                OfficialAgentCatalog.codexDownload
            ) {
                actionError = "无法打开Codex官方下载页"
            }
        case .reviewEvidence:
            evidenceExpanded.toggle()
        }
    }

    private func guidanceColor(
        _ state: CodexDoctorReadinessState
    ) -> Color {
        switch state {
        case .ready: return .green
        case .limited: return .orange
        case .blocked: return .red
        case .unknown: return .secondary
        }
    }

    private func guidanceIcon(
        _ state: CodexDoctorReadinessState
    ) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .limited:
            return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
