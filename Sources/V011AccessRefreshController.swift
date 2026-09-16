import Foundation

@MainActor
protocol V011AccessRefreshControllerDelegate: AnyObject {
    var allowsAccessRefreshStart: Bool { get }

    func accessRefreshPreparePresentation()
    func accessRefreshConnectionFailureScope()
        -> V011ConnectionFailureScope
    func accessRefreshDidBegin(status: String)
    func accessRefreshDidReceive(
        _ outcome: V011AccessRefreshOutcome
    )
    func accessRefreshDidBecomeIdle()
    func accessRefreshDidFinish(
        _ observation: V011RefreshObservation
    )
    func accessRefreshDidObserveRecovery(
        _ recovery: V011PendingRecoveryContext
    )
}

/// Owns refresh request coalescing, debounce, task lifetime, and timing.
/// AccessModel remains the weak delegate for Published-state projection.
@MainActor
final class V011AccessRefreshController {
    private let dependencies: V011AccessDependencies
    private weak var delegate:
        (any V011AccessRefreshControllerDelegate)?
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var gate = V011RefreshGate()
    private var completionAfterRefresh: (() -> Void)?

    private lazy var service = V011AccessRefreshService(
        dependencies: dependencies,
        recoveryProgress: { [weak self] recovery in
            self?.delegate?
                .accessRefreshDidObserveRecovery(recovery)
        }
    )

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011AccessRefreshControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func request(
        reason: V011RefreshReason,
        debounceNanoseconds: UInt64,
        completion: (() -> Void)? = nil
    ) {
        guard reason == .manual
                || dependencies.allowsUnpromptedRefresh else {
            delegate?.accessRefreshPreparePresentation()
            return
        }
        if let completion { completionAfterRefresh = completion }
        guard gate.request(reason) == .schedule else {
            return
        }
        debounceTask?.cancel()
        guard debounceNanoseconds > 0 else {
            beginIfPossible()
            return
        }
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: debounceNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.beginIfPossible()
        }
    }

    private func beginIfPossible() {
        guard let delegate,
              delegate.allowsAccessRefreshStart,
              let reasons = gate.begin() else {
            return
        }
        delegate.accessRefreshDidBegin(
            status:
                "正在核对Codex版本；检测到升级会自动在隔离环境验证"
        )
        let connectionFailureScope =
            delegate.accessRefreshConnectionFailureScope()
        let startedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        let service = service
        refreshTask = Task { [weak self] in
            defer {
                self?.finish(
                    reasons: reasons,
                    startedNanoseconds: startedNanoseconds
                )
            }
            do {
                let outcome = try await service.load(
                    connectionFailureScope:
                        connectionFailureScope
                )
                guard !Task.isCancelled else { return }
                self?.delegate?
                    .accessRefreshDidReceive(outcome)
            } catch is CancellationError {
            } catch {
                self?.delegate?.accessRefreshDidReceive(
                    .failed(
                        V011AccessRefreshFailed(
                            recovery: nil,
                            status: "暂时无法读取Codex状态",
                            errorMessage:
                                error.localizedDescription
                        )
                    )
                )
            }
        }
    }

    private func finish(
        reasons: [V011RefreshReason],
        startedNanoseconds: UInt64
    ) {
        let elapsedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - startedNanoseconds
        delegate?.accessRefreshDidBecomeIdle()
        let needsTrailingRefresh = gate.complete()
        delegate?.accessRefreshDidFinish(
            V011RefreshObservation(
                reasons: reasons,
                durationMilliseconds:
                    Double(elapsedNanoseconds) / 1_000_000,
                requestCount: gate.requestCount,
                executionCount: gate.executionCount,
                coalescedRequestCount:
                    gate.coalescedRequestCount
            )
        )
        if needsTrailingRefresh {
            beginIfPossible()
        } else {
            let completion = completionAfterRefresh
            completionAfterRefresh = nil
            completion?()
        }
    }
}
