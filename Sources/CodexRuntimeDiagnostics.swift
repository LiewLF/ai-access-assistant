// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

enum CodexApplicationLocator {
    static let bundleIdentifier = "com.openai.codex"

    static func applicationURL() -> URL? {
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return registered
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
        ]
        return candidates.first { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  let info = Bundle(url: url) else { return false }
            return info.bundleIdentifier == bundleIdentifier
        }
    }
}

enum CodexDoctorDiagnosticError: LocalizedError, Equatable {
    case authorizationRequired
    case executableUnavailable
    case unsafeExecutable
    case timedOut
    case outputTooLarge
    case invalidJSON
    case unsupportedSchema(Int)
    case codexHomeMismatch

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "必须先确认Codex官方诊断会只读配置并执行网络连通性检查"
        case .executableUnavailable:
            return "未找到Codex内置诊断程序"
        case .unsafeExecutable:
            return "Codex诊断程序不是安全的普通文件"
        case .timedOut:
            return "Codex官方诊断超过30秒，已停止"
        case .outputTooLarge:
            return "Codex官方诊断输出超过1 MB安全上限"
        case .invalidJSON:
            return "Codex官方诊断未返回可识别的脱敏JSON"
        case .unsupportedSchema(let schema):
            return "Codex官方诊断Schema \(schema)尚未适配"
        case .codexHomeMismatch:
            return "Codex官方诊断报告的CODEX_HOME与目标目录不一致"
        }
    }
}

struct CodexDoctorDiagnostic: Equatable {
    let schemaVersion: Int
    let codexVersion: String?
    let overallStatus: String
    let codexHome: String
    let providerID: String?
    let model: String?
    let appServerStatus: String?
    let authStatus: String?
    let configStatus: String?
    let networkChecksPerformed: Bool
    let reportSHA256: String
    let checks: [CodexDoctorCheckEvidence]

    init(
        schemaVersion: Int,
        codexVersion: String?,
        overallStatus: String,
        codexHome: String,
        providerID: String?,
        model: String?,
        appServerStatus: String?,
        authStatus: String?,
        configStatus: String?,
        networkChecksPerformed: Bool,
        reportSHA256: String,
        checks: [CodexDoctorCheckEvidence] = []
    ) {
        self.schemaVersion = schemaVersion
        self.codexVersion = codexVersion
        self.overallStatus = overallStatus
        self.codexHome = codexHome
        self.providerID = providerID
        self.model = model
        self.appServerStatus = appServerStatus
        self.authStatus = authStatus
        self.configStatus = configStatus
        self.networkChecksPerformed = networkChecksPerformed
        self.reportSHA256 = reportSHA256
        self.checks = checks
    }

    var summary: String {
        let provider = providerID ?? "官方默认"
        let modelText = model ?? "默认模型"
        return "Codex官方诊断：\(overallStatus)；Provider：\(provider)；模型：\(modelText)；报告已脱敏，仅保留摘要和哈希。"
    }
}

enum CodexDoctorDiagnosticParser {
    static func parse(
        _ data: Data,
        expectedCodexHome: URL
    ) throws -> CodexDoctorDiagnostic {
        guard data.count <= 1_000_000 else {
            throw CodexDoctorDiagnosticError.outputTooLarge
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = root["schemaVersion"] as? Int,
              let overallStatus = boundedString(root["overallStatus"]),
              let checks = root["checks"] as? [String: Any] else {
            throw CodexDoctorDiagnosticError.invalidJSON
        }
        guard schemaVersion == 1 else {
            throw CodexDoctorDiagnosticError.unsupportedSchema(schemaVersion)
        }
        let configCheck = check("config.load", in: checks)
        let configDetails = configCheck?["details"] as? [String: Any]
        guard let reportedCodexHome = boundedString(configDetails?["CODEX_HOME"]) else {
            throw CodexDoctorDiagnosticError.invalidJSON
        }
        guard URL(fileURLWithPath: reportedCodexHome).standardizedFileURL.path
            == expectedCodexHome.standardizedFileURL.path else {
            throw CodexDoctorDiagnosticError.codexHomeMismatch
        }
        let rawModel = boundedString(configDetails?["model"])
        let model = rawModel == "<default>" ? nil : rawModel
        let appServerCheck = check("app_server.status", in: checks)
        let appServerDetails = appServerCheck?["details"] as? [String: Any]
        return CodexDoctorDiagnostic(
            schemaVersion: schemaVersion,
            codexVersion: boundedString(root["codexVersion"]),
            overallStatus: overallStatus,
            codexHome: reportedCodexHome,
            providerID: boundedString(configDetails?["model provider"]),
            model: model,
            appServerStatus:
                boundedString(appServerDetails?["status"])
                ?? boundedString(appServerCheck?["summary"]),
            authStatus: boundedString(check("auth.credentials", in: checks)?["status"]),
            configStatus: boundedString(configCheck?["status"]),
            networkChecksPerformed: checks.keys.contains {
                $0.hasPrefix("network.")
            },
            reportSHA256: TOMLSemanticEngine.sha256(data),
            checks: CodexDoctorCheckEvidenceParser.parse(checks)
        )
    }

    private static func check(
        _ id: String,
        in checks: [String: Any]
    ) -> [String: Any]? {
        checks[id] as? [String: Any]
    }

    private static func boundedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return String(value.prefix(300))
    }
}

enum CodexDoctorDiagnosticRunner {
    static func run(
        executableURL: URL,
        codexHome: URL,
        userAuthorized: Bool,
        timeout: TimeInterval = 30
    ) throws -> CodexDoctorDiagnostic {
        guard userAuthorized else {
            throw CodexDoctorDiagnosticError.authorizationRequired
        }
        let values = try executableURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw CodexDoctorDiagnosticError.unsafeExecutable
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["doctor", "--json"]
        process.currentDirectoryURL = codexHome
        var environment = ProcessInfo.processInfo.environment
        environment = environment.filter { key, _ in
            let upper = key.uppercased()
            return !upper.contains("KEY")
                && !upper.contains("TOKEN")
                && !upper.contains("AUTH")
        }
        environment["CODEX_HOME"] = codexHome.path
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ai-access-doctor-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let stdoutURL = temporaryRoot.appendingPathComponent("stdout.json")
        let stderrURL = temporaryRoot.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(
            atPath: stdoutURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        FileManager.default.createFile(
            atPath: stderrURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw CodexDoctorDiagnosticError.timedOut
        }
        try stdout.synchronize()
        try stderr.synchronize()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stdoutURL.path
        )
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0
            <= 1_000_000 else {
            throw CodexDoctorDiagnosticError.outputTooLarge
        }
        let data = try Data(contentsOf: stdoutURL, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw CodexDoctorDiagnosticError.invalidJSON
        }
        return try CodexDoctorDiagnosticParser.parse(
            data,
            expectedCodexHome: codexHome
        )
    }

    static func embeddedExecutableURL() throws -> URL {
        guard let app = CodexApplicationLocator.applicationURL() else {
            throw CodexDoctorDiagnosticError.executableUnavailable
        }
        let executable = app.appendingPathComponent(
            "Contents/Resources/codex"
        )
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw CodexDoctorDiagnosticError.executableUnavailable
        }
        return executable
    }
}

enum BundledRecoveryHealthState: String, Codable {
    case ready
    case helperMissing
    case helperInvalid
    case recoveryDocumentMissing
}

struct BundledRecoveryHealth: Equatable {
    let state: BundledRecoveryHealthState
    let helperPath: String
    let recoveryDocumentPath: String

    var summary: String {
        switch state {
        case .ready:
            return "认证辅助程序与独立恢复文档均可用。"
        case .helperMissing:
            return "认证辅助程序缺失；不要继续中转启动。请打开独立恢复文档切回官方。路径：\(recoveryDocumentPath)"
        case .helperInvalid:
            return "认证辅助程序签名或文件状态异常；不要继续中转启动。请按独立恢复文档恢复官方。路径：\(recoveryDocumentPath)"
        case .recoveryDocumentMissing:
            return "独立恢复文档缺失；当前安装包不完整，禁止进入托管。"
        }
    }

    var allowsManagedRelayLaunch: Bool {
        state == .ready
    }
}

enum BundledRecoveryHealthInspector {
    static func inspect(
        appBundleURL: URL,
        signatureVerifier: ((URL) -> Bool)? = nil
    ) -> BundledRecoveryHealth {
        let helper = appBundleURL.appendingPathComponent(
            "Contents/Helpers/ai-access-token-helper"
        )
        let recovery = appBundleURL.appendingPathComponent(
            "Contents/Resources/恢复官方轨-独立操作说明.md"
        )
        let recoverySafe = isRegularNonSymbolicFile(recovery)
        guard recoverySafe else {
            return result(
                .recoveryDocumentMissing,
                helper: helper,
                recovery: recovery
            )
        }
        guard isRegularNonSymbolicFile(helper) else {
            return result(.helperMissing, helper: helper, recovery: recovery)
        }
        let verifies = signatureVerifier?(helper)
            ?? verifyHelperSignature(helper)
        guard verifies else {
            return result(.helperInvalid, helper: helper, recovery: recovery)
        }
        return result(.ready, helper: helper, recovery: recovery)
    }

    private static func result(
        _ state: BundledRecoveryHealthState,
        helper: URL,
        recovery: URL
    ) -> BundledRecoveryHealth {
        BundledRecoveryHealth(
            state: state,
            helperPath: helper.path,
            recoveryDocumentPath: recovery.path
        )
    }

    private static func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private static func verifyHelperSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &code
        ) == errSecSuccess,
        let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "identifier \"io.github.liewlf.aiaccessassistant.token-helper\"" as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else { return false }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess
    }
}
