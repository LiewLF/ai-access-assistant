import Foundation

struct SafetyAuditResult {
    let allowed: Bool
    let reasons: [String]
    let protectedSurfaces: [String]
    let allowedSurfaces: [String]
}

struct SafetyPolicy {
    let manager: AdapterTarget
    let agent: DesktopAgent
    let protectedSurfaces: [String]
    let allowedSurfacePrefixes: [String]
    let recoveryMethod: String

    func evaluate(proposedWrites: [String]) -> SafetyAuditResult {
        var reasons: [String] = []
        for write in proposedWrites {
            let normalized = write.lowercased()
            if protectedSurfaces.contains(where: { surface in
                let needle = surface.lowercased()
                return normalized.contains(needle)
                    || normalized.contains(needle.replacingOccurrences(of: "~/", with: ""))
            }) {
                reasons.append("写入命中保护面：\(write)")
                continue
            }
            if !allowedSurfacePrefixes.contains(where: { surface in
                let needle = surface.lowercased()
                return normalized.hasPrefix(needle)
                    || normalized.contains(needle.replacingOccurrences(of: "~/", with: "/"))
            }) {
                reasons.append("写入位置不在允许清单：\(write)")
            }
        }
        return SafetyAuditResult(
            allowed: reasons.isEmpty,
            reasons: reasons,
            protectedSurfaces: protectedSurfaces,
            allowedSurfaces: allowedSurfacePrefixes
        )
    }
}

enum SafetyPolicies {
    static func policy(manager: AdapterTarget, agent: DesktopAgent) -> SafetyPolicy {
        var protected = [
            "~/.codex/auth.json",
            "~/.codex/config.toml",
            "keychain",
            "认证",
            "database",
            "数据库",
        ]
        if agent == .claudeDesktop {
            protected += [
                "~/.claude.json",
                "~/library/application support/claude",
                "claude pro login",
            ]
        }
        if agent == .cherryStudio || manager == .cherryStudio {
            protected += [
                "cherry studio database",
                "cherry studio 数据库",
                "~/library/application support/cherrystudio",
            ]
        }
        if manager == .codexPlusPlus {
            protected += ["codexplusplus.sqlite", "codex++ database"]
        }
        if manager == .ccSwitch {
            protected += ["cc-switch database", "cc switch database"]
        }
        return SafetyPolicy(
            manager: manager,
            agent: agent,
            protectedSurfaces: protected,
            allowedSurfacePrefixes: [
                "~/desktop/ai接入助手导出",
                "/users/example/desktop/ai接入助手导出",
                "codexplusplus://v1/import/provider",
            ],
            recoveryMethod: "关闭中转供应商并选择原官方供应商；保留官方认证文件和官方登录。"
        )
    }
}
