import AppKit
import Foundation
import Security

enum FableLiveAdapterError: LocalizedError, Equatable {
    case testingBlocked
    case invalidCredentialReference
    case invalidCredential
    case credentialUnavailable
    case credentialStoreFailure
    case quitRequestRejected
    case applicationsStillRunning
    case stateDatabaseStillInUse
    case stateDatabaseReleaseCheckUnavailable
    case codexApplicationMissing
    case codexLaunchFailed
    case invalidCodexBundle
    case codexCLIMissing
    case unsafeExecutable
    case versionUnavailable
    case unsupportedVersion
    case commandLaunchFailed
    case verificationPreparationFailed
    case commandTimedOut
    case commandOutputTooLarge
    case commandFailed
    case invalidRelayEndpoint
    case relayRequestFailed
    case relayResponseTooLarge
    case relayRejected(Int)
    case invalidRelayResponse

    var errorDescription: String? {
        switch self {
        case .testingBlocked:
            return "自动测试环境禁止访问真实凭据、进程或网络"
        case .invalidCredentialReference:
            return "中转凭据标识无效"
        case .invalidCredential:
            return "中转Key为空或格式无效"
        case .credentialUnavailable:
            return "未找到该中转的本机凭据，请重新输入API Key"
        case .credentialStoreFailure:
            return "中转Key无法安全存取"
        case .quitRequestRejected:
            return "Codex或配置工具未接受正常退出请求"
        case .applicationsStillRunning:
            return "Codex或配置工具仍在运行；助手没有强制结束进程"
        case .stateDatabaseStillInUse:
            return "Codex后台仍在使用历史会话。请先在Codex中保存工作并正常退出，等待几秒后再点“一键恢复”；助手不会强制结束进程"
        case .stateDatabaseReleaseCheckUnavailable:
            return "助手无法确认历史会话数据库已安全释放。请正常退出Codex，重新打开AI接入助手后再点“一键恢复”；本次没有继续修改文件"
        case .codexApplicationMissing:
            return "未找到Codex Desktop"
        case .codexLaunchFailed:
            return "Codex Desktop无法正常打开"
        case .invalidCodexBundle:
            return "Codex Desktop安装包无法安全识别"
        case .codexCLIMissing:
            return "Codex Desktop缺少内置命令行程序"
        case .unsafeExecutable:
            return "Codex内置命令行程序不是安全的可执行文件"
        case .versionUnavailable:
            return "无法确认Codex Desktop与内置命令行版本"
        case .unsupportedVersion:
            return "当前Codex版本尚未通过真实接入验证，只允许查看"
        case .commandLaunchFailed:
            return "Codex验证程序无法启动"
        case .verificationPreparationFailed:
            return "Codex独立验证准备失败"
        case .commandTimedOut:
            return "Codex独立验证超时（MCP已隔离）；中转网络或模型响应未在限时内完成"
        case .commandOutputTooLarge:
            return "Codex验证返回内容异常"
        case .commandFailed:
            return "Codex官方最小请求未通过"
        case .invalidRelayEndpoint:
            return "中转Responses地址无效"
        case .relayRequestFailed:
            return "中转最小请求未完成"
        case .relayResponseTooLarge:
            return "中转返回内容超过安全上限"
        case let .relayRejected(status):
            return "中转拒绝了最小请求（HTTP \(status)）"
        case .invalidRelayResponse:
            return "中转没有返回有效的Responses结果"
        }
    }
}

enum FableKeychainNamespace {
    static let service = "com.ai-access-assistant.relay-credentials.v1"
    static let accountPrefix = "relay-profile/"

    static func account(for reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw FableLiveAdapterError.invalidCredentialReference
        }
        return accountPrefix + trimmed
    }
}

protocol FableKeychainBackend {
    func copy(service: String, account: String) -> (OSStatus, Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

struct FableSystemKeychainBackend: FableKeychainBackend {
    func copy(service: String, account: String) -> (OSStatus, Data?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        return (status, result as? Data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data,
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let values: [CFString: Any] = [
            kSecValueData: data,
        ]
        return SecItemUpdate(
            query as CFDictionary,
            values as CFDictionary
        )
    }

    func delete(service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

struct FableMacOSKeychainCredentialStore: FableCredentialStore {
    static let maximumSecretBytes = 16 * 1024

    private let backend: any FableKeychainBackend
    private let environment: () -> [String: String]

    init(
        backend: any FableKeychainBackend = FableSystemKeychainBackend(),
        environment: @escaping () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.backend = backend
        self.environment = environment
    }

    func store(_ secret: String, reference: String) throws {
        try requireLiveAccess()
        let account = try FableKeychainNamespace.account(for: reference)
        let data = try validatedSecret(secret)
        let existing = backend.copy(
            service: FableKeychainNamespace.service,
            account: account
        ).0
        let status: OSStatus
        switch existing {
        case errSecSuccess:
            status = backend.update(
                service: FableKeychainNamespace.service,
                account: account,
                data: data
            )
        case errSecItemNotFound:
            let added = backend.add(
                service: FableKeychainNamespace.service,
                account: account,
                data: data
            )
            if added == errSecDuplicateItem {
                status = backend.update(
                    service: FableKeychainNamespace.service,
                    account: account,
                    data: data
                )
            } else {
                status = added
            }
        default:
            throw FableLiveAdapterError.credentialStoreFailure
        }
        guard status == errSecSuccess else {
            throw FableLiveAdapterError.credentialStoreFailure
        }
    }

    func secret(reference: String) throws -> String? {
        try requireLiveAccess()
        let account = try FableKeychainNamespace.account(for: reference)
        let (status, data) = backend.copy(
            service: FableKeychainNamespace.service,
            account: account
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data,
              !data.isEmpty,
              data.count <= Self.maximumSecretBytes,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty,
              (try? validatedSecret(secret)) != nil else {
            throw FableLiveAdapterError.credentialStoreFailure
        }
        return secret
    }

    func delete(reference: String) throws {
        try requireLiveAccess()
        let account = try FableKeychainNamespace.account(for: reference)
        let status = backend.delete(
            service: FableKeychainNamespace.service,
            account: account
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FableLiveAdapterError.credentialStoreFailure
        }
    }

    private func requireLiveAccess() throws {
        guard environment()["AI_ACCESS_ASSISTANT_TESTING"] != "1" else {
            throw FableLiveAdapterError.testingBlocked
        }
    }

    private func validatedSecret(_ secret: String) throws -> Data {
        let data = Data(secret.utf8)
        guard !data.isEmpty,
              data.count <= Self.maximumSecretBytes,
              !secret.unicodeScalars.contains(where: {
                  CharacterSet.newlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw FableLiveAdapterError.invalidCredential
        }
        return data
    }
}

struct FableApplicationSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol FableApplicationRuntime {
    func runningApplications() -> [FableApplicationSnapshot]
    func requestNormalTermination(
        _ application: FableApplicationSnapshot
    ) -> Bool
    func applicationURL(
        bundleIdentifier: String,
        candidates: [URL]
    ) -> URL?
    func launchApplication(at url: URL) throws
}

struct FableSystemApplicationRuntime: FableApplicationRuntime {
    func runningApplications() -> [FableApplicationSnapshot] {
        NSWorkspace.shared.runningApplications.map {
            FableApplicationSnapshot(
                processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName
            )
        }
    }

    func requestNormalTermination(
        _ application: FableApplicationSnapshot
    ) -> Bool {
        guard let running = NSRunningApplication(
            processIdentifier: application.processIdentifier
        ) else {
            return true
        }
        return running.terminate()
    }

    func applicationURL(
        bundleIdentifier: String,
        candidates: [URL]
    ) -> URL? {
        if let registered = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ), verifiedBundle(registered, identifier: bundleIdentifier) {
            return registered
        }
        return candidates.first {
            verifiedBundle($0, identifier: bundleIdentifier)
        }
    }

    func launchApplication(at url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var launchError: Error?
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { _, error in
            lock.lock()
            launchError = error
            lock.unlock()
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(15)
        while semaphore.wait(timeout: .now()) != .success {
            guard Date() < deadline else {
                throw FableLiveAdapterError.codexLaunchFailed
            }
            if Thread.isMainThread {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        lock.lock()
        let error = launchError
        lock.unlock()
        guard error == nil else {
            throw FableLiveAdapterError.codexLaunchFailed
        }
    }

    private func verifiedBundle(
        _ url: URL,
        identifier: String
    ) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let bundle = Bundle(url: url),
        bundle.bundleIdentifier == identifier,
        identifier
            != FableMacOSProcessController.codexBundleIdentifier
            || FableOpenAICodeSignatureValidator()
                .validateApplication(url) else {
            return false
        }
        return true
    }
}

enum FableFileOccupancy: Equatable {
    case released
    case held
}

protocol FableFileOccupancyProbing {
    func occupancy(of files: [URL]) throws -> FableFileOccupancy
}

struct FableLsofFileOccupancyProbe: FableFileOccupancyProbing {
    private static let executable = URL(
        fileURLWithPath: "/usr/sbin/lsof"
    )
    private let commandRunner: any FableCommandRunning
    private let fileManager: FileManager

    init(
        commandRunner: any FableCommandRunning =
            FableSystemCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func occupancy(of files: [URL]) throws -> FableFileOccupancy {
        let existingPaths = files
            .map { $0.standardizedFileURL.path }
            .filter { fileManager.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else { return .released }

        let result: FableCommandResult
        do {
            result = try commandRunner.run(
                executable: Self.executable,
                arguments: ["-t", "--"] + existingPaths,
                environmentOverrides: [:],
                timeout: 2,
                maximumCapturedBytes: 32 * 1024
            )
        } catch {
            throw FableLiveAdapterError
                .stateDatabaseReleaseCheckUnavailable
        }

        switch result.terminationStatus {
        case 0:
            guard containsOnlyProcessIdentifiers(
                result.standardOutput
            ) else {
                throw FableLiveAdapterError
                    .stateDatabaseReleaseCheckUnavailable
            }
            return .held
        case 1:
            guard result.standardOutput.isEmpty,
                  result.standardError.isEmpty else {
                throw FableLiveAdapterError
                    .stateDatabaseReleaseCheckUnavailable
            }
            return .released
        default:
            throw FableLiveAdapterError
                .stateDatabaseReleaseCheckUnavailable
        }
    }

    private func containsOnlyProcessIdentifiers(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let lines = text.split(
            whereSeparator: { $0.isNewline }
        )
        return !lines.isEmpty && lines.allSatisfy { line in
            !line.isEmpty && line.utf8.allSatisfy {
                $0 >= 48 && $0 <= 57
            }
        }
    }
}

struct FableMacOSProcessController: FableProcessController {
    static let codexBundleIdentifier = "com.openai.codex"
    static let managedBundleIdentifiers = Set([
        codexBundleIdentifier,
        "com.bigpizzav3.codexplusplus",
        "com.bigpizzav3.codexplusplus.manager",
        "com.ccswitch.desktop",
    ])

    private let runtime: any FableApplicationRuntime
    private let fileOccupancyProbe:
        any FableFileOccupancyProbing
    private let quitTimeout: TimeInterval
    private let databaseReleaseTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let environment: () -> [String: String]
    private let homeDirectory: URL

    init(
        runtime: any FableApplicationRuntime =
            FableSystemApplicationRuntime(),
        fileOccupancyProbe: any FableFileOccupancyProbing =
            FableLsofFileOccupancyProbe(),
        quitTimeout: TimeInterval = 15,
        databaseReleaseTimeout: TimeInterval = 15,
        pollInterval: TimeInterval = 0.2,
        sleep: @escaping (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        environment: @escaping () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        homeDirectory: URL =
            FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runtime = runtime
        self.fileOccupancyProbe = fileOccupancyProbe
        self.quitTimeout = quitTimeout
        self.databaseReleaseTimeout = databaseReleaseTimeout
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func stopConfigurationWriters() throws {
        try requireLiveAccess()
        let targets = managedApplications(
            in: runtime.runningApplications()
        )
        for application in targets {
            guard runtime.requestNormalTermination(application) else {
                throw FableLiveAdapterError.quitRequestRejected
            }
        }
        let deadline = Date().addingTimeInterval(quitTimeout)
        while !managedApplications(
            in: runtime.runningApplications()
        ).isEmpty {
            guard Date() < deadline else {
                throw FableLiveAdapterError.applicationsStillRunning
            }
            sleep(pollInterval)
        }
        try waitForStateDatabaseRelease()
    }

    func relaunchCodex() throws {
        try requireLiveAccess()
        guard let url = runtime.applicationURL(
            bundleIdentifier: Self.codexBundleIdentifier,
            candidates: codexCandidates
        ) else {
            throw FableLiveAdapterError.codexApplicationMissing
        }
        do {
            try runtime.launchApplication(at: url)
        } catch let error as FableLiveAdapterError {
            throw error
        } catch {
            throw FableLiveAdapterError.codexLaunchFailed
        }
    }

    private var codexCandidates: [URL] {
        [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            homeDirectory.appendingPathComponent(
                "Applications/ChatGPT.app"
            ),
            homeDirectory.appendingPathComponent(
                "Applications/Codex.app"
            ),
        ]
    }

    private func managedApplications(
        in applications: [FableApplicationSnapshot]
    ) -> [FableApplicationSnapshot] {
        applications.filter { application in
            if let identifier = application.bundleIdentifier,
               Self.managedBundleIdentifiers.contains(identifier) {
                return true
            }
            guard application.bundleIdentifier == nil else {
                return false
            }
            let name = application.localizedName?
                .lowercased()
                .replacingOccurrences(of: " ", with: "") ?? ""
            return name == "codex"
                || name == "chatgpt"
                || name == "codex++"
                || name == "codex++管理工具"
                || name == "ccswitch"
        }
    }

    private func waitForStateDatabaseRelease() throws {
        let stateFiles = try stateDatabaseURLs()
        let deadline = Date().addingTimeInterval(
            databaseReleaseTimeout
        )
        while true {
            let occupancy: FableFileOccupancy
            do {
                occupancy = try fileOccupancyProbe.occupancy(
                    of: stateFiles
                )
            } catch {
                throw FableLiveAdapterError
                    .stateDatabaseReleaseCheckUnavailable
            }
            if occupancy == .released { return }
            guard Date() < deadline else {
                throw FableLiveAdapterError.stateDatabaseStillInUse
            }
            sleep(pollInterval)
        }
    }

    private func stateDatabaseURLs() throws -> [URL] {
        let codexHome: URL
        if let override = environment()["CODEX_HOME"],
           !override.isEmpty {
            guard override.hasPrefix("/"),
                  override.utf8.count <= Int(PATH_MAX),
                  !override.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw FableLiveAdapterError
                    .stateDatabaseReleaseCheckUnavailable
            }
            codexHome = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        } else {
            codexHome = homeDirectory.appendingPathComponent(
                ".codex",
                isDirectory: true
            ).standardizedFileURL
        }
        let database = codexHome.appendingPathComponent(
            "state_5.sqlite",
            isDirectory: false
        )
        return [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
        ]
    }

    private func requireLiveAccess() throws {
        guard environment()["AI_ACCESS_ASSISTANT_TESTING"] != "1" else {
            throw FableLiveAdapterError.testingBlocked
        }
    }
}

struct FableCommandResult: Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol FableCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        maximumCapturedBytes: Int
    ) throws -> FableCommandResult
}

struct FableSystemCommandRunner: FableCommandRunning {
    private let environment: () -> [String: String]
    init(
        environment: @escaping () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.environment = environment
    }
    func run(
        executable: URL,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: TimeInterval,
        maximumCapturedBytes: Int
    ) throws -> FableCommandResult {
        guard environment()["AI_ACCESS_ASSISTANT_TESTING"] != "1" else {
            throw FableLiveAdapterError.testingBlocked
        }
        try Task.checkCancellation()
        try validateExecutable(executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = FableCommandEnvironmentPolicy.sanitized(
            base: environment(),
            overrides: environmentOverrides
        )
        let stdout = Pipe()
        let stderr = Pipe()
        if maximumCapturedBytes > 0 {
            process.standardOutput = stdout
            process.standardError = stderr
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        let group = DispatchGroup()
        let outputLock = NSLock()
        var outputData = Data()
        var errorData = Data()
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw FableLiveAdapterError.commandLaunchFailed
        }
        if maximumCapturedBytes > 0 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                outputLock.lock()
                outputData = data
                outputLock.unlock()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                outputLock.lock()
                errorData = data
                outputLock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard !Task.isCancelled, Date() < deadline else {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try Task.checkCancellation()
                throw FableLiveAdapterError.commandTimedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        if maximumCapturedBytes > 0 {
            guard group.wait(timeout: .now() + 2) == .success else {
                throw FableLiveAdapterError.commandTimedOut
            }
        }
        outputLock.lock()
        let capturedOutput = outputData
        let capturedError = errorData
        outputLock.unlock()
        guard capturedOutput.count + capturedError.count
            <= maximumCapturedBytes else {
            throw FableLiveAdapterError.commandOutputTooLarge
        }
        return FableCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: capturedOutput,
            standardError: capturedError
        )
    }

    private func validateExecutable(_ url: URL) throws {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isExecutableFile(atPath: url.path) else {
            throw FableLiveAdapterError.unsafeExecutable
        }
    }
}

struct FableCodexInstallation: Equatable {
    let applicationURL: URL
    let cliURL: URL
    let identity: CodexVersionIdentity
    let support: FableVersionSupport
    let contractEntry: CodexVersionContract.Entry?
    let agentLoopExecutionProtocol:
        CodexAgentLoopExecutionProtocol?
    let compatibilityEvidence: CodexCompatibilityEvidence

    init(
        applicationURL: URL,
        cliURL: URL,
        identity: CodexVersionIdentity,
        support: FableVersionSupport,
        agentLoopExecutionProtocol:
            CodexAgentLoopExecutionProtocol?,
        contractEntry: CodexVersionContract.Entry? = nil,
        compatibilityEvidence:
            CodexCompatibilityEvidence? = nil
    ) {
        self.applicationURL = applicationURL
        self.cliURL = cliURL
        self.identity = identity
        self.agentLoopExecutionProtocol =
            agentLoopExecutionProtocol
        let effectiveSupport: FableVersionSupport =
            agentLoopExecutionProtocol == nil
                ? .readOnly
                : support
        self.support = effectiveSupport
        if let contractEntry {
            self.contractEntry = contractEntry
        } else if case let .verified(schemaID) = effectiveSupport {
            self.contractEntry = CodexVersionContract.Entry(
                schemaID: schemaID,
                appVersion: identity.appVersion,
                appBuild: identity.appBuild,
                cliVersion: identity.cliVersion
            )
        } else {
            self.contractEntry = nil
        }
        self.compatibilityEvidence = compatibilityEvidence
            ?? (
                support.allowsWrites
                    ? .bundled(identity)
                    : .unverified
            )
    }
}

protocol FableCodeSignatureValidating {
    func validateApplication(_ url: URL) -> Bool
    func validateCLI(_ url: URL) -> Bool
}

struct FableOpenAICodeSignatureValidator:
    FableCodeSignatureValidating {
    static let teamIdentifier = "2DC432GLL2"

    func validateApplication(_ url: URL) -> Bool {
        validate(
            url,
            identifier: FableMacOSProcessController
                .codexBundleIdentifier
        )
    }

    func validateCLI(_ url: URL) -> Bool {
        validate(url, identifier: "codex")
    }

    private func validate(
        _ url: URL,
        identifier: String
    ) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return false
        }
        let requirementText =
            #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(Self.teamIdentifier)""#
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }
        let flags = SecCSFlags(
            rawValue:
                kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        ) == errSecSuccess
    }
}

protocol FableCodexBundleLocating {
    func codexApplicationURL() -> URL?
}

struct FableSystemCodexBundleLocator: FableCodexBundleLocating {
    private let runtime: any FableApplicationRuntime
    private let homeDirectory: URL

    init(
        runtime: any FableApplicationRuntime =
            FableSystemApplicationRuntime(),
        homeDirectory: URL =
            FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runtime = runtime
        self.homeDirectory = homeDirectory
    }

    func codexApplicationURL() -> URL? {
        runtime.applicationURL(
            bundleIdentifier:
                FableMacOSProcessController.codexBundleIdentifier,
            candidates: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                URL(fileURLWithPath: "/Applications/Codex.app"),
                homeDirectory.appendingPathComponent(
                    "Applications/ChatGPT.app"
                ),
                homeDirectory.appendingPathComponent(
                    "Applications/Codex.app"
                ),
            ]
        )
    }
}

protocol FableCodexVersionDiscovering {
    func discover() throws -> FableCodexInstallation
}

struct FableCodexVersionDiscovery: FableCodexVersionDiscovering {
    private let locator: any FableCodexBundleLocating
    private let commandRunner: any FableCommandRunning
    private let signatureValidator:
        any FableCodeSignatureValidating
    private let contract: CodexVersionContract
    private let compatibilityResolver:
        any CodexDynamicCompatibilityResolving
    private let binaryHasher: any CodexBinaryHashing

    init(
        locator: any FableCodexBundleLocating =
            FableSystemCodexBundleLocator(),
        commandRunner: any FableCommandRunning =
            FableSystemCommandRunner(),
        signatureValidator:
            any FableCodeSignatureValidating =
                FableOpenAICodeSignatureValidator(),
        contract: CodexVersionContract = .verified,
        compatibilityResolver:
            any CodexDynamicCompatibilityResolving =
                CodexDynamicCompatibilityResolver.live(),
        binaryHasher: any CodexBinaryHashing =
            CodexBinarySHA256Hasher()
    ) {
        self.locator = locator
        self.commandRunner = commandRunner
        self.signatureValidator = signatureValidator
        self.contract = contract
        self.compatibilityResolver = compatibilityResolver
        self.binaryHasher = binaryHasher
    }

    func discover() throws -> FableCodexInstallation {
        guard let applicationURL = locator.codexApplicationURL() else {
            throw FableLiveAdapterError.codexApplicationMissing
        }
        guard isSafeDirectory(applicationURL),
              signatureValidator.validateApplication(
                  applicationURL
              ) else {
            throw FableLiveAdapterError.invalidCodexBundle
        }
        let infoURL = applicationURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard isSafeRegularFile(infoURL),
              let infoData = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                  from: infoData,
                  options: [],
                  format: nil
              ),
              let info = object as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == FableMacOSProcessController.codexBundleIdentifier,
              let appVersion =
                info["CFBundleShortVersionString"] as? String,
              let appBuild = info["CFBundleVersion"] as? String,
              !appVersion.isEmpty,
              !appBuild.isEmpty else {
            throw FableLiveAdapterError.invalidCodexBundle
        }
        guard let cliURL = cliCandidates(applicationURL).first(where: {
            isSafeExecutable($0)
                && signatureValidator.validateCLI($0)
        }) else {
            throw FableLiveAdapterError.codexCLIMissing
        }
        let result = try commandRunner.run(
            executable: cliURL,
            arguments: ["--version"],
            environmentOverrides: [:],
            timeout: 5,
            maximumCapturedBytes: 64 * 1024
        )
        guard result.terminationStatus == 0,
              let cliVersion = parseCLIVersion(
                  result.standardOutput + result.standardError
              ) else {
            throw FableLiveAdapterError.versionUnavailable
        }
        let identity = CodexVersionIdentity(
            appVersion: appVersion,
            appBuild: appBuild,
            cliVersion: cliVersion
        )
        let outcome: CodexCompatibilityProbeOutcome
        if let entry = contract.entry(for: identity) {
            outcome = CodexCompatibilityProbeOutcome(
                contractEntry: entry,
                agentLoopExecutionProtocol: .approveForMeV1,
                evidence: .bundled(identity)
            )
        } else {
            do {
                let digest = try binaryHasher.sha256(of: cliURL)
                outcome = compatibilityResolver.resolve(
                    applicationURL: applicationURL,
                    cliURL: cliURL,
                    identity: identity,
                    cliSHA256: digest
                )
            } catch {
                outcome = CodexCompatibilityProbeOutcome(
                    contractEntry: nil,
                    agentLoopExecutionProtocol: nil,
                    evidence: CodexCompatibilityEvidence(
                        source: .blocked,
                        summary:
                            "无法核对Codex内置程序指纹；本次保持只读",
                        failureCheck: "embedded-cli-sha256",
                        cacheKey: nil
                    )
                )
            }
        }
        let installation = FableCodexInstallation(
            applicationURL: applicationURL,
            cliURL: cliURL,
            identity: identity,
            support: outcome.support,
            agentLoopExecutionProtocol:
                outcome.agentLoopExecutionProtocol,
            contractEntry: outcome.contractEntry,
            compatibilityEvidence: outcome.evidence
        )
        CodexCompatibilityRegistry.record(
            applicationURL: applicationURL,
            appVersion: installation.identity.appVersion,
            appBuild: installation.identity.appBuild,
            allowsWrites: installation.support.allowsWrites,
            evidenceSummary:
                installation.compatibilityEvidence.summary
        )
        return installation
    }

    private func cliCandidates(_ applicationURL: URL) -> [URL] {
        [
            applicationURL
                .appendingPathComponent("Contents/Resources/codex"),
            applicationURL
                .appendingPathComponent("Contents/MacOS/codex"),
        ]
    }

    private func isSafeExecutable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private func parseCLIVersion(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b"#
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(
            in: text,
            options: [],
            range: range
        ),
        let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}

struct FableHTTPResult {
    let data: Data
    let response: HTTPURLResponse
}

protocol FableHTTPTransport {
    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) throws -> FableHTTPResult
}

struct FableSystemHTTPTransport: FableHTTPTransport {
    private let session: URLSession
    private let environment: () -> [String: String]

    init(
        session: URLSession = .shared,
        environment: @escaping () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.session = session
        self.environment = environment
    }

    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) throws -> FableHTTPResult {
        guard environment()["AI_ACCESS_ASSISTANT_TESTING"] != "1" else {
            throw FableLiveAdapterError.testingBlocked
        }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let task = session.dataTask(with: request) {
            data, response, error in
            lock.lock()
            resultData = data
            resultResponse = response
            resultError = error
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw FableLiveAdapterError.relayRequestFailed
        }
        lock.lock()
        let data = resultData
        let response = resultResponse
        let error = resultError
        lock.unlock()
        guard error == nil,
              let data,
              let http = response as? HTTPURLResponse else {
            throw FableLiveAdapterError.relayRequestFailed
        }
        guard data.count <= maximumResponseBytes else {
            throw FableLiveAdapterError.relayResponseTooLarge
        }
        return FableHTTPResult(data: data, response: http)
    }
}

struct FableLiveRuntimeVerifier: FableRuntimeVerifier {
    private let codexHome: URL
    private let credentialStore: any FableCredentialStore
    private let versionDiscovery: any FableCodexVersionDiscovering
    private let commandRunner: any FableCommandRunning
    private let httpTransport: any FableHTTPTransport
    private let versionContract: CodexVersionContract
    private let commandTimeout: TimeInterval

    init(
        codexHome: URL,
        credentialStore: any FableCredentialStore,
        versionDiscovery: any FableCodexVersionDiscovering =
            FableCodexVersionDiscovery(),
        commandRunner: any FableCommandRunning =
            FableSystemCommandRunner(),
        httpTransport: any FableHTTPTransport =
            FableSystemHTTPTransport(),
        versionContract: CodexVersionContract = .verified,
        commandTimeout: TimeInterval = 45
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.credentialStore = credentialStore
        self.versionDiscovery = versionDiscovery
        self.commandRunner = commandRunner
        self.httpTransport = httpTransport
        self.versionContract = versionContract
        self.commandTimeout = max(1, commandTimeout)
    }

    func verifyOfficial() throws {
        try verifyCurrentConfiguration()
    }

    func verifyRelay(_ profile: RelayProfile) throws {
        try verifyCurrentConfiguration()
    }

    private func verifyCurrentConfiguration() throws {
        let installation = try versionDiscovery.discover()
        guard supportsRuntimeVerification(installation) else {
            throw FableLiveAdapterError.unsupportedVersion
        }
        try FableBasicConnectionProbe.run(installation: installation,
            codexHome: codexHome, commandRunner: commandRunner,
            commandTimeout: commandTimeout)
    }

    private func supportsRuntimeVerification(
        _ installation: FableCodexInstallation
    ) -> Bool {
        guard let entry = installation.contractEntry,
              entry.matches(installation.identity),
              case let .verified(schemaID) =
                installation.support else {
            return false
        }
        return schemaID == entry.schemaID
    }

    private func responsesEndpoint(_ baseURL: String) throws -> URL {
        guard var components = URLComponents(string: baseURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw FableLiveAdapterError.invalidRelayEndpoint
        }
        let trimmed = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.split(separator: "/").last?.lowercased()
            != "responses" {
            components.path = "/"
                + ([trimmed, "responses"].filter { !$0.isEmpty })
                    .joined(separator: "/")
        }
        guard let url = components.url else {
            throw FableLiveAdapterError.invalidRelayEndpoint
        }
        return url
    }
}
