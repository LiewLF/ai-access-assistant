// SPDX-License-Identifier: AGPL-3.0-only

enum V015PassiveStateReadBoundary {
    static let detail =
        "不会修改 Codex 配置，也不会联网。首次遇到新 Codex 版本时，只会在 AI接入助手自己的 Application Support 目录保存版本和二进制绑定兼容回执；后续联网或费用动作仍会另行确认。"
}

enum V015FirstUseGuidanceAction: String, Equatable, Sendable {
    case installCodex
    case refreshState
    case checkBasic
    case verifyRealTask
    case addRelay
    case switchMode
}

struct V015FirstUseGuidanceInput: Equatable, Sendable {
    let route: V015UserJourneyRoute
    let codexInstalled: Bool
    let savedRelayCount: Int
    let verificationStage: V014VerificationJourneyStage
    let hasBlockingIssue: Bool
    let isReadingCurrentState: Bool
}

struct V015FirstUseGuidance: Equatable, Sendable {
    let isVisible: Bool
    let title: String
    let detail: String
    let primaryTitle: String?
    let primaryAction: V015FirstUseGuidanceAction?
    let secondaryTitle: String?
    let secondaryAction: V015FirstUseGuidanceAction?

    static let hidden = V015FirstUseGuidance(
        isVisible: false,
        title: "",
        detail: "",
        primaryTitle: nil,
        primaryAction: nil,
        secondaryTitle: nil,
        secondaryAction: nil
    )
}

enum V015FirstUseGuidanceResolver {
    static func resolve(
        _ input: V015FirstUseGuidanceInput
    ) -> V015FirstUseGuidance {
        guard !input.hasBlockingIssue else { return .hidden }
        guard input.codexInstalled else {
            return V015FirstUseGuidance(
                isVisible: true,
                title: "先安装并登录 Codex",
                detail: "完成官方安装和登录后，可以直接使用官方接入；中转以后需要时再添加。",
                primaryTitle: "打开安装说明",
                primaryAction: .installCodex,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        }

        if input.isReadingCurrentState {
            return progressGuidance(
                title: "正在读取当前接入",
                detail: "正在读取本机 Codex 状态。\(V015PassiveStateReadBoundary.detail)"
            )
        }

        switch input.verificationStage {
        case .needsBasic:
            return actionableGuidance(
                input: input,
                step: 1
            )
        case .needsRealTask:
            return actionableGuidance(
                input: input,
                step: 2
            )
        case .checkingBasic:
            return progressGuidance(
                title: "正在完成第1步",
                detail: "正在确认当前接入的基础连接，请等待结果。"
            )
        case .verifyingRealTask:
            return progressGuidance(
                title: "正在完成第2步",
                detail: "正在隔离环境验证真实任务，请等待结果。"
            )
        case .recoveryRequired, .basicFailed, .realTaskFailed, .ready:
            return .hidden
        }
    }

    private static func actionableGuidance(
        input: V015FirstUseGuidanceInput,
        step: Int
    ) -> V015FirstUseGuidance {
        switch input.route {
        case .official:
            let secondaryAction: V015FirstUseGuidanceAction =
                input.savedRelayCount == 0 ? .addRelay : .switchMode
            return V015FirstUseGuidance(
                isVisible: true,
                title: "先用官方，完成第\(step)步",
                detail: step == 1
                    ? "当前已是官方接入，不需要切换中转。先确认基础连接；中转只是可选项。"
                    : "当前仍是官方接入，不需要切换中转。完成真实任务验证后再开始工作。",
                primaryTitle: step == 1
                    ? "保留官方并继续"
                    : "验证官方真实任务",
                primaryAction: step == 1
                    ? .checkBasic : .verifyRealTask,
                secondaryTitle: input.savedRelayCount == 0
                    ? "需要时添加中转" : "查看其他接入",
                secondaryAction: secondaryAction
            )
        case .relay:
            return V015FirstUseGuidance(
                isVisible: true,
                title: "当前使用中转，先完成第\(step)步",
                detail: step == 1
                    ? "先确认当前中转的基础连接；不会自动改用其他接入。"
                    : "完成当前中转的真实任务验证后再开始工作；不会自动切换。",
                primaryTitle: step == 1
                    ? "确认当前中转连接"
                    : "验证当前中转任务",
                primaryAction: step == 1
                    ? .checkBasic : .verifyRealTask,
                secondaryTitle: "查看其他接入",
                secondaryAction: .switchMode
            )
        case .unknown:
            return V015FirstUseGuidance(
                isVisible: true,
                title: "先读取当前接入",
                detail: V015PassiveStateReadBoundary.detail,
                primaryTitle: "读取当前状态",
                primaryAction: .refreshState,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        }
    }

    private static func progressGuidance(
        title: String,
        detail: String
    ) -> V015FirstUseGuidance {
        V015FirstUseGuidance(
            isVisible: true,
            title: title,
            detail: detail,
            primaryTitle: nil,
            primaryAction: nil,
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }
}
