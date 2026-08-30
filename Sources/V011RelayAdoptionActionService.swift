import Foundation

enum V011RelayAdoptionActionOutcome: @unchecked Sendable {
    case success(
        result: V011RelayAdoptionResult,
        status: String
    )
    case unchanged(status: String, errorMessage: String)
    case rolledBack(
        state: V011ManagedState,
        status: String,
        errorMessage: String
    )
    case recoveryPending(status: String, errorMessage: String)
}

/// Maps adoption transaction results into explicit UI/recovery outcomes.
struct V011RelayAdoptionActionService: @unchecked Sendable {
    private let service: V011RelayAdoptionService

    init(dependencies: V011AccessDependencies) {
        service = V011RelayAdoptionService(
            dependencies: dependencies
        )
    }

    func adoptCurrentRelay(
        displayName: String
    ) async -> V011RelayAdoptionActionOutcome {
        do {
            let result = try await service.adoptCurrentRelay(
                displayName: displayName
            )
            return .success(
                result: result,
                status:
                    "已接管“\(result.profileName)”；当前Codex设置保持不变，请检测连接确认任务路由"
            )
        } catch let failure as V011RelayAdoptionFailure {
            switch failure.disposition {
            case .unchanged:
                return .unchanged(
                    status: "当前中转未接管，现有设置保持不变",
                    errorMessage: failure.primaryDescription
                )
            case let .rolledBack(state):
                return .rolledBack(
                    state: state,
                    status: "当前中转未接管，现有设置保持不变",
                    errorMessage: failure.primaryDescription
                )
            case .recoveryPending:
                return .recoveryPending(
                    status: "当前中转未接管，恢复尚未完成",
                    errorMessage: failure.localizedDescription
                )
            }
        } catch {
            return .unchanged(
                status: "当前中转未接管，现有设置保持不变",
                errorMessage: error.localizedDescription
            )
        }
    }
}
