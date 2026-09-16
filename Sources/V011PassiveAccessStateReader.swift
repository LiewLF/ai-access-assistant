import Foundation

struct V011PassiveAccessStateSnapshot {
    let live: LiveCodexState?
    let errorMessage: String?
    let connectionReceipt: V011ConnectionReceipt?
    let agentLoopReceipt: V011AgentLoopReceipt?
    let recovery: V011PendingRecoveryContext
    var hasPendingRecovery: Bool { recovery.pending }
    var status: String {
        hasPendingRecovery ? "发现上次未完成的操作；先读取恢复状态"
            : errorMessage ?? "已读取本机当前接入；连接与版本尚未重新检测"
    }
}

/// Reads configuration identity without version discovery, commands, network,
/// Keychain access, or persistence. A later explicit action verifies capability.
enum V011PassiveAccessStateReader {
    static let unknownVersion = "尚未核对"

    static func read(
        dependencies: V011AccessDependencies,
        managedState: V011ManagedState
    ) throws -> V011PassiveAccessStateSnapshot {
        let core = FableSwitchCore(
            codexHome: dependencies.codexHome,
            versionContract: CodexVersionContract(entries: []),
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier: dependencies.runtimeVerifier,
            managedProviderIDs: managedState.managedProviderIDSet
        )
        // These are explicit unknown markers, never a claimed installed version
        // or a schema contract that could authorize configuration writes.
        let recovery = try V011AccessStateReader.pendingRecoveryContext(
            dependencies: dependencies, passive: true)
        let live: LiveCodexState?
        let errorMessage: String?
        do {
            live = try core.inspect(version: CodexVersionIdentity(
                appVersion: unknownVersion, appBuild: unknownVersion, cliVersion: unknownVersion))
            errorMessage = nil
        } catch {
            live = nil
            errorMessage = V011RecoveryErrorText.safeDetail(error)
        }
        let receiptStore = V011ConnectionHealthService(
            controlRoot: dependencies.controlRoot,
            now: dependencies.now
        ).receiptStore
        let agentLoopStore = V011AgentLoopReceiptStore(fileURL: dependencies.controlRoot
            .appendingPathComponent("V011/agent-loop-receipt.json"))
        return V011PassiveAccessStateSnapshot(
            live: live,
            errorMessage: errorMessage,
            connectionReceipt: try? receiptStore.load(),
            agentLoopReceipt: try? agentLoopStore.load(),
            recovery: recovery
        )
    }
}

extension V011AccessModel {
    var needsCurrentStateRead: Bool {
        guard let version = liveState?.version else { return true }
        return version.appBuild == V011PassiveAccessStateReader.unknownVersion
            || version.appVersion == V011PassiveAccessStateReader.unknownVersion
            || version.cliVersion == V011PassiveAccessStateReader.unknownVersion
    }
}
