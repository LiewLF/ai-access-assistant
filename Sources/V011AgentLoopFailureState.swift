import Foundation

/// Transient verification errors are not receipts: no request or tool outcome
/// is invented. Keep the captured attempt scope until the next explicit check.
struct V011AgentLoopFailureState {
    struct Scope: Equatable {
        let configHash: String
        let providerID: String
        let version: CodexVersionIdentity

        init(_ live: LiveCodexState) {
            configHash = live.configHash
            providerID = V011ConnectionHealthService.providerID(live)
            version = live.version
        }
    }

    private var attempt: Scope?
    private var failure: Scope?
    private var message: String?

    mutating func begin(live: LiveCodexState?) {
        clear()
        attempt = live.map(Scope.init)
    }

    mutating func fail(_ message: String) {
        failure = attempt
        self.message = message
    }

    mutating func clear() {
        attempt = nil
        failure = nil
        message = nil
    }

    mutating func refresh(live: LiveCodexState) -> String? {
        guard (failure ?? attempt) == Scope(live) else {
            clear()
            return nil
        }
        return message
    }

    func currentMessage(live: LiveCodexState?) -> String? {
        guard let live, failure == Scope(live) else { return nil }
        return message
    }

    static func presentation(_ message: String) -> V013FailurePresentation {
        V013FailurePresentation(
            conclusion: "真实任务验证未完成",
            explanation: message,
            primaryAction: .openAdvancedDiagnostics,
            evidence: ["本次验证未生成可采用的任务回执；不代表已完成请求或工具调用。"]
        )
    }
}
