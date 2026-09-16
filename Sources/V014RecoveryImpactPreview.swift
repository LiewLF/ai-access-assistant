import Foundation

/// Projects already-read journal metadata only; never opens snapshots or credentials.
enum V014RecoveryImpactPreview {
    static func operations(
        switches: [V011SwitchJournal],
        adoptions: [V011AdoptionJournal],
        deletions: [V011RelayDeletionJournal],
        configurationPreviews: [String: V014RecoveryFieldPreview] = [:]
    ) -> [V014RecoveryOperationImpact] {
        // Match the existing recovery service's operation order.
        adoptions.enumerated().map { adoption($0.element, index: $0.offset + 1) }
            + deletions.enumerated().map { deletion($0.element, index: $0.offset + 1) }
            + switches.enumerated().map { switching($0.element, index: $0.offset + 1,
                fields: configurationPreviews[$0.element.id]) }
    }

    private static func adoption(_ journal: V011AdoptionJournal, index: Int)
        -> V014RecoveryOperationImpact {
        V014RecoveryOperationImpact(
            title: "中转接管恢复点 \(index)",
            direction: "撤销这次未完成接管，恢复接管前的助手记录。",
            affected: [
                previousObject("助手受管档案", existed: journal.stateExisted),
                previousObject("会话来源账本", existed: journal.originLedgerExisted),
                previousObject("助手迁移记录", existed: journal.migrationManifestExisted),
                journal.previousCredentialExisted
                    ? "本次接管的凭据：从加密恢复点恢复原密钥"
                    : "本次接管的凭据：删除本次新增密钥"
            ],
            preserved: "Codex 当前配置只核对，不改写；原始聊天正文、Skills、Plugins 和 MCP 文件不处理。",
            limitation: "尚未解密恢复点；原密钥内容与档案字段不在此预览中显示。恢复点不可用时原执行器会停止。"
        )
    }

    private static func deletion(_ journal: V011RelayDeletionJournal, index: Int)
        -> V014RecoveryOperationImpact {
        V014RecoveryOperationImpact(
            title: "中转删除恢复点 \(index)",
            direction: journal.credentialExisted
                ? "执行前核对密钥是否仍存在：仍在则恢复删除前档案；已删除则可能完成原删除。"
                : "执行前核对档案与凭据状态，决定保留原档案或完成原删除。",
            affected: ["本次删除涉及的助手受管中转档案及其恢复记录"],
            preserved: "当前 Codex 配置、原始聊天、Skills、Plugins 和 MCP 文件不处理；不会凭空找回已删除的密钥。",
            limitation: "尚未读取实时凭据或加密档案，不能仅凭恢复记录确定最终方向；状态冲突时停止。"
        )
    }

    private static func switching(_ journal: V011SwitchJournal, index: Int,
        fields: V014RecoveryFieldPreview?)
        -> V014RecoveryOperationImpact {
        let configurationOnly = journal.configTransactionID != nil
        var affected = [
            "Codex 受管配置：可能完成原切换目标，也可能恢复切换前设置；会关闭配置写入程序并重新打开 Codex"
        ]
        if journal.stateCASManaged == true {
            affected.append("助手受管状态：按本次事务绑定的状态核对后更新或恢复")
        } else {
            affected.append("助手受管状态由执行前核对决定；旧记录缺少恢复绑定时，不会按旧快照覆盖")
        }
        if configurationOnly {
            affected.append("本次配置事务和关联的助手事务记录")
        } else {
            affected.append("旧式会话恢复可能处理会话索引、来源标记和来源账本；不能视为历史零改动")
        }
        var limitation = "这里只读到恢复记录；精确配置字段差异和恢复值尚未读取，不能当作字段级预览。"
        if let fields, fields.isAvailable {
            affected += fields.fields.map { "若执行配置回退：" + $0 }
            limitation = fields.fields.isEmpty && fields.undisplayedFieldCount == 0
                ? "本次读取时，配置回退路径不需要改变字段。"
                : "以上字段差异只对应回退路径；中转以匿名序号区分，字段值不展示。"
            if fields.undisplayedFieldCount > 0 {
                limitation += "另有\(fields.undisplayedFieldCount)项未识别字段变化未显示名称，不能视为完整字段清单。"
            }
            limitation += "若安全完成原目标，则不按此回退清单执行；确认后仍会重新核对。"
        }
        return V014RecoveryOperationImpact(
            title: "接入切换恢复点 \(index)",
            direction: "先核对能否安全完成原目标；不满足时按已有恢复边界回退，不预先承诺恢复方向。",
            affected: affected,
            preserved: configurationOnly
                ? "本配置事务不回写原始会话；Skills、Plugins、MCP 文件及其他未受管资产不处理。"
                : "保护操作后新增会话；Skills、Plugins、MCP 文件及其他未受管资产不处理。",
            limitation: limitation
        )
    }

    private static func previousObject(_ name: String, existed: Bool) -> String {
        existed ? "\(name)：恢复此前记录" : "\(name)：移除本次新建记录"
    }
}
