import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BeginnerText {
    static func friendly(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: "config.toml",
                with: "Codex设置"
            )
            .replacingOccurrences(
                of: "Provider",
                with: "当前模式"
            )
            .replacingOccurrences(
                of: "SQLite",
                with: "会话索引"
            )
            .replacingOccurrences(
                of: "rollout",
                with: "会话文件"
            )
            .replacingOccurrences(
                of: "Helper",
                with: "本机凭据组件"
            )
    }
}

enum BeginnerCodexLauncher {
    static func openInstalled() -> String? {
        guard let applicationURL =
                CodexApplicationLocator.applicationURL(),
              NSWorkspace.shared.open(applicationURL) else {
            return "无法打开 Codex。请在“应用程序”中手动打开；若仍失败，打开“软件安装”检查安装状态。"
        }
        return nil
    }
}

struct BeginnerRecoveryRepairPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let preview: V014RecoveryRepairPreview
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                "修复预览",
                systemImage: "wrench.and.screwdriver.fill"
            )
            .font(.title2.bold())

            Text(
                "只会处理下面 \(preview.totalCount) 个已存在的恢复点。不会为其他配置、历史或中转创建新的恢复点。"
            )
            .foregroundStyle(.secondary)

            previewRow(
                title: "将处理",
                detail: preview.operationSummary,
                icon: "checkmark.circle.fill",
                color: .blue
            )
            previewRow(
                title: "不会处理",
                detail: "没有恢复点的配置、其他历史会话、网络、认证、额度或兼容问题",
                icon: "hand.raised.fill",
                color: .secondary
            )
            previewRow(
                title: "失败保护",
                detail: preview.protectsNewSessions
                    ? "保护操作后新增会话；首个失败即停止，只回滚本次受影响内容并保留未完成记录"
                    : "首个失败即停止；只回滚本次受影响内容，并保留仍需恢复的记录",
                icon: "shield.checkered",
                color: .orange
            )
            previewRow(
                title: "验证费用",
                detail: "修复提交前最多发送一次基础检测和一次真实任务验证请求，可能产生API费用",
                icon: "creditcard.fill",
                color: .secondary
            )

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("确认只修复这些恢复点") {
                    let fingerprint = preview.fingerprint
                    dismiss()
                    onConfirm(fingerprint)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func previewRow(
        title: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum CapabilityOptionHelp {
    static func reasoning(_ value: ReasoningEffort) -> String {
        switch value {
        case .automatic:
            return "沿用模型默认强度；模型升级时也跟随默认值。"
        case .low:
            return "更快、推理用量更少，适合简单任务。"
        case .medium:
            return "速度与分析深度平衡。"
        case .high:
            return "更深入，通常更慢并使用更多推理额度。"
        case .xhigh:
            return "超高强度；仅支持该档的模型生效。"
        case .max:
            return "质量优先的最大强度；耗时和用量通常最高。"
        case .ultra:
            return "Codex扩展极限档；仅在当前模型和Codex合同支持时使用。"
        }
    }

    static func serviceTier(
        _ value: ProviderServiceTierKind
    ) -> String {
        switch value {
        case .inherit:
            return "保持原设置；不写速度档，也不改Codex Fast功能开关。"
        case .followCodex:
            return "移除助手固定的速度档和Fast功能值；以后由Codex Desktop的Fast开关控制。"
        case .standard:
            return "Standard处理队列；自动关闭Codex Fast功能。"
        case .fast:
            return "发送 service_tier=fast；自动开启Codex Fast功能，可能产生额外费用。"
        case .flex:
            return "Flex低优先级低成本队列；自动关闭Codex Fast功能，繁忙时可能暂时不可用。"
        case .providerSpecific:
            return "只写Provider文档明确给出的自定义值；不改Codex Fast功能开关。"
        }
    }

    static func remoteCompaction(
        _ value: ProviderRemoteCompactionSetting
    ) -> String {
        switch value {
        case .preserve:
            return "不改在线压缩能力和Provider兼容名称。"
        case .enabled:
            return "自动把内部兼容名称设为OpenAI并请求服务端在线压缩；Responses和remote_compaction_v2仍须可用，真实远程事件后才算已验证。"
        case .disabled:
            return "不申请在线压缩，并移除由OpenAI兼容名称触发的该路径；本地自动压缩阈值不受影响。"
        }
    }

    static func webSearch(
        _ value: ProviderWebSearchSetting
    ) -> String {
        switch value {
        case .preserve:
            return "不改Web Search设置。"
        case .disabled:
            return "禁止Codex使用内置Web Search。"
        case .cached:
            return "允许使用缓存搜索结果；新鲜度可能低于Live。"
        case .live:
            return "允许实时联网搜索和来源引用；可能产生搜索及API费用。"
        }
    }

    static func verbosity(
        _ value: ProviderModelVerbositySetting
    ) -> String {
        switch value {
        case .preserve:
            return "保持当前回答详略；不改变思考强度。"
        case .low:
            return "短回答，结论优先；可能减少输出Token、耗时和费用；不改变思考强度。"
        case .medium:
            return "长度和细节平衡；输出Token、耗时和费用通常居中；不改变思考强度。"
        case .high:
            return "更详细，含更多说明和示例；可能增加输出Token、耗时和费用；不改变思考强度。"
        }
    }

    static func imageInput(
        _ value: ProviderOptionalBooleanSetting
    ) -> String {
        switch value {
        case .preserve:
            return "不改Provider图片能力声明。"
        case .enabled:
            return "声明模型接受图片；真实支持仍需合成图片探针。"
        case .disabled:
            return "声明该轨不使用图片输入；不影响文本请求。"
        }
    }

    static func responseStorage(
        _ value: ProviderOptionalBooleanSetting
    ) -> String {
        switch value {
        case .preserve:
            return "不改Provider响应留存策略；不影响本机聊天记录，也不会删除历史；最终行为受Provider合同约束。"
        case .enabled:
            return "要求Provider不保存响应；不影响本机聊天记录，也不会删除历史；最终行为受Provider合同约束。"
        case .disabled:
            return "允许Provider按默认策略保存响应；不影响本机聊天记录，也不会删除历史；最终行为受Provider合同约束。"
        }
    }

    static func responseStorageDisplayName(
        _ value: ProviderOptionalBooleanSetting
    ) -> String {
        switch value {
        case .preserve:
            return "保持原设置"
        case .enabled:
            return "要求不保存"
        case .disabled:
            return "允许默认保存"
        }
    }

    static func configurationSummary(
        _ values: [String]
    ) -> [String] {
        var output: [String] = []
        var emittedSpeedTier = false
        let speedTier = values.first {
            $0.hasPrefix("速度档：")
        }
        let fastMode = values.first {
            $0.hasPrefix("Fast开关：")
        }

        for value in values {
            if value.hasPrefix("速度档：") {
                guard !emittedSpeedTier else { continue }
                output.append(
                    mergedSpeedTierSummary(
                        speedTier: speedTier,
                        fastMode: fastMode
                    )
                )
                emittedSpeedTier = true
                continue
            }
            if value.hasPrefix("Fast开关：") {
                guard !emittedSpeedTier else { continue }
                output.append(
                    mergedSpeedTierSummary(
                        speedTier: speedTier,
                        fastMode: fastMode
                    )
                )
                emittedSpeedTier = true
                continue
            }
            if value.hasPrefix("回答详略：") {
                output.append(
                    "回答详略：\(verbositySummary(value))"
                )
                continue
            }
            if value.hasPrefix("响应存储：") {
                output.append(
                    "Provider响应留存：\(responseStorageSummary(value))"
                )
                continue
            }
            output.append(value)
        }
        return output
    }

    private static func mergedSpeedTierSummary(
        speedTier: String?,
        fastMode: String?
    ) -> String {
        let rawTier = speedTier.map {
            String($0.dropFirst("速度档：".count))
        } ?? "保持原设置"
        let tier: String
        switch rawTier.lowercased() {
        case "followcodex":
            tier = "跟随 Codex Fast 开关"
        case "fast":
            tier = "Fast"
        case "standard":
            tier = "Standard"
        case "flex":
            tier = "Flex"
        default:
            tier = rawTier
        }
        let fastState: String
        if let fastMode {
            let rawFastState = String(
                fastMode.dropFirst("Fast开关：".count)
            )
            switch (tier, rawFastState) {
            case ("Fast", "开启"):
                fastState = "自动开启"
            case ("Standard", "关闭"), ("Flex", "关闭"):
                fastState = "自动关闭"
            default:
                fastState = rawFastState
            }
        } else {
            switch tier.lowercased() {
            case "fast":
                fastState = "自动开启"
            case "standard", "flex":
                fastState = "自动关闭"
            default:
                fastState = "保持原设置"
            }
        }
        return "速度档：\(tier)（Codex Fast功能\(fastState)）"
    }

    private static func verbositySummary(
        _ value: String
    ) -> String {
        switch String(value.dropFirst("回答详略：".count)).lowercased() {
        case "low":
            return "低（短回答）"
        case "medium":
            return "中（平衡）"
        case "high":
            return "高（详细）"
        default:
            return "保持原设置"
        }
    }

    private static func responseStorageSummary(
        _ value: String
    ) -> String {
        switch String(value.dropFirst("响应存储：".count)) {
        case "禁用":
            return "要求不保存"
        case "允许":
            return "允许默认保存"
        default:
            return "保持原设置"
        }
    }
}

func beginnerEndpointHost(
    _ value: String?
) -> String? {
    guard let value = value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    let candidate = value.contains("://")
        ? value : "https://\(value)"
    guard let components = URLComponents(string: candidate),
          components.user == nil,
          components.password == nil,
          let host = components.host,
          !host.isEmpty else {
        return nil
    }
    return components.port.map {
        "\(host.lowercased()):\($0)"
    } ?? host.lowercased()
}

enum BeginnerConnectionHealthCopy {
    static func presentation(
        for observation: V011ConnectionHealthObservation?
    ) -> V013FailurePresentation? {
        V013FailurePresentation.connection(observation)
    }

    static func title(
        for observation: V011ConnectionHealthObservation?
    ) -> String? {
        presentation(for: observation)?.conclusion
    }

    static func detail(
        for observation: V011ConnectionHealthObservation?
    ) -> String? {
        presentation(for: observation)?.explanation
    }

    static func actionTitle(
        for observation: V011ConnectionHealthObservation?
    ) -> String? {
        presentation(for: observation)?.primaryAction.title
    }
}

struct BeginnerFailureEvidenceDisclosure: View {
    let presentation: V013FailurePresentation

    var body: some View {
        DisclosureGroup("查看验证证据") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(
                    Array(presentation.evidence.enumerated()),
                    id: \.offset
                ) { _, item in
                    Text(item)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 5)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension ConfigWorkspaceModel {
    func refreshConfigurationHealth(
        using accessModel: V011AccessModel
    ) {
        refreshConfigurationHealth(
            expectedProviderID:
                accessModel.currentProviderID,
            expectedCodexContractID:
                accessModel.currentCodexContractID,
            expectedProfileID:
                accessModel.currentRelayProfileID,
            expectedCapabilityProfileSHA256:
                accessModel
                    .currentCapabilityProfileSHA256,
            providerProbeReceipts:
                accessModel.providerProbeReceipts
        )
    }
}
