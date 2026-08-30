import Foundation

enum RelayCatalog {
    static let customID = "custom"

    static let providers: [RelayProvider] = [
        RelayProvider(
            id: "siliconflow",
            name: "SiliconFlow",
            homepageURL: "https://siliconflow.cn",
            documentationURL: "https://docs.siliconflow.cn/cn/userguide/quickstart",
            defaultBaseURL: "https://api.siliconflow.cn/v1",
            verifiedProtocols: [.chatCompletions],
            region: "国内",
            lastVerified: "2026-07-18",
            notes: "官方快速开始文档。与桌面 Agent 的自动导入组合尚未核验，只提供指导。"
        ),
        RelayProvider(
            id: "openrouter",
            name: "OpenRouter",
            homepageURL: "https://openrouter.ai",
            documentationURL: "https://openrouter.ai/docs/quickstart",
            defaultBaseURL: "https://openrouter.ai/api/v1",
            verifiedProtocols: [.chatCompletions],
            region: "国外",
            lastVerified: "2026-07-18",
            notes: "官方快速开始文档。与 Codex++/桌面 Agent 的自动导入组合尚未核验。"
        ),
        RelayProvider(
            id: "azure-openai",
            name: "Azure OpenAI",
            homepageURL: "https://azure.microsoft.com/products/ai-services/openai-service",
            documentationURL: "https://learn.microsoft.com/azure/ai-foundry/openai/quickstart",
            defaultBaseURL: nil,
            verifiedProtocols: [.responses, .chatCompletions],
            region: "国外",
            lastVerified: "2026-07-18",
            notes: "Endpoint 随 Azure 资源变化，禁止预填固定 Base URL。"
        ),
    ]

    static func provider(id: String) -> RelayProvider? {
        providers.first(where: { $0.id == id })
    }
}

enum CompatibilityCatalog {
    static func record(
        relayID: String,
        manager: AdapterTarget,
        method: ConfigurationMethod = .toolImport,
        tool: ConfigurationTool? = nil,
        agent: DesktopAgent
    ) -> CompatibilityRecord {
        if method == .managed, agent == .codexDesktop {
            return CompatibilityRecord(
                id: "\(relayID)-managed-codexdesktop-simulation",
                relayID: relayID,
                manager: .manual,
                method: method,
                tool: nil,
                agent: agent,
                protocols: RelayCatalog.provider(id: relayID)?.verifiedProtocols ?? [],
                level: .simulation,
                configurationMethod: "0.6.0 只建立加密配置档并模拟事务，不读取或写入真实 Codex 配置",
                officialModeImpact: "零真实写入；0.6.1 通过白名单验收后才开放切换",
                recoveryMethod: "模拟数据可清除；不会影响官方模式",
                evidence: "P5.1 安全托管设计与本地模拟事务测试",
                verifiedAt: "2026-07-18"
            )
        }
        if method == .managed {
            return CompatibilityRecord(
                id: "\(relayID)-managed-\(agent.rawValue)-blocked",
                relayID: relayID,
                manager: .manual,
                method: method,
                tool: nil,
                agent: agent,
                protocols: [],
                level: .blocked,
                configurationMethod: "该桌面 Agent 尚无安全托管写入面证据",
                officialModeImpact: "未知，因此阻止",
                recoveryMethod: "未执行写入，无需恢复",
                evidence: "P5.1 fail-closed 规则",
                verifiedAt: "2026-07-18"
            )
        }
        if method == .guidance {
            return CompatibilityRecord(
                id: "\(relayID)-guidance-\(agent.rawValue)",
                relayID: relayID,
                manager: .manual,
                method: method,
                tool: nil,
                agent: agent,
                protocols: RelayCatalog.provider(id: relayID)?.verifiedProtocols ?? [],
                level: .guidance,
                configurationMethod: "只生成核对清单，不自动写入",
                officialModeImpact: "零写入",
                recoveryMethod: "无需恢复",
                evidence: "用户资料与目标平台公开证据",
                verifiedAt: "2026-07-18"
            )
        }
        if manager == .codexPlusPlus, agent == .codexDesktop {
            let supportedProtocols = RelayCatalog.provider(id: relayID)?.verifiedProtocols
                ?? (relayID == RelayCatalog.customID ? RelayWireProtocol.allCases : [])
            return CompatibilityRecord(
                id: "\(relayID)-codexpp-codexdesktop",
                relayID: relayID,
                manager: manager,
                method: method,
                tool: tool ?? .codexPlusPlus,
                agent: agent,
                protocols: supportedProtocols,
                level: .export,
                configurationMethod: "Codex++ 官方深链接；目标工具二次确认",
                officialModeImpact: "导入只新增供应商；之后激活纯 API 会切换 Codex config.toml/auth.json",
                recoveryMethod: "按导出检查单在 Codex++ 切回原官方供应商并验证官方会话",
                evidence: "用户确认的中转字段 + Codex++ 285f40e 导入协议 + OpenAI Codex 配置参考",
                verifiedAt: "2026-07-18"
            )
        }
        if manager == .cherryStudio, agent == .cherryStudio,
           let provider = RelayCatalog.provider(id: relayID), !provider.verifiedProtocols.isEmpty {
            return CompatibilityRecord(
                id: "\(relayID)-cherrystudio-client",
                relayID: relayID,
                manager: manager,
                method: method,
                tool: nil,
                agent: agent,
                protocols: provider.verifiedProtocols,
                level: .export,
                configurationMethod: "Cherry Studio v1 深链接只打开并预填新增供应商表单；用户核对后保存",
                officialModeImpact: "只配置 Cherry Studio 自己，不触碰 Codex Desktop 或 Claude Desktop",
                recoveryMethod: "未保存时关闭表单；保存后只移除新增的 Cherry Studio 供应商",
                evidence: "Cherry Studio 65e55c5 providersImport 源码与测试 + 中转站协议文档",
                verifiedAt: "2026-07-18"
            )
        }
        if agent == .claudeDesktop {
            return CompatibilityRecord(
                id: "\(relayID)-\(manager.rawValue)-claude-desktop",
                relayID: relayID,
                manager: manager,
                method: method,
                tool: tool,
                agent: agent,
                protocols: [],
                level: .blocked,
                configurationMethod: "Claude Desktop 官方公开能力未提供任意中转 Base URL；MCP 不是模型供应商配置",
                officialModeImpact: "未知，因此保护 Claude Pro 登录并阻止自动导入",
                recoveryMethod: "未执行写入，无需恢复",
                evidence: "Claude Desktop 官方安装与本地 MCP 文档，核验 2026-07-18",
                verifiedAt: "2026-07-18"
            )
        }
        if manager == .manual {
            return CompatibilityRecord(
                id: "\(relayID)-manual-\(agent.rawValue)",
                relayID: relayID,
                manager: manager,
                method: method,
                tool: nil,
                agent: agent,
                protocols: RelayCatalog.provider(id: relayID)?.verifiedProtocols ?? RelayWireProtocol.allCases,
                level: .guidance,
                configurationMethod: "只生成操作清单；不自动写入",
                officialModeImpact: "软件不修改官方配置",
                recoveryMethod: "不执行写入，无需恢复",
                evidence: "中转文档；目标 Agent 写入面未核验",
                verifiedAt: "2026-07-18"
            )
        }
        return CompatibilityRecord(
            id: "\(relayID)-\(manager.rawValue)-\(agent.rawValue)",
            relayID: relayID,
            manager: manager,
            method: method,
            tool: tool,
            agent: agent,
            protocols: RelayCatalog.provider(id: relayID)?.verifiedProtocols ?? [],
            level: .blocked,
            configurationMethod: "组合证据不足，只显示字段和风险",
            officialModeImpact: "未知；因此禁止自动导入",
            recoveryMethod: "未核实前不执行写入",
            evidence: "缺少完整上游导入格式或官方模式影响证据",
            verifiedAt: "2026-07-18"
        )
    }
}
