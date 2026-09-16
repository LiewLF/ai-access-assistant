import Foundation

enum BeginnerRelayDraftEvent {
    case primaryButton
    case modelReadFinished
}

enum BeginnerRelayDraftAction: Equatable {
    case none
    case readModels
    case submit
    case feedback(String)
}

/// Model discovery updates a draft; only an explicit button event can add it.
enum BeginnerRelayDraftActionPolicy {
    static func action(
        for event: BeginnerRelayDraftEvent,
        isDraftVisible: Bool,
        isBusy: Bool,
        isFetchingModels: Bool,
        hasSelectedModel: Bool
    ) -> BeginnerRelayDraftAction {
        guard isDraftVisible, !isBusy, !isFetchingModels else {
            return .none
        }
        switch event {
        case .primaryButton:
            return hasSelectedModel ? .submit : .readModels
        case .modelReadFinished:
            return .feedback(hasSelectedModel
                ? "草稿已有模型。确认选择后，点击“检测并添加”完成验证和保存。"
                : "尚未选择模型。可手动填写或再次读取，然后点击“检测并添加”。")
        }
    }

    static func buttonTitle(
        isFetchingModels: Bool,
        hasSelectedModel: Bool
    ) -> String {
        if isFetchingModels { return "正在读取模型" }
        return hasSelectedModel ? "检测并添加" : "读取可用模型"
    }
}
