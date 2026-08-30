// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

struct OfficialBaseline: Codable, Equatable {
    let codexHomePath: String
    let snapshot: SnapshotManifest
    let configExisted: Bool
    let authExisted: Bool
    let configHash: String?
    let authHash: String?
    let createdAt: Date
}

enum CodexRuntimeMode: String, Codable {
    case official = "官方"
    case relay = "中转"
    case external = "未知外部状态"
}

enum OfficialBaselineTrust: String, Codable {
    case missing
    case legacyCandidate
    case candidate
    case verified
}

enum RealSwitchPhase: String, Codable, CaseIterable {
    case preflight = "安全检查"
    case snapshot = "保存恢复点"
    case write = "原子写入"
    case launch = "启动 Codex"
    case validate = "真实连接验证"
    case committed = "完成"
    case rolledBack = "已回滚"
    case manualRecovery = "需要人工恢复"
}

struct RealSwitchTransaction: Identifiable, Codable, Equatable {
    let id: String
    let fromMode: CodexRuntimeMode
    let toMode: CodexRuntimeMode
    var phase: RealSwitchPhase
    let startedAt: Date
    var completedAt: Date?
    var message: String
    let beforeConfigHash: String?
    var afterConfigHash: String?
}

struct CodexSwitchRecoveryPoint: Equatable {
    let configData: Data?
    let configHash: String?
    let authHash: String?
    let state: CodexStateStore.State
}

struct ExistingProviderImportReport: Equatable {
    let providerID: String
    let displayName: String
    let configHashBefore: String
    let configHashAfter: String
    let byteCount: Int
    let legacyBearerFieldPresent: Bool
    let environmentKeyFieldPresent: Bool
    let commandAuthenticationPresent: Bool
    let warnings: [String]

    var targetConfigurationUnchanged: Bool {
        configHashBefore == configHashAfter
    }
}

struct ExistingProviderImportResult: Equatable {
    let profile: CodexRelayProfile
    let report: ExistingProviderImportReport
}

enum ExternalDriftChoice: String, CaseIterable, Identifiable {
    case saveRelay = "保存为当前中转档"
    case restoreKnown = "恢复已知配置"
    case cancel = "取消"
    var id: String { rawValue }
}

struct CodexConfigurationPlan: Equatable {
    let original: String
    let proposed: String
    let managedChanges: [(String, String, String)]
    let manualBlock: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.original == rhs.original && lhs.proposed == rhs.proposed
            && lhs.managedChanges.map { [$0.0, $0.1, $0.2] } == rhs.managedChanges.map { [$0.0, $0.1, $0.2] }
            && lhs.manualBlock == rhs.manualBlock
    }
}

enum CodexControlError: LocalizedError {
    case unsafeCodexHome
    case symbolicLink(String)
    case malformedTOML(Int)
    case duplicateManagedKey(String)
    case invalidProfile
    case baselineMissing
    case externalDrift
    case compareAndSwapFailed
    case manualConfigurationMismatch
    case codexStillRunning
    case configurationWritersRunning([String])
    case codexApplicationMissing
    case atomicWriteFailed
    case injectedFailure(RealSwitchPhase)
    case secretStore(OSStatus)
    case credentialBridge(String)
    case missingSecret
    case responseTooLarge
    case badResponse(Int, String)
    case invalidResponseBody(String)
    case unsupportedStateSchema(Int)
    case officialValidationEvidenceMissing
    case officialBaselineContainsRelay
    case officialBaselineUnverified
    case testKeychainAccessBlocked
    case legacyWriterDisabled

    var errorDescription: String? {
        switch self {
        case .unsafeCodexHome: return "CODEX_HOME 不在当前用户目录，已阻止"
        case let .symbolicLink(path): return "白名单文件是符号链接，已阻止：\(path)"
        case let .malformedTOML(line): return "config.toml 第 \(line) 行结构无法安全解析"
        case let .duplicateManagedKey(key): return "config.toml 重复定义托管字段：\(key)"
        case .invalidProfile: return "中转配置缺少必填字段"
        case .baselineMissing: return "尚未建立官方配置基线"
        case .externalDrift: return "检测到外部配置改动，请先选择保存、恢复或取消"
        case .compareAndSwapFailed: return "配置在提交前被其他程序修改，本次切换未写入"
        case .manualConfigurationMismatch: return "手动配置尚未匹配目标值；请核对供应商段、默认模型、Base URL和命令认证"
        case .codexStillRunning: return "Codex 仍在运行；未强制退出，也未写入配置"
        case let .configurationWritersRunning(names):
            return "请先正常退出其他配置写入工具：\(names.joined(separator: "、"))"
        case .codexApplicationMissing: return "未找到 Codex Desktop 应用"
        case .atomicWriteFailed: return "配置原子写入失败，已恢复"
        case let .injectedFailure(phase): return "切换在“\(phase.rawValue)”失败，已回滚"
        case let .secretStore(status): return "中转密钥 Keychain 操作失败：\(status)"
        case let .credentialBridge(message):
            return "中转凭据桥失败：\(message)"
        case .missingSecret: return "助手 Keychain 中没有该中转密钥"
        case .responseTooLarge: return "连接测试响应超过 2 MB，已停止读取"
        case let .badResponse(code, message): return "连接测试失败 HTTP \(code)：\(message)"
        case let .invalidResponseBody(detail):
            return "接口返回200，但正文不是可识别的模型响应（\(detail)）"
        case .officialValidationEvidenceMissing:
            return "官方验证证据不足；必须由当前官方Codex完成真实请求"
        case .officialBaselineContainsRelay:
            return "旧官方基线仍包含中转Provider。Codex未关闭、配置未写入；请先只读接管当前中转，再在“官方覆盖层候选”选择“当前配置移除Provider”"
        case .officialBaselineUnverified:
            return "旧官方基线尚未验证；请先选择官方候选，再执行首次真实切回"
        case .testKeychainAccessBlocked:
            return "自动测试禁止访问真实Keychain"
        case .legacyWriterDisabled:
            return "旧配置控制面只允许生成预览；真实切换必须进入FableSwitchCore"
        case let .unsupportedStateSchema(version):
            return "助手状态Schema版本\(version)高于当前支持版本，已进入只读保护"
        }
    }
}
