import AppKit

@MainActor
final class V013CPACollectionAppLifecycle: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        _ = SensitiveTemporaryArtifactJanitor.cleanupExpired()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let collection = V013CPACollectionModel.shared
        guard collection.needsShutdown else { return .terminateNow }
        Task {
            let stopped = await collection.stop()
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}
