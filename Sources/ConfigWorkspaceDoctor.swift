// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension ConfigWorkspaceModel {
    func runCodexDoctorDiagnostic() {
        guard confirmsCodexDoctorDiagnostic else {
            errorMessage =
                "先确认允许Codex官方诊断只读配置并执行网络连通性检查"
            return
        }
        guard !isRunningCodexDoctorDiagnostic else { return }
        isRunningCodexDoctorDiagnostic = true
        codexDoctorStatus = "正在运行Codex官方脱敏诊断…"
        let codexHome = codexHomeURL
        Task {
            do {
                let executable = try CodexDoctorDiagnosticRunner
                    .embeddedExecutableURL()
                let diagnostic = try await Task.detached {
                    try CodexDoctorDiagnosticRunner.run(
                        executableURL: executable,
                        codexHome: codexHome,
                        userAuthorized: true
                    )
                }.value
                codexDoctorDiagnostic = diagnostic
                refreshRuntimeTruth()
                let guidance =
                    CodexDoctorActionableProjector.project(
                        diagnostic: diagnostic,
                        comparison: codexDoctorComparison
                    )
                codexDoctorGuidance = guidance
                codexDoctorStatus = guidance.summary
                errorMessage = nil
            } catch {
                codexDoctorStatus =
                    "Codex官方诊断失败：\(error.localizedDescription)"
                codexDoctorGuidance = nil
                codexDoctorBlocksManagedWrite =
                    (error as? CodexDoctorDiagnosticError)
                        == .codexHomeMismatch
            }
            isRunningCodexDoctorDiagnostic = false
            confirmsCodexDoctorDiagnostic = false
        }
    }

    func refreshCodexDoctorComparison(
        with truth: RuntimeTruth
    ) {
        guard let diagnostic = codexDoctorDiagnostic else {
            codexDoctorComparison = nil
            codexDoctorGuidance = nil
            codexDoctorBlocksManagedWrite = false
            return
        }
        let comparison = CodexDoctorTruthComparator.compare(
            diagnostic: diagnostic,
            runtimeTruth: truth
        )
        codexDoctorComparison = comparison
        codexDoctorGuidance =
            CodexDoctorActionableProjector.project(
                diagnostic: diagnostic,
                comparison: comparison
            )
        codexDoctorBlocksManagedWrite =
            !comparison.matchesPersistentConfig
    }
}
