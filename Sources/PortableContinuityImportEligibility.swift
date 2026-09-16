import Foundation

/// Read-only feedback for the existing migration form. No credentials or writes.
struct PortableContinuityImportEligibility: Equatable {
    let issue: String?
    var canApply: Bool { issue == nil }

    struct Relay {
        let targetID: String
        let hasCredential: Bool
        let targetIssue: String?
    }

    struct Workspace {
        let targetPath: String
        let isFavorite: Bool
    }

    static func evaluate(
        hasSession: Bool, confirmed: Bool, isBusy: Bool, hasPendingImport: Bool,
        relays: [Relay], workspaces: [Workspace]
    ) -> Self {
        func blocked(_ message: String) -> Self { Self(issue: message) }
        if isBusy { return blocked("正在处理其他操作，请等当前操作结束后再导入。") }
        if hasPendingImport { return blocked("发现未完成的迁移导入，请先完成恢复。") }
        if !hasSession { return blocked("请先选择迁移设置文件并完成预检。") }
        if relays.isEmpty && workspaces.isEmpty {
            return blocked("请至少选择一条中转或一个工作区标签。")
        }
        for (index, relay) in relays.enumerated() {
            if let issue = relay.targetIssue {
                return blocked("第\(index + 1)条已选中转：\(issue)")
            }
            if !relay.hasCredential {
                return blocked("第\(index + 1)条已选中转尚未填写凭据，请在本机重新输入。")
            }
        }
        // Empty IDs create separate new profiles and are not duplicate updates.
        let targetIDs = relays.map(\.targetID).filter { !$0.isEmpty }
        if Set(targetIDs).count != targetIDs.count {
            return blocked("多条已选中转指向同一个现有中转，请调整其中一项的写入目标，或取消该项。")
        }
        for (index, workspace) in workspaces.enumerated() where !workspace.isFavorite {
            return blocked("第\(index + 1)个已选标签尚未绑定有效工作区，请选择本机已收藏工作区。")
        }
        let targetPaths = workspaces.map(\.targetPath)
        if Set(targetPaths).count != targetPaths.count {
            return blocked("多个已选标签绑定到同一个工作区，请调整其中一项的目标工作区，或取消该项。")
        }
        if !confirmed { return blocked("请核对来源、字段、目标和凭据，再勾选上方确认。") }
        return Self(issue: nil)
    }
}
