// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

struct V011HistoryRecoveryPlanContext: Sendable {
    let snapshot: V011HistoryRecoverySnapshot
    let pointerKind: V011HistoryRecoveryPointer.Kind?
    let provider: String
    let codexHome: URL
    let controlRoot: URL
    let isWorking: Bool
}

/// Builds and validates Build68 zero-write plans from one immutable recovery
/// context. Transaction writers remain in their existing services.
enum V011HistoryRecoveryPlanService {
    static func make(
        operation: B68RecoveryOperation,
        context: V011HistoryRecoveryPlanContext
    ) throws -> B68RecoveryPlanBundle {
        let snapshot = context.snapshot
        let estimatedWrites: Int
        let phases: [String]
        let writeSet: [String]
        switch operation {
        case .restore:
            estimatedWrites = max(1, snapshot.pendingCount)
            if context.pointerKind == .externalImport {
                phases = ["重新核对", "撤回本次导入", "验证结果"]
                writeSet = ["本次导入的历史会话", "恢复记录"]
            } else {
                phases = ["重新核对", "恢复可见标记", "验证结果"]
                writeSet = ["历史会话可见标记", "恢复记录"]
            }
        case .cleanup:
            estimatedWrites = 1
            phases = ["重新核对", "归档旧完成记录", "验证结果"]
            writeSet = ["旧恢复记录"]
        case .retry:
            estimatedWrites = max(1, snapshot.pendingCount)
            phases = ["建立恢复点", "整理可见标记", "验证结果"]
            writeSet = ["历史会话可见标记", "恢复记录"]
        }

        let estimatedBytes = Int64(estimatedWrites) * 4096
        let capacity = try context.codexHome.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? 0
        let permissionRoot = existingParent(
            of: context.controlRoot
        )
        let permissionGranted = FileManager.default.isReadableFile(
            atPath: context.codexHome.path
        ) && FileManager.default.isWritableFile(
            atPath: permissionRoot.path
        )
        let operationID = [
            operation.rawValue,
            String(snapshot.generation),
            snapshot.operationKey ?? "none",
        ].joined(separator: "-")
        let now = Date()
        let input = B68RecoveryPlanInput(
            operationID: operationID,
            operation: operation,
            generation: snapshot.generation,
            build: currentBuild,
            environmentFingerprint:
                environmentFingerprint(context),
            pointer: pointerIdentity(snapshot),
            journal: journalIdentity(snapshot),
            receipt: receiptIdentity(snapshot),
            estimatedReadObjects: 3,
            estimatedBytes: estimatedBytes,
            availableBytes: max(0, capacity),
            phases: phases,
            recoveryPoint: operation == .cleanup
                ? snapshot.pointerHash
                : "will-create-operation-journal",
            managedWriteSet: writeSet,
            unmanagedWriteSet: [],
            irreversibleItems: [],
            irreversibleItemsConfirmed: true,
            permissionGranted: permissionGranted,
            sessionCoreAvailable: snapshot.failureCode
                != Build65HistoryRecoveryFailureCode
                    .sessionCoreUnavailable.rawValue,
            lockAvailable: !context.isWorking,
            schemaVersion: 1,
            supportedSchemaVersion: 1,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        return try B68RecoveryPlanFactory.make(input)
    }

    static func validate(
        _ plan: RecoveryOperationPlan,
        context: V011HistoryRecoveryPlanContext
    ) -> B68RecoveryExecutionDecision {
        let snapshot = context.snapshot
        return B68RecoveryPlanExecutionGuard.validate(
            plan: plan,
            observation: B68RecoveryExecutionObservation(
                planHash: plan.planHash,
                generation: snapshot.generation,
                build: currentBuild,
                environmentFingerprint:
                    environmentFingerprint(context),
                pointer: pointerIdentity(snapshot),
                journal: journalIdentity(snapshot),
                receipt: receiptIdentity(snapshot),
                lockAvailable: !context.isWorking,
                thirdValueDetected: false,
                observedAt: Date()
            )
        )
    }

    private static var currentBuild: Int {
        Int(AppReleaseMetadata.build) ?? 0
    }

    private static func environmentFingerprint(
        _ context: V011HistoryRecoveryPlanContext
    ) -> String {
        let data = Data(
            "\(AppReleaseMetadata.build)|\(context.provider)|\(context.snapshot.generation)"
                .utf8
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func pointerIdentity(
        _ snapshot: V011HistoryRecoverySnapshot
    ) -> B68RecoveryArtifactIdentity {
        artifactIdentity(
            state: snapshot.pointerState == .absent
                ? .absent
                : snapshot.pointerState == .invalid
                    ? .unknown : .present,
            hash: snapshot.pointerHash
        )
    }

    private static func journalIdentity(
        _ snapshot: V011HistoryRecoverySnapshot
    ) -> B68RecoveryArtifactIdentity {
        artifactIdentity(
            state: snapshot.journalState == .absent
                || snapshot.journalState == .staleEmpty
                ? .absent
                : snapshot.journalState == .corrupt
                    ? .unknown : .present,
            hash: snapshot.journalHash
        )
    }

    private static func receiptIdentity(
        _ snapshot: V011HistoryRecoverySnapshot
    ) -> B68RecoveryArtifactIdentity {
        artifactIdentity(
            state: snapshot.lastSuccessfulOperationID == nil
                ? .absent : .present,
            hash: snapshot.lastSuccessfulOperationID
        )
    }

    private static func artifactIdentity(
        state: B68RecoveryIdentityState,
        hash: String?
    ) -> B68RecoveryArtifactIdentity {
        B68RecoveryArtifactIdentity(
            state: state,
            sha256: state == .present ? hash : nil,
            version: 1
        )
    }

    private static func existingParent(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(
            atPath: candidate.path
        ), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}
