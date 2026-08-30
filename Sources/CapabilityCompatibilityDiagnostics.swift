// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

enum CapabilityCompatibilityKind:
    String, Codable, CaseIterable, Sendable {
    case codex = "Codex"
    case skills = "Skills"
    case plugins = "Plugins"
    case mcp = "MCP"
    case hooks = "Hooks"

    var stableID: String {
        rawValue.lowercased()
    }
}

enum CapabilityCompatibilityVerdict:
    String, Codable, Sendable {
    case compatible = "兼容证据通过"
    case attention = "需核对"
    case unverified = "存在，未验证"
    case unavailable = "核对不完整"
    case notDetected = "未发现"
    case blocked = "不兼容"
}

enum CapabilityCompatibilityEvidenceSource:
    String, Codable, Sendable {
    case freshProbe = "本次隔离验证"
    case cachedProbe = "本机缓存验证"
    case bundledContract = "内置版本合同"
    case localSnapshot = "本机只读快照"
    case failedCheck = "本次失败检查"
    case missing = "无证据"
}

enum CapabilityCompatibilityFreshness:
    String, Codable, Sendable {
    case fresh = "新鲜"
    case stale = "已过期"
    case versionBound = "随版本绑定"
    case unknown = "时间未知"
}

struct CapabilityCompatibilityCodexEvidence:
    Codable, Equatable, Sendable {
    let verdict: CapabilityCompatibilityVerdict
    let source: CapabilityCompatibilityEvidenceSource
    let observedAt: Date?
    let summary: String

    static let unverified = CapabilityCompatibilityCodexEvidence(
        verdict: .unverified,
        source: .missing,
        observedAt: nil,
        summary: "尚未读取当前Codex兼容证据"
    )
}

struct CapabilityCompatibilityEvidenceItem:
    Identifiable, Codable, Equatable, Sendable {
    var id: String { kind.stableID }

    let kind: CapabilityCompatibilityKind
    let verdict: CapabilityCompatibilityVerdict
    let source: CapabilityCompatibilityEvidenceSource
    let freshness: CapabilityCompatibilityFreshness
    let observedAt: Date?
    let detail: String
}

struct CapabilityCompatibilitySideEffects:
    Codable, Equatable, Sendable {
    let networkRequests: Int
    let processLaunches: Int
    let configurationWrites: Int
    let extensionWrites: Int

    static let none = CapabilityCompatibilitySideEffects(
        networkRequests: 0,
        processLaunches: 0,
        configurationWrites: 0,
        extensionWrites: 0
    )
}

struct CapabilityCompatibilityReport:
    Codable, Equatable, Sendable {
    let generatedAt: Date
    let items: [CapabilityCompatibilityEvidenceItem]
    let sideEffects: CapabilityCompatibilitySideEffects
}

enum CapabilityCompatibilityPrimaryAction:
    String, Codable, Equatable, Sendable {
    case refreshCodexCompatibility
    case refreshLocalSnapshot
    case openSkills
    case openPlugins
    case openCodexSettings

    var title: String {
        switch self {
        case .refreshCodexCompatibility:
            return "重新核对Codex"
        case .refreshLocalSnapshot:
            return "重新只读核对"
        case .openSkills:
            return "打开Codex Skills"
        case .openPlugins:
            return "打开Codex Plugins"
        case .openCodexSettings:
            return "打开Codex设置"
        }
    }
}

struct CapabilityCompatibilityPresentation:
    Identifiable, Equatable, Sendable {
    var id: String { kind.stableID }

    let kind: CapabilityCompatibilityKind
    let conclusion: String
    let primaryAction: CapabilityCompatibilityPrimaryAction?
    let evidence: [String]
}

enum CapabilityCompatibilityPresenter {
    static func presentation(
        for item: CapabilityCompatibilityEvidenceItem
    ) -> CapabilityCompatibilityPresentation {
        CapabilityCompatibilityPresentation(
            kind: item.kind,
            conclusion: conclusion(for: item),
            primaryAction: primaryAction(for: item),
            evidence: [
                "能力：\(item.kind.rawValue)",
                "原始结论：\(item.verdict.rawValue)",
                "证据来源：\(item.source.rawValue)",
                "新鲜度：\(item.freshness.rawValue)",
                "核对时间：\(observedAtText(item.observedAt))",
                "说明：\(item.detail)",
            ]
        )
    }

    private static func conclusion(
        for item: CapabilityCompatibilityEvidenceItem
    ) -> String {
        let name = item.kind.rawValue
        switch item.freshness {
        case .stale:
            return "\(name)证据已过期，当前兼容性需重新核对"
        case .unknown:
            return "\(name)证据时间未知，当前兼容性未确认"
        case .fresh, .versionBound:
            break
        }
        switch item.verdict {
        case .compatible:
            return item.freshness == .versionBound
                ? "\(name)当前版本合同可用"
                : "\(name)当前兼容证据可用"
        case .attention:
            return "\(name)发现需先核对的本机风险"
        case .unverified:
            return "\(name)已发现，但运行兼容性未验证"
        case .unavailable:
            return "\(name)本次没有完整核对，当前状态未确认"
        case .notDetected:
            return "未发现\(name)；不用时无需处理"
        case .blocked:
            return "\(name)当前未通过兼容核对"
        }
    }

    private static func primaryAction(
        for item: CapabilityCompatibilityEvidenceItem
    ) -> CapabilityCompatibilityPrimaryAction? {
        if item.freshness == .stale
            || item.freshness == .unknown {
            return refreshAction(for: item.kind)
        }
        if item.verdict == .unavailable {
            return refreshAction(for: item.kind)
        }
        guard item.verdict != .compatible else { return nil }
        switch item.kind {
        case .codex:
            return .refreshCodexCompatibility
        case .skills:
            return .openSkills
        case .plugins:
            return .openPlugins
        case .mcp, .hooks:
            return .openCodexSettings
        }
    }

    private static func refreshAction(
        for kind: CapabilityCompatibilityKind
    ) -> CapabilityCompatibilityPrimaryAction {
        kind == .codex
            ? .refreshCodexCompatibility
            : .refreshLocalSnapshot
    }

    private static func observedAtText(_ date: Date?) -> String {
        guard let date else { return "未提供" }
        return date.formatted(
            date: .numeric,
            time: .standard
        )
    }
}

enum CapabilityCompatibilityEvaluator {
    static let defaultMaximumAge: TimeInterval = 24 * 60 * 60
    private static let futureClockTolerance: TimeInterval = 5 * 60

    static func evaluate(
        codexEvidence: CapabilityCompatibilityCodexEvidence,
        snapshot: LocalTrustSnapshot,
        now: Date = Date(),
        maximumAge: TimeInterval = defaultMaximumAge
    ) -> CapabilityCompatibilityReport {
        let boundedMaximumAge = max(0, maximumAge)
        let localFreshness = freshness(
            source: .localSnapshot,
            observedAt: snapshot.scannedAt,
            now: now,
            maximumAge: boundedMaximumAge
        )
        let skillArtifacts = snapshot.artifacts.filter {
            $0.kind == .skill
        }
        let pluginArtifacts = snapshot.artifacts.filter {
            $0.kind == .plugin
        }
        let configurationArtifacts = snapshot.artifacts.filter {
            $0.kind == .codexConfiguration
                || $0.kind == .mcpConfiguration
        }

        let items = [
            CapabilityCompatibilityEvidenceItem(
                kind: .codex,
                verdict: codexEvidence.verdict,
                source: codexEvidence.source,
                freshness: freshness(
                    source: codexEvidence.source,
                    observedAt: codexEvidence.observedAt,
                    now: now,
                    maximumAge: boundedMaximumAge
                ),
                observedAt: codexEvidence.observedAt,
                detail: codexEvidence.summary
            ),
            localItem(
                kind: .skills,
                count: skillArtifacts.count,
                riskCount: riskCount(in: skillArtifacts),
                freshness: localFreshness,
                observedAt: snapshot.scannedAt,
                complete: snapshot.coverage.skillsComplete,
                evidenceName: "SKILL.md清单",
                limitation: "文件可读不等于触发和任务结果兼容"
            ),
            localItem(
                kind: .plugins,
                count: pluginArtifacts.count,
                riskCount: riskCount(in: pluginArtifacts),
                freshness: localFreshness,
                observedAt: snapshot.scannedAt,
                complete: snapshot.coverage.plugins,
                evidenceName: "plugin.json清单",
                limitation: "清单存在不等于授权、套餐和运行状态兼容"
            ),
            localItem(
                kind: .mcp,
                count: snapshot.mcpServers.count,
                riskCount: riskCount(in: configurationArtifacts),
                freshness: localFreshness,
                observedAt: snapshot.scannedAt,
                complete: snapshot.coverage.configuration,
                structureFingerprint: structureFingerprint(
                    snapshot.mcpServers.flatMap { entry in
                        ["id:\(entry.serverID)"]
                            + entry.configurationFields.map {
                                "field:\($0)"
                            }
                    }
                ),
                evidenceName: "脱敏服务器ID与字段结构",
                limitation: "配置存在不等于进程、连接和工具兼容"
            ),
            localItem(
                kind: .hooks,
                count: snapshot.hooks.count,
                riskCount: riskCount(in: configurationArtifacts),
                freshness: localFreshness,
                observedAt: snapshot.scannedAt,
                complete: snapshot.coverage.configuration,
                structureFingerprint: structureFingerprint(
                    snapshot.hooks.flatMap { entry in
                        ["id:\(entry.hookID)"]
                            + entry.configurationFields.map {
                                "field:\($0)"
                            }
                    }
                ),
                evidenceName: "脱敏Hook ID与字段结构",
                limitation: "配置存在不等于作用域、触发和执行兼容"
            ),
        ]
        return CapabilityCompatibilityReport(
            generatedAt: now,
            items: items,
            sideEffects: .none
        )
    }

    private static func localItem(
        kind: CapabilityCompatibilityKind,
        count: Int,
        riskCount: Int,
        freshness: CapabilityCompatibilityFreshness,
        observedAt: Date,
        complete: Bool,
        structureFingerprint: String? = nil,
        evidenceName: String,
        limitation: String
    ) -> CapabilityCompatibilityEvidenceItem {
        let verdict: CapabilityCompatibilityVerdict
        if riskCount > 0 {
            verdict = .attention
        } else if !complete {
            verdict = .unavailable
        } else if count > 0 {
            verdict = .unverified
        } else {
            verdict = .notDetected
        }
        let countDetail = count > 0
            ? "发现\(count)项\(evidenceName)"
            : "未发现\(evidenceName)"
        let riskDetail = riskCount > 0
            ? "；其中\(riskCount)项有权限、重名或链接风险"
            : ""
        let coverageDetail = complete
            ? ""
            : "；本次只读核对不完整，未发现不代表不存在"
        let structureDetail = structureFingerprint.map {
            "；结构标识 \($0)"
        } ?? ""
        return CapabilityCompatibilityEvidenceItem(
            kind: kind,
            verdict: verdict,
            source: .localSnapshot,
            freshness: freshness,
            observedAt: observedAt,
            detail: "\(countDetail)\(riskDetail)\(coverageDetail)"
                + "\(structureDetail)；\(limitation)。"
        )
    }

    private static func structureFingerprint(
        _ components: [String]
    ) -> String? {
        guard !components.isEmpty else { return nil }
        let payload = components.sorted().map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(12))
    }

    private static func riskCount(
        in artifacts: [LocalTrustArtifact]
    ) -> Int {
        artifacts.filter {
            $0.symbolicLink
                || $0.writableByGroupOrOthers
                || $0.duplicateName
        }.count
    }

    private static func freshness(
        source: CapabilityCompatibilityEvidenceSource,
        observedAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> CapabilityCompatibilityFreshness {
        if source == .bundledContract {
            return .versionBound
        }
        guard let observedAt else { return .unknown }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureClockTolerance else { return .unknown }
        return age <= maximumAge ? .fresh : .stale
    }
}
