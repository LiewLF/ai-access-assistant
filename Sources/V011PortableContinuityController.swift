import Foundation

@MainActor
protocol V011PortableContinuityControllerDelegate: AnyObject {
    var allowsPortableContinuityActionStart: Bool { get }
    var portableContinuityProtectedProviderID: String? { get }

    func portableContinuityActionDidBegin(status: String)
    func portableContinuityActionDidApply(
        _ snapshot: V011PortableContinuityReloadSnapshot
    )
    func portableContinuityActionDidSucceed(status: String)
    func portableContinuityActionDidBecomeIdle()
    func portableContinuityRecoveryStateDidChange(
        _ recovery: V011PortableContinuityRecoveryState
    )
}

/// Owns portable-continuity prepare/apply/recover service calls and busy-state
/// ordering. AccessModel remains delegate for Published-state projection.
@MainActor
final class V011PortableContinuityController {
    private weak var delegate:
        (any V011PortableContinuityControllerDelegate)?
    private let service: V011PortableContinuityImportService

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011PortableContinuityControllerDelegate
    ) {
        service = V011PortableContinuityImportService(
            dependencies: dependencies
        )
        self.delegate = delegate
    }

    func prepare(
        from sourceURL: URL
    ) async throws -> PortableContinuityImportSession {
        guard let delegate else {
            throw PortableContinuityApplyError.stateChanged
        }
        return try await service.prepare(
            sourceURL: sourceURL,
            protectedProviderID:
                delegate.portableContinuityProtectedProviderID
        )
    }

    func apply(
        _ request: PortableContinuityApplyRequest
    ) async throws -> PortableContinuityApplyResult {
        guard let delegate,
              delegate.allowsPortableContinuityActionStart else {
            throw PortableContinuityApplyError.stateChanged
        }
        delegate.portableContinuityActionDidBegin(
            status: "正在安全导入所选迁移设置"
        )
        defer {
            delegate.portableContinuityActionDidBecomeIdle()
        }
        switch await service.apply(request) {
        case let .success(result, snapshot):
            delegate.portableContinuityActionDidApply(snapshot)
            delegate.portableContinuityActionDidSucceed(
                status: "迁移设置已导入；中转凭据尚未联网验证"
            )
            return result
        case let .failure(error, snapshot):
            delegate.portableContinuityActionDidApply(snapshot)
            throw error
        }
    }

    func recoverPending() async throws -> Int {
        guard let delegate,
              delegate.allowsPortableContinuityActionStart else {
            throw PortableContinuityApplyError.stateChanged
        }
        delegate.portableContinuityActionDidBegin(
            status: "正在恢复未完成的迁移导入"
        )
        defer {
            delegate.portableContinuityActionDidBecomeIdle()
        }
        switch await service.recoverPending() {
        case let .success(count, snapshot):
            delegate.portableContinuityActionDidApply(snapshot)
            delegate.portableContinuityActionDidSucceed(
                status: "未完成的迁移导入已安全恢复"
            )
            return count
        case let .failure(error, snapshot):
            delegate.portableContinuityActionDidApply(snapshot)
            throw error
        }
    }

    func refreshRecoveryState() {
        delegate?.portableContinuityRecoveryStateDidChange(
            service.recoveryState()
        )
    }
}
