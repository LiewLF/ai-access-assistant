// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

enum CodexWorkSafetyState: String, Equatable {
    case notRunning
    case userConfirmedSafe
    case unknown
}

struct CodexWorkSafetyDecision: Equatable {
    let state: CodexWorkSafetyState
    let allowsQuit: Bool
    let message: String
}

enum CodexWorkSafetyGate {
    static func evaluate(
        isRunning: Bool,
        userConfirmedSavedWork: Bool
    ) -> CodexWorkSafetyDecision {
        if !isRunning {
            return CodexWorkSafetyDecision(
                state: .notRunning,
                allowsQuit: true,
                message: "Codex未运行，无需关闭"
            )
        }
        if userConfirmedSavedWork {
            return CodexWorkSafetyDecision(
                state: .userConfirmedSafe,
                allowsQuit: true,
                message: "用户已确认工作保存，可正常请求退出"
            )
        }
        return CodexWorkSafetyDecision(
            state: .unknown,
            allowsQuit: false,
            message: "无法证明Codex没有活跃Turn或未保存工作"
        )
    }
}

enum AccessRouteKind: String, CaseIterable, Codable, Identifiable {
    case managed = "AI接入助手托管"
    case codexPlusPlus = "通过 Codex++ 接入"
    case ccSwitch = "通过 CC Switch 接入"
    case manual = "手动配置并由助手检查"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .managed: return "助手建立恢复点、写入、启动、验证；推荐"
        case .codexPlusPlus: return "助手先备份，再打开 Codex++ 导入并检查结果"
        case .ccSwitch: return "助手先备份，再检查 CC Switch 写入并修正思考强度"
        case .manual: return "显示精确配置块，保存后由助手解析和验证"
        }
    }

    var requiresExternalTool: Bool {
        self == .codexPlusPlus || self == .ccSwitch
    }
}

enum AccessRouteCatalog {
    static func available(for agent: DesktopAgent) -> [AccessRouteKind] {
        guard agent == .codexDesktop else { return [] }
        guard CodexApplicationLocator.applicationURL() != nil else {
            return []
        }
        var routes: [AccessRouteKind] = [.managed]
        if let url = URL(string: "codexplusplus://v1/import/provider"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
           PlatformEvidenceCatalog.record(for: .codexPlusPlus)?
            .allowsAdapterUse() == true {
            routes.append(.codexPlusPlus)
        }
        if let url = URL(string: "ccswitch://v1/import"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
           PlatformEvidenceCatalog.record(for: .ccSwitch)?
            .allowsAdapterUse() == true {
            routes.append(.ccSwitch)
        }
        routes.append(.manual)
        return routes
    }
}
