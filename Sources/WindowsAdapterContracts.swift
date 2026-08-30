import Foundation

enum WindowsArchitecture: String, Codable {
    case x64
    case arm64
}

enum WindowsProductContract {
    static let sourceBuild = 142
    static let minimumWindowsBuild = 22_000
    static let runtimeIdentifier = "win-x64"
    static let runtimeState = "unverified"
    static let supportedArchitecture = WindowsArchitecture.x64
}

struct WindowsHostFacts: Codable, Equatable {
    let edition: String
    let version: String
    let build: Int
    let architecture: WindowsArchitecture
    let availableDiskBytes: Int64?
    let webView2Version: String?
    let vcRuntimeVersions: [String]
    let dotnetVersions: [String]
    let appLockerBlocked: Bool
    let smartScreenPolicy: String?
    let canRequestElevation: Bool
}

struct WindowsInstallationArtifact: Identifiable, Codable, Equatable {
    let id: String
    let productVersion: String
    let architecture: WindowsArchitecture
    let packageKind: InstallationPackageKind
    let downloadURL: URL
    let sha256: String
    let authenticodePublisher: String
    let packageFamilyName: String?
    let productCode: String?
    let minimumBuild: Int
    let maximumVerifiedBuild: Int?
    let byteCount: Int64
    let verifiedAt: Date
    let revoked: Bool
}

enum WindowsSupportState: String, Codable {
    case deferred
    case compatible
    case blocked
}

struct WindowsSupportDecision: Codable, Equatable {
    let state: WindowsSupportState
    let reasons: [String]
}

enum WindowsCompatibilityGate {
    static func evaluate(
        artifact: WindowsInstallationArtifact?,
        host: WindowsHostFacts,
        windowsRuntimeImplemented: Bool
    ) -> WindowsSupportDecision {
        guard windowsRuntimeImplemented else {
            return WindowsSupportDecision(
                state: .deferred,
                reasons: ["Windows运行时尚未在Windows构建机完成真实构建和验收"]
            )
        }
        guard let artifact else {
            return WindowsSupportDecision(state: .blocked, reasons: ["没有匹配的Windows安装包"])
        }
        var reasons: [String] = []
        if artifact.packageKind != .msix && artifact.packageKind != .exe {
            reasons.append("安装包不是MSIX或EXE")
        }
        if artifact.revoked { reasons.append("安装包已撤销") }
        if artifact.architecture != host.architecture { reasons.append("CPU架构不匹配") }
        if host.build < artifact.minimumBuild { reasons.append("Windows Build过低") }
        if let maximum = artifact.maximumVerifiedBuild, host.build > maximum {
            reasons.append("Windows Build超出已验证范围")
        }
        if artifact.sha256.count != 64 { reasons.append("SHA-256证据无效") }
        if artifact.authenticodePublisher.isEmpty { reasons.append("缺少Authenticode发布者") }
        if host.appLockerBlocked { reasons.append("AppLocker策略阻止安装") }
        if let available = host.availableDiskBytes, available < artifact.byteCount * 2 {
            reasons.append("可用磁盘空间不足")
        }
        return WindowsSupportDecision(
            state: reasons.isEmpty ? .compatible : .blocked,
            reasons: reasons
        )
    }
}

struct WindowsCodexPaths: Codable, Equatable {
    let userProfile: String
    let codexHome: String
    let configPath: String
    let authPath: String
    let assistantApplicationData: String
    let transactionMutexName: String

    static func standard(
        userProfile: String,
        localAppData: String
    ) -> WindowsCodexPaths {
        let profile = userProfile.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        let appData = localAppData.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        return WindowsCodexPaths(
            userProfile: profile,
            codexHome: "\(profile)\\.codex",
            configPath: "\(profile)\\.codex\\config.toml",
            authPath: "\(profile)\\.codex\\auth.json",
            assistantApplicationData: "\(appData)\\AI接入助手",
            transactionMutexName: "Local\\AIAccessAssistant.ProviderSwitch"
        )
    }
}

struct WindowsFileMetadata: Codable, Equatable {
    let securityDescriptorSDDL: String
    let attributes: UInt32
    let creationTime: UInt64?
    let lastWriteTime: UInt64?
}

protocol WindowsAtomicFileReplacing {
    func snapshotMetadata(path: String) throws -> WindowsFileMetadata
    func replaceFileAtomically(
        destination: String,
        temporary: String,
        expectedSHA256: String?,
        metadata: WindowsFileMetadata
    ) throws
    func flushFile(path: String) throws
    func flushDirectory(path: String) throws
}

protocol WindowsCredentialStoring {
    func readGenericCredential(targetName: String) throws -> Data?
    func writeGenericCredential(targetName: String, secret: Data) throws
    func deleteGenericCredential(targetName: String) throws
}

protocol WindowsProcessControlling {
    func runningConfigurationWriters() throws -> [String]
    func requestGracefulExit(processIdentifier: UInt32) throws
    func launchCodex(environment: [String: String]) throws -> UInt32
    func waitForExit(processIdentifier: UInt32, timeoutMilliseconds: UInt32) throws -> Bool
}

protocol WindowsPackageVerifying {
    func verifySHA256(path: String, expected: String) throws
    func verifyAuthenticode(path: String, expectedPublisher: String) throws
    func verifyPackageIdentity(path: String, packageFamilyName: String?, productCode: String?) throws
}

struct WindowsRuntimeImplementationChecklist: Codable, Equatable {
    let nativeUIBuilt: Bool
    let credentialManagerAdapterBuilt: Bool
    let replaceFileAdapterBuilt: Bool
    let namedMutexBuilt: Bool
    let processLauncherBuilt: Bool
    let msixOrExeBuilt: Bool
    let authenticodeSigned: Bool
    let x64Tested: Bool
    let installerRollbackTested: Bool

    var complete: Bool {
        nativeUIBuilt
            && credentialManagerAdapterBuilt
            && replaceFileAdapterBuilt
            && namedMutexBuilt
            && processLauncherBuilt
            && msixOrExeBuilt
            && authenticodeSigned
            && x64Tested
            && installerRollbackTested
    }
}
