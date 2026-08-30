import Foundation

struct V011SavedRelayPreflightActionOutcome: @unchecked Sendable {
    let result: V011SavedRelayPreflightResult
    let status: String
}

enum V011SavedRelayDeleteOutcome: @unchecked Sendable {
    case success(state: V011ManagedState, status: String)
    case failure(
        state: V011ManagedState?,
        shouldRefreshForRecovery: Bool,
        status: String,
        safeError: String
    )
}

enum V011SavedRelayAddOutcome: @unchecked Sendable {
    case success(result: V011SavedRelayAddResult, status: String)
    case failure(status: String, errorMessage: String)
}

/// Owns saved-relay action execution and deterministic UI projections while
/// V011SavedRelayService remains the transaction and compensation primitive.
struct V011SavedRelayActionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let service: V011SavedRelayService

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
        service = V011SavedRelayService(
            dependencies: dependencies
        )
    }

    func preflight(
        _ profile: CodexRelayProfile
    ) async -> V011SavedRelayPreflightActionOutcome {
        do {
            return V011SavedRelayPreflightActionOutcome(
                result: try await service.preflight(profile),
                status:
                    "“\(profile.name)”切换前检测通过；当前Codex模式未改变"
            )
        } catch {
            return V011SavedRelayPreflightActionOutcome(
                result: V011SavedRelayPreflightResult(
                    profile: profile,
                    outcome: .failed,
                    checkedAt: dependencies.now(),
                    detail: V011RecoveryErrorText.safeDetail(error)
                ),
                status:
                    "“\(profile.name)”切换前检测未通过；当前Codex模式未改变"
            )
        }
    }

    func delete(
        _ profile: CodexRelayProfile
    ) async -> V011SavedRelayDeleteOutcome {
        let service = service
        return await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    state: try service.delete(profile),
                    status:
                        "已删除“\(profile.name)”；当前Codex模式、历史会话和其他设置未改变"
                )
            } catch {
                return .failure(
                    state: try? service.loadState(),
                    shouldRefreshForRecovery:
                        service.hasPendingDeletionRecovery(),
                    status:
                        "中转未删除；已按恢复记录保留可确认状态",
                    safeError:
                        V011RecoveryErrorText.safeDetail(error)
                )
            }
        }.value
    }

    func add(
        draft: CodexRelayProfile,
        apiKey: String
    ) async -> V011SavedRelayAddOutcome {
        do {
            let result = try await service.add(
                draft: draft,
                apiKey: apiKey
            )
            return .success(
                result: result,
                status:
                    "“\(result.profileName)”已验证并保存；现在可以切换"
            )
        } catch let failure as V011SavedRelayAddFailure {
            return .failure(
                status: failure.recoveryDescription == nil
                    ? "中转没有添加，当前Codex设置未改变"
                    : "中转没有添加，凭据恢复需要处理",
                errorMessage: failure.localizedDescription
            )
        } catch {
            return .failure(
                status: "中转没有添加，当前Codex设置未改变",
                errorMessage: error.localizedDescription
            )
        }
    }
}
