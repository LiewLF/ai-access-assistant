import Foundation

enum V011RelayUpdateActionOutcome: @unchecked Sendable {
    case success(
        result: V011CapabilityProfileUpdateResult,
        status: String
    )
    case failure(
        status: String,
        errorMessage: String,
        shouldRefresh: Bool
    )
}

/// Maps relay capability/profile update execution into deterministic UI
/// outcomes while V011RelayUpdateService owns transactions and compensation.
struct V011RelayUpdateActionService: @unchecked Sendable {
    private let service: V011RelayUpdateService

    init(service: V011RelayUpdateService) {
        self.service = service
    }

    func updateCapabilities(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) async -> V011RelayUpdateActionOutcome {
        do {
            let result = try await service.updateCapabilities(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile
            )
            let sourceIsCurrent =
                V011ConnectionHealthService.providerID(
                    result.liveState
                ) == sourceProfile.v011ProviderID
            return .success(
                result: result,
                status: result.appliedToLiveConfiguration
                    ? "当前轨能力已应用；Codex已快速重开，历史会话未改动"
                    : (
                        sourceIsCurrent
                            ? "能力档已更新；当前Codex配置无需改动"
                            : "能力档已保存；下次切换到该中转时自动应用"
                    )
            )
        } catch let failure as V011RelayUpdateFailure {
            if failure.isPreflight {
                return .failure(
                    status:
                        "写入前验证未通过；能力档和Codex设置未改变",
                    errorMessage: failure.primaryDescription,
                    shouldRefresh: failure.shouldRefresh
                )
            }
            return .failure(
                status: "能力配置未完成；请按当前状态提示处理",
                errorMessage: failure.primarySafeDescription,
                shouldRefresh: failure.shouldRefresh
            )
        } catch {
            return .failure(
                status: "能力配置未完成；请按当前状态提示处理",
                errorMessage: V011RecoveryErrorText.safeDetail(error),
                shouldRefresh: false
            )
        }
    }

    func updateProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        replacementSecret: String?,
        sourceIsCurrent: Bool
    ) async -> V011RelayUpdateActionOutcome {
        do {
            let result = try await service.updateProfile(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile,
                replacementSecret: replacementSecret
            )
            return .success(
                result: result,
                status: result.appliedToLiveConfiguration
                    ? "当前中转资料已应用；Codex已快速重开，历史会话未改动"
                    : (
                        sourceIsCurrent
                            ? "当前中转资料已更新；Codex配置无需改动"
                            : "中转资料已验证并保存；下次切换时自动应用"
                    )
            )
        } catch let failure as V011RelayUpdateFailure {
            return .failure(
                status: failure.recoverySafeDescription == nil
                    ? "中转资料未保存；当前Codex设置未改变"
                    : "中转资料未保存；凭据恢复需要处理",
                errorMessage: failure.localizedDescription,
                shouldRefresh: failure.shouldRefresh
            )
        } catch {
            return .failure(
                status: "中转资料未保存；当前Codex设置未改变",
                errorMessage: V011RecoveryErrorText.safeDetail(error),
                shouldRefresh: false
            )
        }
    }
}
