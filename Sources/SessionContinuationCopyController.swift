import AppKit
import Combine
import Foundation

/// Owns the user-authorized copy task and its UI state. The existing extractor
/// retains all history bounds, writer checks and redaction rules.
@MainActor
final class SessionContinuationCopyController: ObservableObject {
    private enum CopyError: LocalizedError {
        case clipboardWriteFailed
        var errorDescription: String? {
            "内容已读取，但未能写入剪贴板；请在该会话的“更多”菜单中重新选择“生成精简续接包”。"
        }
    }

    @Published private(set) var isCopying = false
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private let writeClipboard: (String) -> Bool

    init(writeClipboard: @escaping (String) -> Bool = { document in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(document, forType: .string)
    }) {
        self.writeClipboard = writeClipboard
    }

    func start(readPacket: @escaping () async throws -> SessionContinuationPacket) {
        guard requestID == nil else { return }
        let id = UUID()
        requestID = id
        isCopying = true
        status = nil
        errorMessage = nil
        task = Task { [weak self] in
            do {
                let packet = try await readPacket()
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                guard self.writeClipboard(packet.pasteDocument) else {
                    throw CopyError.clipboardWriteFailed
                }
                self.status = packet.continuationStatusNote
                    + "精简续接包已复制（\(packet.messages.count)条，跳过\(packet.omittedMessageCount)条）。"
                    + "请由你在Codex新建会话后手动粘贴。"
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self.errorMessage = "精简续接包没有复制：" + error.localizedDescription
                }
            }
            // An old reader may finish after cancellation and a fresh request.
            // Only the current request may clear its busy state and task handle.
            guard let self, self.requestID == id else { return }
            self.requestID = nil
            self.task = nil
            self.isCopying = false
        }
    }

    func cancel() {
        guard requestID != nil else { return }
        requestID = nil
        task?.cancel()
        task = nil
        isCopying = false
        status = nil
        errorMessage = nil
    }
}
