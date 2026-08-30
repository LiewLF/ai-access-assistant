import Foundation
import Security

enum CredentialBridgeState: String, Codable, Equatable {
    case ready
    case helperMissing
    case helperInvalid
    case codexUnsupported
    case secretMissing
}

enum PersistentCredentialBridgeError: LocalizedError, Equatable {
    case testingBlocked
    case bundledHelperMissing
    case bundledHelperInvalid
    case installedHelperInvalid
    case launchFailed
    case timeout
    case outputTooLarge
    case helperFailure(Int32)
    case invalidSecret

    var errorDescription: String? {
        switch self {
        case .testingBlocked:
            return "自动测试禁止访问真实凭据Helper"
        case .bundledHelperMissing:
            return "安装包缺少认证辅助程序"
        case .bundledHelperInvalid:
            return "安装包中的认证辅助程序签名无效"
        case .installedHelperInvalid:
            return "稳定认证辅助程序安装或签名校验失败"
        case .launchFailed:
            return "认证辅助程序无法启动"
        case .timeout:
            return "认证辅助程序响应超时"
        case .outputTooLarge:
            return "认证辅助程序返回内容异常"
        case let .helperFailure(status):
            return "认证辅助程序失败：\(status)"
        case .invalidSecret:
            return "中转Key为空或超过安全长度"
        }
    }
}

enum PersistentCredentialBridge {
    static let helperName = "ai-access-token-helper"
    static let maximumSecretBytes = 16 * 1024

    static func rootURL(
        applicationSupportURL: URL? = nil
    ) -> URL {
        let support = applicationSupportURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        return support
            .appendingPathComponent("AI接入助手", isDirectory: true)
            .appendingPathComponent("CredentialBridge", isDirectory: true)
    }

    static func stableHelperURL(
        applicationSupportURL: URL? = nil
    ) -> URL {
        rootURL(applicationSupportURL: applicationSupportURL)
            .appendingPathComponent(helperName, isDirectory: false)
    }

    static func bundledHelperURL(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName, isDirectory: false)
    }

    static func ensureInstalled(
        bundleURL: URL = Bundle.main.bundleURL,
        applicationSupportURL: URL? = nil,
        signatureVerifier: ((URL) -> Bool)? = nil,
        allowTestRoot: Bool = false
    ) throws -> URL {
        try requireLiveAccess(
            allowTestRoot: allowTestRoot
        )
        let source = bundledHelperURL(bundleURL: bundleURL)
        guard isRegularNonSymbolicFile(source) else {
            throw PersistentCredentialBridgeError.bundledHelperMissing
        }
        let verify = signatureVerifier ?? verifiesCodeSignature
        guard verify(source) else {
            throw PersistentCredentialBridgeError.bundledHelperInvalid
        }

        let root = rootURL(applicationSupportURL: applicationSupportURL)
        let target = stableHelperURL(
            applicationSupportURL: applicationSupportURL
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        if isRegularNonSymbolicFile(target), verify(target),
           try Data(contentsOf: target, options: .mappedIfSafe)
            == Data(contentsOf: source, options: .mappedIfSafe) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: target.path
            )
            return target
        }

        let temporary = root.appendingPathComponent(
            ".\(helperName).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporary.path
        )
        guard verify(temporary) else {
            throw PersistentCredentialBridgeError.installedHelperInvalid
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(
                target,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: target.path
        )
        guard isRegularNonSymbolicFile(target), verify(target) else {
            throw PersistentCredentialBridgeError.installedHelperInvalid
        }
        return target
    }

    static func save(
        _ secret: String,
        profileID: String
    ) throws {
        let data = Data(secret.utf8)
        guard !data.isEmpty, data.count <= maximumSecretBytes else {
            throw PersistentCredentialBridgeError.invalidSecret
        }
        _ = try run(
            operation: "store",
            profileID: profileID,
            input: data,
            expectsOutput: false
        )
    }

    static func load(profileID: String) throws -> String {
        let data = try run(
            operation: "fetch",
            profileID: profileID,
            input: nil,
            expectsOutput: true
        )
        guard !data.isEmpty, data.count <= maximumSecretBytes,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw PersistentCredentialBridgeError.invalidSecret
        }
        return value
    }

    static func delete(profileID: String) throws {
        _ = try run(
            operation: "delete",
            profileID: profileID,
            input: nil,
            expectsOutput: false
        )
    }

    static func status(profileID: String) throws -> CredentialBridgeState {
        let data = try run(
            operation: "status",
            profileID: profileID,
            input: nil,
            expectsOutput: true
        )
        switch String(decoding: data, as: UTF8.self) {
        case "ready": return .ready
        case "missing": return .secretMissing
        default: return .helperInvalid
        }
    }

    static func commandAuthenticationLines(
        profileID: String,
        helperURL: URL? = nil
    ) -> [String] {
        let path = helperURL
            ?? stableHelperURL()
        return [
            "command = \(tomlString(path.path))",
            "args = [\(tomlString("fetch")), \(tomlString("--profile")), \(tomlString(profileID))]",
            "timeout_ms = 5000",
            "refresh_interval_ms = 0",
        ]
    }

    private static func run(
        operation: String,
        profileID: String,
        input: Data?,
        expectsOutput: Bool
    ) throws -> Data {
        try requireLiveAccess()
        let helper = try ensureInstalled()
        let process = Process()
        process.executableURL = helper
        process.arguments = [operation, "--profile", profileID]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input == nil ? nil : Pipe()
        if let stdin {
            process.standardInput = stdin
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            throw PersistentCredentialBridgeError.launchFailed
        }
        if let input, let stdin {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw PersistentCredentialBridgeError.timeout
        }
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let errorOutput = try stderr.fileHandleForReading.readToEnd() ?? Data()
        guard output.count <= maximumSecretBytes,
              errorOutput.count <= 4 * 1024 else {
            throw PersistentCredentialBridgeError.outputTooLarge
        }
        guard process.terminationStatus == 0 else {
            throw PersistentCredentialBridgeError.helperFailure(
                process.terminationStatus
            )
        }
        if expectsOutput {
            return output
        }
        guard output.isEmpty, errorOutput.isEmpty else {
            throw PersistentCredentialBridgeError.outputTooLarge
        }
        return Data()
    }

    private static func requireLiveAccess(
        allowTestRoot: Bool = false
    ) throws {
        if ProcessInfo.processInfo.environment[
            "AI_ACCESS_ASSISTANT_TESTING"
        ] == "1", !allowTestRoot {
            throw PersistentCredentialBridgeError.testingBlocked
        }
    }

    private static func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private static func verifiesCodeSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &code
        ) == errSecSuccess,
        let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private static func tomlString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output += "\\b"
            case 0x09:
                output += "\\t"
            case 0x0A:
                output += "\\n"
            case 0x0C:
                output += "\\f"
            case 0x0D:
                output += "\\r"
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0x00...0x1F, 0x7F:
                output += String(
                    format: "\\u%04X",
                    scalar.value
                )
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}
