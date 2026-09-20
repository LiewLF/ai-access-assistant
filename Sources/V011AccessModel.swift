import AppKit
import Foundation
/// Stable, production-owned accessibility metadata for the beginner status
/// cards.  The UI consumes these identifiers while the focused fixture tests
/// traversal and large-type copy without launching the live application.
struct V011AccessibilityCardContract: Equatable, Sendable {
    let identifier: String
    let title: String
    let value: String
    let detail: String
    let sortPriority: Double
    var voiceOverLabel: String {
        "\(title)：\(value)"
    }
    var voiceOverHint: String { detail }
}
enum V011AccessibilityContract {
    static let configurationCardID = "beginner.configuration-outcome"
    static let sessionCardID = "beginner.session-outcome"
    static func cards(
        configurationOutcome: String,
        sessionOutcome: String
    ) -> [V011AccessibilityCardContract] {
        [
            V011AccessibilityCardContract(
                identifier: configurationCardID,
                title: "配置状态",
                value: configurationOutcome,
                detail: "配置提交独立于历史会话整理",
                sortPriority: 2
            ),
            V011AccessibilityCardContract(
                identifier: sessionCardID,
                title: "会话状态",
                value: sessionOutcome,
                detail: "失败可重试，不回滚已提交配置",
                sortPriority: 1
            ),
        ]
    }
    static let traversalOrder = [configurationCardID, sessionCardID]
    static func preservesLargeType(_ card: V011AccessibilityCardContract) -> Bool {
        !card.voiceOverLabel.isEmpty
            && !card.voiceOverHint.isEmpty
            && !card.voiceOverLabel.contains("…")
            && !card.voiceOverHint.contains("…")
    }
}
@MainActor
final class V011AccessModel:
    ObservableObject,
    V011AccessRefreshControllerDelegate,
    V011UserReadinessControllerDelegate,
    V011ConnectionVerificationControllerDelegate,
    V011SavedRelayControllerDelegate,
    V011CapabilityEvidenceControllerDelegate,
    V011RelayProfileControllerDelegate,
    V011RecoveryControllerDelegate,
    V011SwitchControllerDelegate,
    V011PortableContinuityControllerDelegate {
    @Published private(set) var liveState:
        LiveCodexState?
    @Published private(set) var managedState =
        V011ManagedState.empty
    @Published private(set) var isWorking = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshObservation:
        V011RefreshObservation?
    @Published private(set) var isCheckingCurrentConnection =
        false
    @Published private(set) var isVerifyingAgentLoop = false
    @Published private(set) var preflightingSavedRelayID:
        String?
    @Published private(set) var savedRelayPreflightResults:
        [String: V011SavedRelayPreflightResult] = [:]
    @Published private(set) var hasPendingRecovery =
        false
    @Published private(set) var hasPendingPortableContinuityImport =
        false
    @Published private(set) var portableContinuityRecoveryError:
        String?
    @Published private(set) var recoveryDisposition:
        V011RecoveryDisposition = .unread
    @Published private(set) var recoveryRepairPreview:
        V014RecoveryRepairPreview?
    @Published private(set) var isCurrentConnectionVerified =
        false
    @Published private(set) var recoveryFailureStageText:
        String?
    @Published private(set) var recoveryNextAction: String?
    @Published private(set) var recoveryProtectsNewSessions =
        false
    /// Redacted details loaded during explicit refresh or export.
    @Published private(set) var recoveryDiagnosticSummary = """
    transaction_id=unavailable
    phase=unavailable
    failure_code=unavailable
    journal_size_bytes=unavailable
    config_hash=unavailable
    session_attempt=unavailable
    """

    func copyRecoveryDiagnosticSummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            recoveryDiagnosticSummary,
            forType: .string
        )
    }

    private func diagnosticEvidenceFreshness(
        at now: Date
    ) -> V013DiagnosticEvidenceFreshness {
        supportEvidenceService.diagnosticEvidenceFreshness(
            connectionObservation:
                currentConnectionHealthObservation,
            agentLoopReceipt: agentLoopReceipt,
            agentLoopTargetsCurrentState:
                agentLoopReceipt.map(
                    agentLoopReceiptTargetsCurrentState
                ) ?? false,
            compatibilityEvidence: compatibilityEvidence,
            officialUsageSnapshot: officialUsageSnapshot,
            at: now
        )
    }

    func exportRedactedSupportBundle(
        readiness: V016AccessReadinessDecision,
        to destinationURL: URL,
        userConfirmed: Bool
    ) throws {
        let now = dependencies.now()
        recoveryDiagnosticExportURL = try supportEvidenceService
            .exportRedactedSupportBundle(
            readiness: readiness,
            freshness: diagnosticEvidenceFreshness(at: now),
            to: destinationURL,
            userConfirmed: userConfirmed,
            exportedAt: now
        )
        status = "已导出脱敏求助包；未联网、未上传"
    }

    func exportManagedConfigurationSnapshot() {
        do {
            managedSnapshotExportURL = try supportEvidenceService
                .exportManagedConfigurationSnapshot()
            status = "已导出脱敏配置快照；未修改当前设置"
        } catch {
            errorMessage = "配置快照导出失败：\(V011RecoveryErrorText.safeDetail(error))"
        }
    }

    /// Parses a previously exported snapshot without touching configuration,
    /// session files, processes, credentials, or receipts.
    func previewConfigurationImport(
        snapshot: V011ManagedConfigurationSnapshot,
        currentData: Data
    ) -> V011SnapshotImportDryRun {
        supportEvidenceService.previewConfigurationImport(
            snapshot: snapshot,
            currentData: currentData
        )
    }

    /// Read-only audit adapter. It inspects existing journals/receipts and
    /// reports zero writes as part of the returned evidence.
    func readOnlyAuditReport() -> V011ReadOnlyAuditReport {
        supportEvidenceService.readOnlyAuditReport(
            configurationHash: liveState?.configHash,
            configurationOutcome: configurationOutcome,
            sessionOutcome: sessionOutcome
        )
    }
    @Published private(set) var compatibilityEvidence:
        CodexCompatibilityEvidence?
    @Published private(set) var currentConnectionCheckError:
        String?
    @Published private(set) var currentConnectionReceipt: V011ConnectionReceipt?
    @Published private(set) var agentLoopReceipt: V011AgentLoopReceipt?
    @Published private(set) var agentLoopCompletedUsage: V012CompletedTurnUsage?
    @Published private(set) var isAgentLoopVerified = false
    @Published private(set) var agentLoopErrorMessage: String?
    private var agentLoopFailureState = V011AgentLoopFailureState()
    private var wasCurrentConnectionVerifiedBeforeCheck = false
    @Published private(set) var officialUsageSnapshot: V011OfficialUsageSnapshot?
    @Published private(set) var isRefreshingOfficialUsage = false
    @Published private(set) var officialUsageErrorMessage: String?
    @Published private(set) var officialUsageFailurePresentation: V013FailurePresentation?
    @Published private(set) var officialUsageRefreshFailedAt: Date?
    @Published private(set) var savedRelayReadinessReceipts: [String: V011SavedRelayReadinessReceipt] = [:]
    @Published private(set) var savedRelayReadinessMatches: [String: Bool] = [:]
    @Published private(set) var verifyingSavedRelayReadinessID:
        String?
    @Published private(set) var savedRelayReadinessErrors:
        [String: String] = [:]
    @Published private(set) var connectionHealthHistory:
        [V011ConnectionHealthObservation] = []
    @Published private(set) var connectionHealthHistoryError:
        String?
    @Published private(set) var verifiedEndpointHost: String?
    @Published private(set) var currentSessionProviderCheck:
        V011SessionProviderCheck?
    @Published private(set) var currentRuntimeFreshness:
        V011RuntimeFreshness = .unknown
    @Published private(set) var recoveryDiagnosticExportURL: URL?
    @Published private(set) var managedSnapshotExportURL: URL?
    @Published private(set) var providerProbeReceipts:
        [ProviderCapabilityProbeReceipt] = []
    @Published private(set) var capabilityEvidenceErrorMessage:
        String?
    @Published var status = "正在读取Codex当前状态"
    @Published var errorMessage: String?
    /// Config and session outcomes are kept separately so a post-commit
    /// session failure cannot overwrite the committed configuration fact.
    @Published private(set) var configurationOutcome = "尚未读取"
    @Published private(set) var sessionOutcome = "尚未整理"

    private let dependencies: V011AccessDependencies
    private var currentConnectionCheckErrorConfigHash:
        String?
    private var currentConnectionCheckErrorProviderID:
        String?
    private lazy var refreshController =
        V011AccessRefreshController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var userReadinessController =
        V011UserReadinessController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var connectionVerificationController =
        V011ConnectionVerificationController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var savedRelayController =
        V011SavedRelayController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var capabilityEvidenceController =
        V011CapabilityEvidenceController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var relayProfileController =
        V011RelayProfileController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var recoveryController =
        V011RecoveryController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var switchController =
        V011SwitchController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var portableContinuityController =
        V011PortableContinuityController(
            dependencies: dependencies,
            delegate: self
        )

    init(
        dependencies: V011AccessDependencies = .live
    ) {
        self.dependencies = dependencies
        reloadConnectionHealthHistory()
        loadUserReadinessEvidence()
        loadPassivePresentationState()
        refreshPortableContinuityRecoveryState()
        if dependencies.allowsUnpromptedRefresh {
            requestRefresh(reason: .initial, debounceNanoseconds: 0)
        } else {
            preparePresentation()
        }
    }

    var savedProfiles: [CodexRelayProfile] {
        managedState.relayProfiles
    }

    func preparePortableContinuityImport(
        from sourceURL: URL
    ) async throws -> PortableContinuityImportSession {
        try await portableContinuityController.prepare(
            from: sourceURL
        )
    }

    func applyPortableContinuityImport(
        _ request: PortableContinuityApplyRequest
    ) async throws -> PortableContinuityApplyResult {
        try await portableContinuityController.apply(request)
    }

    func recoverPortableContinuityImport() async throws -> Int {
        try await portableContinuityController.recoverPending()
    }

    func refreshPortableContinuityRecoveryState() {
        portableContinuityController.refreshRecoveryState()
    }

    var allowsPortableContinuityActionStart: Bool {
        !isWorking
    }

    var portableContinuityProtectedProviderID: String? {
        liveState.map(V011ConnectionHealthService.providerID)
    }

    func portableContinuityActionDidBegin(status: String) {
        isWorking = true
        self.status = status
    }

    func portableContinuityActionDidApply(
        _ snapshot: V011PortableContinuityReloadSnapshot
    ) {
        if let state = snapshot.managedState {
            managedState = state
        }
        portableContinuityRecoveryStateDidChange(snapshot.recovery)
    }

    func portableContinuityActionDidSucceed(status: String) {
        self.status = status
    }

    func portableContinuityActionDidBecomeIdle() {
        isWorking = false
    }

    func portableContinuityRecoveryStateDidChange(
        _ recovery: V011PortableContinuityRecoveryState
    ) {
        hasPendingPortableContinuityImport = recovery.hasPendingImport
        portableContinuityRecoveryError = recovery.errorMessage
    }

    var officialUsageRefreshAvailability: V011OfficialUsageRefreshAvailability {
        V011OfficialUsageRefreshAvailability(
            isBusy: isRefreshingOfficialUsage || isWorking || isVerifyingAgentLoop
                || verifyingSavedRelayReadinessID != nil)
    }

    var canRefreshOfficialUsage: Bool {
        officialUsageRefreshAvailability == .available
    }

    var currentConnectionFailurePresentation: V013FailurePresentation? {
        connectionPresentation.currentConnectionFailurePresentation
    }

    var compatibilityFailurePresentation:
        V013FailurePresentation? {
        V013FailurePresentation.compatibility(
            compatibilityEvidence
        )
    }

    var agentLoopFailurePresentation: V013FailurePresentation? {
        connectionPresentation.agentLoopFailurePresentation
    }

    var officialUsageFreshnessText: String? {
        guard let snapshot = officialUsageSnapshot else {
            return nil
        }
        let prefix = snapshot.isFresh(at: dependencies.now())
            ? "上次成功读取，仍在有效期内" : "上次成功读取，已过期"
        return "\(prefix) · \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var officialUsageCardPresentation: V011OfficialUsageCardPresentation {
        V011OfficialUsageCardPresentation.make(
            snapshot: officialUsageSnapshot,
            now: dependencies.now(),
            refreshFailedAt: officialUsageRefreshFailedAt,
            refreshAvailability: officialUsageRefreshAvailability)
    }

    func refreshOfficialUsage(threadID: String? = nil) {
        userReadinessController.refreshOfficialUsage(threadID: threadID)
    }

    var officialUsageRefreshUnavailableReason: String? {
        officialUsageRefreshAvailability.unavailableReason
    }

    func userReadinessOfficialUsageDidReject(_ message: String) {
        officialUsageErrorMessage = message
    }

    func userReadinessOfficialUsageDidBegin() {
        isRefreshingOfficialUsage = true
        officialUsageErrorMessage = nil
        officialUsageFailurePresentation = nil
        officialUsageRefreshFailedAt = nil
    }

    func userReadinessOfficialUsageDidBecomeIdle() {
        isRefreshingOfficialUsage = false
    }

    func userReadinessOfficialUsageDidReceive(_ outcome: V011OfficialUsageRefreshOutcome) {
        switch outcome {
        case let .success(snapshot):
            officialUsageSnapshot = snapshot
            officialUsageErrorMessage = nil
            officialUsageFailurePresentation = nil
            officialUsageRefreshFailedAt = nil
        case let .failure(presentation):
            officialUsageFailurePresentation = presentation
            officialUsageErrorMessage = presentation.conclusion
            officialUsageRefreshFailedAt = dependencies.now()
        case .cancelled:
            return
        }
    }

    func canVerifySavedRelayReadiness(
        _ profile: CodexRelayProfile
    ) -> Bool {
        managedState.relayProfiles.contains(profile)
            && verifyingSavedRelayReadinessID == nil
            && !isWorking
            && !isRefreshing
            && !isVerifyingAgentLoop
            && !isRefreshingOfficialUsage
    }

    func savedRelayReadinessState(
        for profile: CodexRelayProfile
    ) -> V011SavedRelayReadinessState {
        V011UserReadinessCoordinator.state(
            for: profile,
            verifyingProfileID: verifyingSavedRelayReadinessID,
            errors: savedRelayReadinessErrors,
            receipts: savedRelayReadinessReceipts,
            matches: savedRelayReadinessMatches,
            now: dependencies.now()
        )
    }

    func savedRelayReadinessStatus(
        for profile: CodexRelayProfile
    ) -> String {
        V011UserReadinessCoordinator.status(
            for: profile,
            state: savedRelayReadinessState(for: profile),
            errors: savedRelayReadinessErrors,
            receipts: savedRelayReadinessReceipts
        )
    }

    func verifySavedRelayReadiness(
        _ profile: CodexRelayProfile,
        userConsented: Bool
    ) {
        userReadinessController.verifySavedRelayReadiness(
            profile,
            userConsented: userConsented
        )
    }

    var userReadinessSavedRelayReceiptsForCommit:
        [String: V011SavedRelayReadinessReceipt] {
        savedRelayReadinessReceipts
    }

    func userReadinessSavedRelayProfileIsCurrent(
        _ profile: CodexRelayProfile
    ) -> Bool {
        managedState.relayProfiles.contains(profile)
    }

    func userReadinessSavedRelayDidReject(
        profileID: String, message: String
    ) {
        savedRelayReadinessErrors[profileID] = message
    }

    func userReadinessSavedRelayDidBegin(profileID: String) {
        verifyingSavedRelayReadinessID = profileID
        savedRelayReadinessErrors.removeValue(forKey: profileID)
    }

    func userReadinessSavedRelayDidBecomeIdle() {
        verifyingSavedRelayReadinessID = nil
    }

    func userReadinessSavedRelayDidReceive(
        profileID: String,
        outcome: V011SavedRelayReadinessCommitOutcome
    ) {
        switch outcome {
        case let .success(receipts, matches):
            savedRelayReadinessReceipts = receipts
            savedRelayReadinessMatches[profileID] = matches
            savedRelayReadinessErrors.removeValue(forKey: profileID)
        case let .failure(message):
            savedRelayReadinessErrors[profileID] = message
        }
    }

    private func loadUserReadinessEvidence() {
        let evidence = userReadinessController.loadEvidence()
        officialUsageSnapshot = evidence.officialUsage
        if evidence.officialUsageLoadFailed {
            let presentation = V013FailurePresentation
                .officialUsage(V011OfficialUsageError.unsafeEvidence)
            officialUsageFailurePresentation = presentation
            officialUsageErrorMessage = presentation.conclusion
        }
        savedRelayReadinessReceipts =
            evidence.savedRelayReceipts
        savedRelayReadinessMatches = [:]
    }

    func savedRelayPreflightResult(
        for profile: CodexRelayProfile
    ) -> V011SavedRelayPreflightResult? {
        guard let result =
                savedRelayPreflightResults[profile.id],
              result.profile == profile else {
            return nil
        }
        return result
    }

    func canPreflightSavedRelay(
        _ profile: CodexRelayProfile
    ) -> Bool {
        managedState.relayProfiles.contains(profile)
            && currentProviderID
                != profile.v011ProviderID
            && preflightingSavedRelayID == nil
            && allowsSwitching
    }

    var currentProviderID: String? {
        connectionPresentation.currentProviderID
    }

    var connectionHealthProviderSummaries:
        [V011ConnectionHealthProviderSummary] {
        connectionPresentation.connectionHealthProviderSummaries
    }

    var currentConnectionRescueAdvice:
        V011ConnectionHealthAdvice {
        connectionPresentation.currentConnectionRescueAdvice
    }

    var currentConnectionHealthObservation:
        V011ConnectionHealthObservation? {
        connectionPresentation.currentConnectionHealthObservation
    }

    var currentCodexContractID: String? {
        connectionPresentation.currentCodexContractID
    }

    var currentRelayProfileID: String? {
        connectionPresentation.currentRelayProfileID
    }

    var currentRelayProfile: CodexRelayProfile? {
        connectionPresentation.currentRelayProfile
    }

    /// Executes the user-confirmed Build 65 catalog copy through the existing
    /// managed-profile writer path. The external file is re-read and hashed
    /// immediately before import so a changed source fails closed.
    func copyExternalModelCatalogAsManaged(
        _ request: Build65CatalogCopyRequest
    ) {
        capabilityEvidenceController.copyExternalCatalog(request)
    }

    var currentCapabilityProfileSHA256: String? {
        connectionPresentation.currentCapabilityProfileSHA256
    }

    var codexHomeURL: URL {
        dependencies.codexHome
    }

    var controlRootURL: URL {
        dependencies.controlRoot
    }

    var runningBuildDiagnosticSummary: String {
        let evidence = V011RunningBuildEvidence.current(
            now: dependencies.now()
        )
        return evidence.version
            + " ("
            + evidence.build
            + ") · "
            + evidence.bundleClass.rawValue
    }

    var currentDisplayName: String {
        connectionPresentation.currentDisplayName
    }

    var currentEndpointHost: String? {
        connectionPresentation.currentEndpointHost
    }

    var canCheckCurrentConnection: Bool {
        connectionPresentation.canCheckCurrentConnection
    }

    var canVerifyRealAgentLoop: Bool {
        connectionPresentation.canVerifyRealAgentLoop
    }

    var hasCurrentBasicConnectionEvidence: Bool {
        connectionPresentation.hasCurrentBasicConnectionEvidence
    }

    var canRunDeterministicRepair: Bool {
        recoveryPresentation.canRunDeterministicRepair
    }

    var agentLoopVerificationSummary: String {
        connectionPresentation.agentLoopVerificationSummary
    }

    var deterministicRepairPreviewSummary: String {
        recoveryPresentation.deterministicRepairPreviewSummary
    }

    var canRecoverPendingSwitch: Bool {
        recoveryPresentation.canRecoverPendingSwitch
    }

    var recoveryStatusTitle: String { recoveryPresentation.statusTitle }

    var hasExecutableRecoveryAction: Bool {
        recoveryPresentation.hasExecutableRecoveryAction
    }

    var canKeepCurrentStateAndEndPendingSwitch: Bool {
        recoveryPresentation.canKeepCurrentStateAndEndPendingSwitch
    }

    /// The recovery-safe action is configuration-only; historical sessions
    /// are intentionally left untouched when the inner journal is unsafe.
    var canKeepCurrentConfigurationAndEndPendingSwitch: Bool {
        canKeepCurrentStateAndEndPendingSwitch
    }

    var configurationOnlyRecoveryActionTitle: String {
        "只处理设置，不处理历史会话"
    }

    var canAcceptCurrentRelayAndEndPendingSwitch: Bool {
        recoveryPresentation
            .canAcceptCurrentRelayAndEndPendingSwitch
    }

    var currentConnectionVerificationSummary: String {
        connectionPresentation.currentConnectionVerificationSummary
    }

    var currentRuntimeFreshnessText: String {
        connectionPresentation.currentRuntimeFreshnessText
    }

    var currentSessionProviderCheckText: String {
        connectionPresentation.currentSessionProviderCheckText
    }

    var currentConnectionWarning: String? {
        connectionPresentation.currentConnectionWarning
    }

    private var hasFreshConnectionReceipt: Bool {
        connectionPresentation.hasFreshConnectionReceipt
    }

    var needsCurrentRelayAdoption: Bool {
        connectionPresentation.needsCurrentRelayAdoption
    }

    var allowsSwitching: Bool {
        recoveryPresentation.allowsSwitching
    }

    var canSwitchToOfficial: Bool {
        recoveryPresentation.canSwitchToOfficial
    }

    var hasTrustedOfficialRootOverlay: Bool {
        recoveryPresentation.hasTrustedOfficialRootOverlay
    }

    var canEstablishOfficialRecoveryInfo: Bool {
        recoveryPresentation.canEstablishOfficialRecoveryInfo
    }

    var cutoverRecoveryPlan: FableCutoverRecoveryPlan {
        recoveryPresentation.cutoverRecoveryPlan
    }

    var cutoverRecoverySummary: String {
        recoveryPresentation.cutoverRecoverySummary
    }

    var switchingBlockMessage: String? {
        recoveryPresentation.switchingBlockMessage
    }

    private func pendingRecoveryBlockMessage(
        action: String
    ) -> String {
        recoveryPresentation.pendingRecoveryBlockMessage(
            action: action
        )
    }

    nonisolated static func isRelevantCodexApplication(
        bundleIdentifier: String?
    ) -> Bool {
        bundleIdentifier == CodexApplicationLocator.bundleIdentifier
    }

    func preparePresentation() {
        guard liveState == nil, !isWorking, !isRefreshing else { return }
        do {
            let snapshot = try V011PassiveAccessStateReader.read(
                dependencies: dependencies, managedState: managedState)
            liveState = snapshot.live
            currentConnectionReceipt = snapshot.connectionReceipt
            agentLoopReceipt = snapshot.agentLoopReceipt
            applyRecoveryContext(snapshot.recovery)
            errorMessage = snapshot.errorMessage ?? snapshot.recovery.detail
            status = snapshot.status
        } catch {
            status = "暂时无法读取Codex当前接入"
            errorMessage = V011RecoveryErrorText.safeDetail(error)
        }
    }

    func refresh() {
        guard !isRefreshing,
              !isCheckingCurrentConnection,
              !isVerifyingAgentLoop,
              !isRefreshingOfficialUsage,
              verifyingSavedRelayReadinessID == nil,
              !isWorking else { return }
        requestRefresh(reason: .manual, debounceNanoseconds: 0)
    }

    func requestRefresh(
        reason: V011RefreshReason,
        debounceNanoseconds: UInt64 = 250_000_000
    ) {
        refreshController.request(
            reason: reason,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    var allowsAccessRefreshStart: Bool {
        !isRefreshing
            && !isCheckingCurrentConnection
            && !isVerifyingAgentLoop
            && !isRefreshingOfficialUsage
            && verifyingSavedRelayReadinessID == nil
            && !isWorking
    }

    func accessRefreshPreparePresentation() {
        preparePresentation()
    }

    func accessRefreshConnectionFailureScope()
        -> V011ConnectionFailureScope {
        V011ConnectionFailureScope(
            hasFailure: currentConnectionCheckError != nil,
            configHash: currentConnectionCheckErrorConfigHash,
            providerID: currentConnectionCheckErrorProviderID
        )
    }

    func accessRefreshDidBegin(status: String) {
        isRefreshing = true
        self.status = status
    }

    func accessRefreshDidReceive(
        _ outcome: V011AccessRefreshOutcome
    ) {
        switch outcome {
        case let .loaded(loaded):
            applyRefreshLoaded(loaded)
        case let .failed(failed):
            applyRefreshFailed(failed)
        }
    }

    func accessRefreshDidBecomeIdle() {
        isRefreshing = false
    }

    func accessRefreshDidFinish(
        _ observation: V011RefreshObservation
    ) {
        lastRefreshObservation = observation
    }

    func accessRefreshDidObserveRecovery(
        _ recovery: V011PendingRecoveryContext
    ) {
        applyRecoveryContext(recovery)
        guard recovery.pending else { return }
        status = recovery.disposition == .decisionRequired
            ? "上次切换没有完成，当前设置已保留"
            : "发现上次未完成的操作，可继续最小修复"
    }

    private func applyRecoveryContext(_ recovery: V011PendingRecoveryContext?) {
        guard let recovery else {
            recoveryDisposition = .unread
            return
        }
        hasPendingRecovery = recovery.pending
        recoveryDisposition = recovery.disposition
        recoveryFailureStageText = recovery.stage
        recoveryNextAction = recovery.nextAction
        recoveryProtectsNewSessions = recovery.protectsNewSessions
        recoveryRepairPreview = recovery.preview
    }

    private func applyRefreshLoaded(
        _ loaded: V011AccessRefreshLoaded
    ) {
        let result = loaded.state
        let recovery = loaded.recovery
        let presentation = loaded.presentation
        managedState = result.managed
        liveState = result.live
        compatibilityEvidence = result.compatibilityEvidence
        applyRecoveryContext(recovery)
        currentConnectionReceipt = result.connectionReceipt
        agentLoopReceipt = result.agentLoopReceipt
        agentLoopErrorMessage = agentLoopFailureState.refresh(live: result.live)
            ?? presentation.agentLoopErrorMessage
        isAgentLoopVerified = result.agentLoopMatches && agentLoopErrorMessage == nil
        savedRelayReadinessReceipts =
            result.savedRelayReadinessReceipts
        savedRelayReadinessMatches = result.savedRelayReadinessMatches
        recoveryDiagnosticSummary = result.recoveryDiagnosticSummary
        capabilityEvidenceController.reloadReceipts()
        if presentation.shouldClearConnectionFailure {
            currentConnectionCheckError = nil
            currentConnectionCheckErrorConfigHash = nil
            currentConnectionCheckErrorProviderID = nil
        }
        isCurrentConnectionVerified =
            presentation.isCurrentConnectionVerified
        currentRuntimeFreshness = result.runtimeFreshness
        verifiedEndpointHost = presentation.verifiedEndpointHost
        currentSessionProviderCheck =
            presentation.currentSessionProviderCheck
        status = presentation.status
        errorMessage = presentation.errorMessage
    }

    private func applyRefreshFailed(
        _ failed: V011AccessRefreshFailed
    ) {
        liveState = nil
        compatibilityEvidence = nil
        isCurrentConnectionVerified = false
        currentRuntimeFreshness = .unknown
        agentLoopReceipt = nil
        isAgentLoopVerified = false
        agentLoopErrorMessage = nil
        savedRelayReadinessMatches = [:]
        applyRecoveryContext(failed.recovery)
        status = failed.status
        errorMessage = failed.errorMessage
    }

    func detectCurrentConnection(userConsented: Bool) {
        connectionVerificationController.detectCurrentConnection(userConsented: userConsented)
    }
    func cancelCurrentConnection() {
        connectionVerificationController.cancelCurrentConnection()
    }

    var connectionVerificationLiveState: LiveCodexState? { liveState }

    func connectionVerificationCurrentContext()
        -> V011CurrentConnectionActionContext {
        V011CurrentConnectionActionContext(
            managedState: managedState,
            hasPendingRecovery: hasPendingRecovery,
            recoveryDisposition: recoveryDisposition,
            currentProviderID: currentProviderID,
            currentLiveState: liveState
        )
    }

    func connectionVerificationDidRejectCurrentCheck(_ message: String) {
        currentConnectionCheckError = message
    }

    func connectionVerificationCurrentCheckDidBegin() {
        wasCurrentConnectionVerifiedBeforeCheck = isCurrentConnectionVerified
        isCheckingCurrentConnection = true
        isCurrentConnectionVerified = false
        currentConnectionCheckError = nil
        currentConnectionCheckErrorConfigHash = nil
        currentConnectionCheckErrorProviderID = nil
        verifiedEndpointHost = nil
        currentSessionProviderCheck = nil
    }

    func connectionVerificationCurrentCheckDidReceive(_ outcome: V011CurrentConnectionActionOutcome) {
        switch outcome {
        case .cancelled:
            isCurrentConnectionVerified = currentConnectionReceipt.map { receipt in
                guard wasCurrentConnectionVerifiedBeforeCheck, let live = liveState,
                      let data = try? Data(contentsOf: live.configURL),
                      TOMLSemanticEngine.sha256(data) == live.configHash else { return false }
                return V011ConnectionHealthService.receiptMatches(receipt, live: live, at: dependencies.now())
            } ?? false
            verifiedEndpointHost = isCurrentConnectionVerified ? currentConnectionReceipt?.endpointHost : nil
            currentSessionProviderCheck = isCurrentConnectionVerified ? currentConnectionReceipt?.sessionProviderCheck : nil
            status = "基础连接检测已取消；已发送请求的用量以账户记录为准。"
        case let .verified(check, status, capability, history):
            let result = check.verification
            applyCurrentConnectionCapabilityUpdate(capability)
            currentConnectionReceipt = check.receipt
            liveState = result.state
            verifiedEndpointHost = check.endpointHost
            currentSessionProviderCheck = result.sessionProviderCheck
            currentRuntimeFreshness = check.runtimeFreshness
            isCurrentConnectionVerified = check.isVerified
            currentConnectionCheckError = nil
            currentConnectionCheckErrorConfigHash = nil
            currentConnectionCheckErrorProviderID = nil
            self.status = status
            applyCurrentConnectionHistoryUpdate(history)
        case let .probeFailed(
            failure, runtimeFreshness, status, history
        ):
            liveState = failure.state
            currentRuntimeFreshness = runtimeFreshness
            currentSessionProviderCheck = failure.sessionProviderCheck
            currentConnectionCheckError = failure.safeMessage
            currentConnectionCheckErrorConfigHash = failure.configHash
            currentConnectionCheckErrorProviderID = failure.providerID
            isCurrentConnectionVerified = false
            self.status = status
            applyCurrentConnectionHistoryUpdate(history)
        case let .failed(safeError, history):
            currentConnectionCheckError = safeError
            currentConnectionCheckErrorConfigHash = nil
            currentConnectionCheckErrorProviderID = nil
            isCurrentConnectionVerified = false
            applyCurrentConnectionHistoryUpdate(history)
        }
    }

    func connectionVerificationCurrentCheckDidBecomeIdle() {
        isCheckingCurrentConnection = false
    }

    func verifyRealAgentLoop(userConsented: Bool) {
        connectionVerificationController.verifyRealAgentLoop(userConsented: userConsented)
    }

    func connectionVerificationDidRejectAgentLoop(_ message: String) {
        agentLoopErrorMessage = message
    }

    func connectionVerificationAgentLoopDidBegin() {
        agentLoopFailureState.begin(live: liveState)
        isVerifyingAgentLoop = true
        isAgentLoopVerified = false
        agentLoopCompletedUsage = nil
        agentLoopErrorMessage = nil
        status = "正在隔离环境验证真实工具调用和续答"
    }

    func connectionVerificationAgentLoopDidVerify(
        _ result: V011AgentLoopVerificationResult
    ) {
        liveState = result.currentState.live
        compatibilityEvidence = result.currentState.compatibilityEvidence
        currentRuntimeFreshness = result.currentState.runtimeFreshness
        hasPendingRecovery = result.currentState.pending
        applyAgentLoopResult(result.probeResult, matchesCurrent: result.matchesCurrent)
        status = result.matchesCurrent ? "真实任务闭环已通过" : "真实任务证据与当前状态不匹配"
    }

    func connectionVerificationAgentLoopDidFail(_ message: String) {
        isAgentLoopVerified = false
        agentLoopFailureState.fail(message)
        agentLoopErrorMessage = message
        status = "真实任务验证未完成；当前配置未修改"
    }

    func connectionVerificationAgentLoopDidBecomeIdle() {
        isVerifyingAgentLoop = false
    }

    func preflightSavedRelay(
        _ profile: CodexRelayProfile
    ) {
        savedRelayController.preflight(profile)
    }

    var allowsSavedRelayMutationStart: Bool {
        !isWorking && !isRefreshing && !isCheckingCurrentConnection
    }

    func savedRelayPendingRecoveryBlockMessage(
        action: String
    ) -> String {
        pendingRecoveryBlockMessage(action: action)
    }

    func savedRelayActionDidReject(_ message: String) {
        errorMessage = message
    }

    func savedRelayPreflightDidBegin(
        profile: CodexRelayProfile
    ) {
        let profileID = profile.id
        preflightingSavedRelayID = profileID
        savedRelayPreflightResults[profileID] =
            V011SavedRelayPreflightResult(
                profile: profile,
                outcome: .checking,
                checkedAt: nil,
                detail:
                    "正在发送一次最小Responses请求；当前模式不会改变"
            )
        isWorking = true
        status = "正在检测“\(profile.name)”，当前Codex模式不会改变"
        errorMessage = nil
    }

    func savedRelayPreflightDidReceive(
        profileID: String,
        outcome: V011SavedRelayPreflightActionOutcome
    ) {
        savedRelayPreflightResults[profileID] = outcome.result
        status = outcome.status
    }

    func savedRelayPreflightDidBecomeIdle(profileID: String) {
        if preflightingSavedRelayID == profileID {
            preflightingSavedRelayID = nil
        }
        isWorking = false
    }

    func deleteSavedRelay(
        _ profile: CodexRelayProfile
    ) {
        savedRelayController.delete(profile)
    }

    func savedRelayDeleteDidBegin(profile: CodexRelayProfile) {
        isWorking = true
        errorMessage = nil
        status = "正在删除“\(profile.name)”；当前Codex模式不会改变"
    }

    func savedRelayDeleteDidReceive(
        profileID: String,
        outcome: V011SavedRelayDeleteOutcome
    ) {
        switch outcome {
        case let .success(state, status):
            managedState = state
            savedRelayPreflightResults.removeValue(forKey: profileID)
            self.status = status
            errorMessage = nil
        case let .failure(state, _, status, safeError):
            if let state { managedState = state }
            self.status = status
            errorMessage = safeError
        }
    }

    var isAddingRelay: Bool { savedRelayController.isAdding }
    func cancelAddingRelay() { savedRelayController.cancelAddition() }
    func addRelay(draft: CodexRelayProfile, apiKey: String) {
        savedRelayController.add(draft: draft, apiKey: apiKey)
    }

    func savedRelayAddDidBegin() {
        isWorking = true
        status = "正在验证中转，当前Codex设置不会改变"
    }

    func savedRelayAddDidReceive(
        _ outcome: V011SavedRelayAddOutcome
    ) {
        switch outcome {
        case let .success(result, status):
            managedState = result.managedState
            self.status = status
            errorMessage = nil
        case let .failure(status, errorMessage):
            self.status = status
            self.errorMessage = errorMessage
        }
    }

    func savedRelayMutationDidBecomeIdle() {
        isWorking = false
    }

    func savedRelayActionRequestsRefresh() {
        requestRefresh(reason: .manual, debounceNanoseconds: 0)
    }

    func runOptionalProviderCapabilityProbe(
        _ kind: ProviderCapabilityProbeKind,
        userConsented: Bool
    ) {
        capabilityEvidenceController.runOptionalProbe(
            kind,
            userConsented: userConsented
        )
    }

    var allowsCapabilityEvidenceActionStart: Bool {
        !isWorking && !isRefreshing && !isCheckingCurrentConnection
    }

    func capabilityEvidencePendingRecoveryBlockMessage(
        action: String
    ) -> String {
        pendingRecoveryBlockMessage(action: action)
    }

    func capabilityEvidenceActionDidReject(_ message: String) {
        errorMessage = message
    }

    func capabilityEvidenceOptionalProbeDidReject(
        _ message: String
    ) {
        capabilityEvidenceErrorMessage = message
    }

    func capabilityEvidenceValidateOptionalProbeExpectation(
        _ expected: V011OptionalProviderProbeExpectation
    ) throws {
        guard currentProviderID == expected.providerID,
              currentCodexContractID == expected.contractID,
              let profile = managedState.relayProfiles.first(where: {
                  $0.id == expected.profileID
                      && $0.v011ProviderID == expected.providerID
              }),
              try ProviderCapabilityProfileIdentity.sha256(
                  profile.effectiveCapabilityProfile
              ) == expected.profileHash else {
            throw V011ProviderCapabilityProbeRunError.stateChanged
        }
    }

    func capabilityEvidenceOptionalProbeDidBegin(
        kind: ProviderCapabilityProbeKind
    ) {
        isWorking = true
        errorMessage = nil
        capabilityEvidenceErrorMessage = nil
        status = "正在执行\(V011OptionalProviderProbeService.optionalProbeName(kind))真实探针"
    }

    func capabilityEvidenceOptionalProbeDidSucceed(
        _ result: V011OptionalProviderProbeActionResult
    ) {
        capabilityEvidenceController.invalidateReceiptReload()
        providerProbeReceipts = result.allReceipts
        status = result.differences.isEmpty
            ? "扩展能力真实探针已保存"
            : "普通Responses保持可用；以下能力仍有差异："
                + result.differences.joined(separator: "、")
        capabilityEvidenceErrorMessage = nil
    }

    func capabilityEvidenceOptionalProbeDidFail(
        _ message: String
    ) {
        status = "可选探针未完成；普通Responses和当前配置保持不变"
        capabilityEvidenceErrorMessage = message
    }

    func capabilityEvidenceOptionalProbeDidBecomeIdle() {
        isWorking = false
    }

    func importManagedModelCatalog(
        payload: Data,
        sourceName: String,
        sourceProfile: CodexRelayProfile
    ) {
        capabilityEvidenceController.importCatalog(
            payload: payload,
            sourceName: sourceName,
            sourceProfile: sourceProfile
        )
    }

    func capabilityEvidenceCatalogImportDidBegin() {
        isWorking = true
        errorMessage = nil
        status = "正在验证并复制受管模型目录"
    }

    func capabilityEvidenceCatalogImportDidReceive(
        request: V011ManagedModelCatalogActionRequest,
        outcome: V011ManagedModelCatalogActionOutcome
    ) {
        switch outcome {
        case let .success(result):
            capabilityEvidenceController.invalidateReceiptReload()
            providerProbeReceipts = result.allReceipts
            capabilityEvidenceErrorMessage = nil
            isWorking = false
            updateRelayCapabilities(
                sourceProfile: request.sourceProfile,
                targetProfile: result.targetProfile
            )
        case let .failure(status, errorMessage):
            isWorking = false
            self.status = status
            self.errorMessage = errorMessage
        }
    }

    func updateRelayCapabilities(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) {
        relayProfileController.updateCapabilities(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile
        )
    }

    func updateRelayProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        replacementAPIKey: String?
    ) {
        relayProfileController.updateProfile(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile,
            replacementAPIKey: replacementAPIKey
        )
    }

    func adoptCurrentRelay(
        displayName: String,
        replacementAPIKey: String
    ) {
        relayProfileController.adoptCurrentRelay(
            displayName: displayName,
            replacementAPIKey: replacementAPIKey
        )
    }

    var allowsRelayProfileActionStart: Bool {
        !isWorking && !isRefreshing && !isCheckingCurrentConnection
    }

    func relayProfilePendingRecoveryBlockMessage(
        action: String
    ) -> String {
        pendingRecoveryBlockMessage(action: action)
    }

    func relayProfileActionDidReject(_ message: String) {
        errorMessage = message
    }

    func relayProfileActionDidProgress(_ message: String) {
        status = message
    }

    func relayProfileUpdateDidBegin(status: String) {
        isWorking = true
        errorMessage = nil
        self.status = status
    }

    func relayProfileUpdateDidReceive(
        _ outcome: V011RelayUpdateActionOutcome
    ) {
        switch outcome {
        case let .success(result, status):
            liveState = result.liveState
            managedState = result.managedState
            isCurrentConnectionVerified = false
            self.status = status
            errorMessage = nil
        case let .failure(status, errorMessage, _):
            self.status = status
            self.errorMessage = errorMessage
        }
    }

    func relayProfileAdoptionDidBegin() {
        isWorking = true
        status = "正在接管当前中转，现有Codex设置不会改变"
    }

    func relayProfileAdoptionDidReceive(
        _ outcome: V011RelayAdoptionActionOutcome
    ) {
        switch outcome {
        case let .success(result, status):
            managedState = result.managedState
            liveState = result.liveState
            isCurrentConnectionVerified = false
            currentConnectionReceipt = nil
            verifiedEndpointHost = nil
            currentSessionProviderCheck = nil
            self.status = status
            errorMessage = nil
        case let .unchanged(status, errorMessage):
            self.status = status
            self.errorMessage = errorMessage
        case let .rolledBack(state, status, errorMessage):
            managedState = state
            hasPendingRecovery = false
            recoveryDisposition = .none
            self.status = status
            self.errorMessage = errorMessage
        case let .recoveryPending(status, errorMessage):
            hasPendingRecovery = true
            recoveryDisposition = .recoverable
            self.status = status
            self.errorMessage = errorMessage
        }
    }

    func relayProfileActionDidBecomeIdle() {
        isWorking = false
    }

    func relayProfileActionRequestsRefresh() {
        refresh()
    }

    func switchToOfficial() {
        switchController.switchToOfficial()
    }

    func establishOfficialRecoveryInfo() {
        recoveryController.establishOfficialRecoveryInfo()
    }

    func switchToRelay(_ profile: CodexRelayProfile) {
        switchController.switchToRelay(profile)
    }

    func recoverPendingSwitch() {
        recoveryController.recoverPendingSwitch()
    }

    func runDeterministicRepair(
        userConsented: Bool,
        expectedPreviewFingerprint: String
    ) {
        recoveryController.runDeterministicRepair(
            userConsented: userConsented,
            expectedPreviewFingerprint: expectedPreviewFingerprint
        )
    }

    func keepCurrentStateAndEndPendingSwitch() {
        keepCurrentConfigurationAndEndPendingSwitch()
    }

    func keepCurrentConfigurationAndEndPendingSwitch() {
        recoveryController
            .keepCurrentConfigurationAndEndPendingSwitch()
    }

    func acceptCurrentRelayAndEndPendingSwitch() {
        recoveryController
            .acceptCurrentRelayAndEndPendingSwitch()
    }

    var allowsRecoveryActionStart: Bool {
        !isWorking && !isRefreshing && !isCheckingCurrentConnection
    }

    var recoveryControllerUsesOfficialAccess: Bool {
        if case .official? = liveState?.mode { return true }
        return false
    }

    func recoveryActionDidReject(
        status: String?,
        errorMessage: String
    ) {
        if let status { self.status = status }
        self.errorMessage = errorMessage
    }

    func recoveryActionDidProgress(_ message: String) {
        status = message
    }

    func recoveryActionDidBegin(_ start: V011RecoveryActionStart) {
        isWorking = true
        errorMessage = nil
        status = start.status
        if start.protectsNewSessions {
            recoveryProtectsNewSessions = true
        }
        if start.resetsAgentLoop {
            agentLoopFailureState.clear()
            isAgentLoopVerified = false
            agentLoopErrorMessage = nil
        }
    }

    func recoveryActionDidReceiveOfficial(
        _ outcome: V011OfficialRecoveryActionOutcome
    ) {
        switch outcome {
        case let .success(result, status):
            managedState = result.managedState
            liveState = result.liveState
            self.status = status
            errorMessage = nil
        case let .failure(failure):
            status = failure.status
            errorMessage = failure.errorMessage
        }
    }

    func recoveryActionDidReceivePending(
        _ outcome: V011PendingRecoveryActionOutcome
    ) {
        switch outcome {
        case let .success(_, status):
            self.status = status
            errorMessage = nil
            recoveryFailureStageText = nil
            recoveryNextAction = nil
            recoveryProtectsNewSessions = false
        case let .failure(failure):
            status = failure.status
            errorMessage = failure.errorMessage
        }
    }

    func recoveryActionDidReceiveDeterministicRepair(
        _ outcome: V011DeterministicRepairActionOutcome
    ) {
        switch outcome {
        case let .completed(_, result, refreshed, status):
            liveState = refreshed.live
            managedState = refreshed.managed
            applyAgentLoopResult(
                result,
                matchesCurrent: refreshed.agentLoopMatches
            )
            self.status = status
            errorMessage = nil
            recoveryFailureStageText = nil
            recoveryNextAction = nil
            recoveryProtectsNewSessions = false
            recoveryRepairPreview = nil
        case let .previewChanged(context, status, errorMessage):
            hasPendingRecovery = context.pending
            recoveryDisposition = context.disposition
            recoveryRepairPreview = context.preview
            self.errorMessage = errorMessage
            self.status = status
        case let .failed(result, refreshed, status, errorMessage):
            if let refreshed {
                liveState = refreshed.live
                managedState = refreshed.managed
            }
            if let result {
                applyAgentLoopResult(result, matchesCurrent: false)
            }
            self.errorMessage = errorMessage
            self.status = status
        }
    }

    func recoveryActionDidReceiveKeepCurrent(
        _ outcome: V011KeepCurrentRecoveryActionOutcome
    ) {
        switch outcome {
        case let .success(_, status):
            self.status = status
            errorMessage = nil
        case let .failure(failure):
            status = failure.status
            errorMessage = failure.errorMessage
        }
    }

    func recoveryActionDidReceiveAcceptCurrentRelay(
        _ outcome: V011AcceptCurrentRelayRecoveryActionOutcome
    ) {
        switch outcome {
        case let .success(state, status):
            managedState = state
            hasPendingRecovery = false
            recoveryDisposition = .none
            self.status = status
            errorMessage = nil
        case let .failure(failure):
            status = failure.status
            errorMessage = failure.errorMessage
        }
    }

    func recoveryActionDidBecomeIdle() {
        isWorking = false
    }

    func recoveryActionRequestsRefresh() {
        refresh()
    }

    var allowsSwitchEntry: Bool {
        !isRefreshing && !isCheckingCurrentConnection
    }

    var allowsSwitchExecution: Bool {
        !isWorking && !isRefreshing && !isCheckingCurrentConnection
    }

    var switchControllerUsesRelayAccess: Bool {
        if case .relay? = liveState?.mode { return true }
        return false
    }

    func switchControllerPendingRecoveryBlockMessage(
        action: String
    ) -> String {
        pendingRecoveryBlockMessage(action: action)
    }

    func switchControllerDidReject(
        status: String?,
        errorMessage: String
    ) {
        if let status { self.status = status }
        self.errorMessage = errorMessage
    }

    func switchControllerDidProgress(_ message: String) {
        status = message
    }

    func switchControllerDidBegin() {
        isWorking = true
        errorMessage = nil
        status = "正在准备安全切换"
        configurationOutcome = "正在准备配置提交"
        sessionOutcome = "等待配置提交"
    }

    func switchControllerDidReceive(
        _ outcome: V011SwitchActionOutcome
    ) {
        switch outcome {
        case let .completed(result, managedState, presentation):
            liveState = result.state
            self.managedState = managedState
            configurationOutcome = presentation.configurationOutcome
            sessionOutcome = presentation.sessionOutcome
            status = presentation.status
            errorMessage = nil
        case let .failed(failure):
            status = failure.status
            configurationOutcome = failure.configurationOutcome
            sessionOutcome = failure.sessionOutcome
            errorMessage = failure.errorMessage
        }
    }

    func switchControllerDidBecomeIdle() {
        isWorking = false
    }
    func switchControllerRequestsRefresh(completion: (() -> Void)?) {
        guard allowsAccessRefreshStart else { return }
        refreshController.request(reason: .manual, debounceNanoseconds: 0, completion: completion)
    }

    private var connectionPresentation:
        V011AccessConnectionPresentation {
        V011AccessConnectionPresentation(
            managedState: managedState,
            liveState: liveState,
            connectionHealthHistory: connectionHealthHistory,
            hasPendingRecovery: hasPendingRecovery,
            isWorking: isWorking,
            isRefreshing: isRefreshing,
            isCheckingCurrentConnection:
                isCheckingCurrentConnection,
            isVerifyingAgentLoop: isVerifyingAgentLoop,
            isRefreshingOfficialUsage:
                isRefreshingOfficialUsage,
            verifyingSavedRelayReadinessID:
                verifyingSavedRelayReadinessID,
            isAgentLoopVerified: isAgentLoopVerified,
            agentLoopReceipt: agentLoopReceipt,
            agentLoopReceiptTargetsCurrentState:
                agentLoopReceipt.map(agentLoopReceiptTargetsCurrentState) ?? false,
            agentLoopTransientError: agentLoopFailureState.currentMessage(live: liveState),
            currentConnectionCheckError:
                currentConnectionCheckError,
            isCurrentConnectionVerified:
                isCurrentConnectionVerified,
            currentConnectionReceipt: currentConnectionReceipt,
            currentRuntimeFreshness: currentRuntimeFreshness,
            currentSessionProviderCheck:
                currentSessionProviderCheck,
            now: dependencies.now()
        )
    }

    private var recoveryPresentation:
        V011AccessRecoveryPresentation {
        let connection = connectionPresentation
        return V011AccessRecoveryPresentation(
            managedState: managedState,
            liveState: liveState,
            compatibilityEvidence: compatibilityEvidence,
            hasPendingRecovery: hasPendingRecovery,
            recoveryDisposition: recoveryDisposition,
            recoveryRepairPreview: recoveryRepairPreview,
            currentProviderID: connection.currentProviderID,
            currentRelayProfileID:
                connection.currentRelayProfileID,
            needsCurrentRelayAdoption:
                connection.needsCurrentRelayAdoption,
            isWorking: isWorking,
            isRefreshing: isRefreshing,
            isCheckingCurrentConnection:
                isCheckingCurrentConnection,
            isVerifyingAgentLoop: isVerifyingAgentLoop,
            isRefreshingOfficialUsage:
                isRefreshingOfficialUsage,
            verifyingSavedRelayReadinessID:
                verifyingSavedRelayReadinessID
        )
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent("state.json")
        )
    }

    private var supportEvidenceService:
        V011SupportEvidenceService {
        V011SupportEvidenceService(
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            now: dependencies.now
        )
    }

    private func loadPassivePresentationState() {
        managedState = (try? stateStore.load()) ?? .empty
    }

    private var connectionHealthService:
        V011ConnectionHealthService {
        V011ConnectionHealthService(
            controlRoot: dependencies.controlRoot,
            now: dependencies.now
        )
    }

    private func applyAgentLoopResult(
        _ result: V011AgentLoopProbeResult,
        matchesCurrent: Bool
    ) {
        agentLoopFailureState.clear()
        agentLoopReceipt = result.receipt
        isAgentLoopVerified =
            matchesCurrent
                && result.receipt.outcome == .passed
        agentLoopCompletedUsage = isAgentLoopVerified
            ? result.completedUsage : nil
        agentLoopErrorMessage = isAgentLoopVerified
            ? nil : result.safeMessage
    }

    private func agentLoopReceiptTargetsCurrentState(
        _ receipt: V011AgentLoopReceipt
    ) -> Bool {
        guard let liveState else { return false }
        return connectionVerificationController
            .agentLoopReceiptTargetsCurrentState(
            receipt,
            live: liveState
        )
    }

    private func reloadConnectionHealthHistory() {
        do {
            connectionHealthHistory =
                try connectionHealthService.loadHistory()
            connectionHealthHistoryError = nil
        } catch {
            connectionHealthHistory = []
            connectionHealthHistoryError =
                "连接检测历史无法读取；不会影响当前连接检测"
        }
    }

    private func applyCurrentConnectionHistoryUpdate(
        _ update: V011CurrentConnectionHistoryUpdate
    ) {
        if let history = update.history {
            connectionHealthHistory = history
        }
        connectionHealthHistoryError = update.errorMessage
    }

    private func applyCurrentConnectionCapabilityUpdate(
        _ update: V011CurrentConnectionCapabilityUpdate
    ) {
        capabilityEvidenceController.invalidateReceiptReload()
        if let receipts = update.receipts {
            providerProbeReceipts = receipts
        }
        capabilityEvidenceErrorMessage = update.errorMessage
    }

    var hasPendingCapabilityReceiptRead: Bool {
        capabilityEvidenceController.hasPendingReceiptRead
    }

    func capabilityEvidenceReceiptReloadDidReceive(
        _ result: V011CapabilityEvidenceReloadResult
    ) {
        switch result {
        case let .loaded(receipts):
            providerProbeReceipts = receipts
            capabilityEvidenceErrorMessage = nil
        case let .failed(message):
            providerProbeReceipts = []
            capabilityEvidenceErrorMessage = message
        }
    }

    nonisolated static func isReceiptFreshForUnsafeApply(
        _ receipt: V011ConnectionReceipt,
        at now: Date
    ) -> Bool {
        V011ConnectionHealthService.isReceiptFresh(
            receipt,
            at: now
        )
    }

    nonisolated static func interpretOptionalProviderCapabilityResponse(
        _ kind: ProviderCapabilityProbeKind,
        data: Data,
        capability: ProviderCapabilityProfile
    ) -> [V011ProviderCapabilityProbeObservation]? {
        V011OptionalProviderProbeService
            .interpretOptionalProviderCapabilityResponse(
                kind,
                data: data,
                capability: capability
            )
    }

}
