import Foundation

/// Historical transaction results and current request evidence have different scopes.
/// The caller supplies receipts filtered by the existing identity and freshness gate.
enum ConfigurationHealthRuntimeEvidence {
    static func items(
        lastTransaction: RealSwitchTransaction?,
        receipt: ProviderCapabilityProbeReceipt?,
        providerID: String?,
        modelID: String?,
        runtimeDrifted: Bool
    ) -> [ConfigurationHealthItem] {
        let history = item("最近切换事务",
            state: lastTransaction?.phase == .committed ? .passed : .unverified,
            detail: lastTransaction.map {
                "历史记录：\($0.phase.rawValue)：\($0.message)。此记录不代表当前接入可用。"
            } ?? "没有切换事务记录。")
        let request = requestEvidence(receipt: receipt, providerID: providerID,
            modelID: modelID, runtimeDrifted: runtimeDrifted)
        return [history, item("中转最小请求", state: request.state, detail: request.detail)]
    }

    private static func requestEvidence(
        receipt: ProviderCapabilityProbeReceipt?,
        providerID: String?, modelID: String?, runtimeDrifted: Bool
    ) -> (state: ConfigurationHealthState, detail: String) {
        guard let providerID, providerID != "openai" else {
            return (.notEnabled, "当前为官方接入；官方基础连接和真实任务结果请在接入页查看。")
        }
        guard !runtimeDrifted else {
            return (.unverified, "当前配置与已知运行状态不一致，旧最小请求记录不能证明当前接入可用。")
        }
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let receipt, receipt.providerID == providerID,
              receipt.modelID == modelID else {
            return (.unverified, "没有匹配当前中转、模型和版本合同的有效最小请求回执；旧切换记录不能替代。")
        }
        switch receipt.status {
        case .verified:
            return (.passed, "当前中转、模型和版本合同的基础请求回执已通过；这不代表客户端真实工具闭环已验证。")
        case .unknown:
            return (.unverified, "当前最小请求尚无可确认结果；不能根据配置或旧切换记录推断可用。")
        case .requested, .unsupported, .degraded:
            return (.warning, "最近的当前最小请求尚未通过，请核对接入后重新验证；旧成功记录不能覆盖这个结果。")
        }
    }

    private static func item(_ title: String, state: ConfigurationHealthState,
        detail: String) -> ConfigurationHealthItem {
        ConfigurationHealthItem(id: "\(ConfigurationHealthCategory.runtime.rawValue):\(title)",
            category: .runtime, title: title, state: state, detail: detail)
    }
}
