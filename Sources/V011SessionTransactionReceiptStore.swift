// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011SessionReceiptScan: Equatable, Sendable {
    var receipts: [V011SessionTransactionReceipt] = []
    var conflictIDs: [String] = []
}

private enum V011ReceiptTransitionAuthority {
    case ordinary
    case supersede(V011SessionSupersedeIntent)
    case legacyAnchorHeal
}

struct V011SessionTransactionReceiptStore {
    let rootURL: URL
    let anchoredIOHook: @Sendable (V011AnchoredIOCheckpoint) throws -> Void
    private static let maximumRecordBytes =
        SessionCoreClient.maximumRecoveryJournalBytes

    init(
        rootURL: URL,
        anchoredIOHook: @escaping @Sendable
            (V011AnchoredIOCheckpoint) throws -> Void = { _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.anchoredIOHook = anchoredIOHook
    }

    func load(_ id: String) throws
        -> V011SessionTransactionReceipt {
        guard UUID(uuidString: id) != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withLock(operation: LOCK_EX) { root in
            try loadUnlocked(id, root: root)
        }
    }

    func all() throws -> [V011SessionTransactionReceipt] {
        try scan().receipts
    }

    func scan() throws -> V011SessionReceiptScan {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return V011SessionReceiptScan()
        }
        return try withLock(operation: LOCK_EX) { root in
            let leaves = try root.entries()
                .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            var result = V011SessionReceiptScan()
            for leaf in leaves {
                let leafID = String(leaf.dropLast(5))
                guard UUID(uuidString: leafID) != nil else {
                    result.conflictIDs.append(leafID)
                    continue
                }
                do {
                    result.receipts.append(
                        try loadUnlocked(leafID, root: root)
                    )
                } catch {
                    result.conflictIDs.append(leafID)
                }
            }
            result.receipts.sort { $0.createdAt < $1.createdAt }
            result.conflictIDs = Array(Set(result.conflictIDs)).sorted()
            return result
        }
    }

    @discardableResult
    func save(
        _ receipt: V011SessionTransactionReceipt,
        expectedHash: String?
    ) throws -> String {
        try save(
            receipt,
            expectedHash: expectedHash,
            authority: .ordinary
        )
    }

    @discardableResult
    func saveSuperseded(
        _ receipt: V011SessionTransactionReceipt,
        expectedHash: String,
        intent: V011SessionSupersedeIntent
    ) throws -> String {
        try save(
            receipt,
            expectedHash: expectedHash,
            authority: .supersede(intent)
        )
    }

    @discardableResult
    func saveLegacyAnchorHeal(
        _ receipt: V011SessionTransactionReceipt,
        expectedHash: String
    ) throws -> String {
        try save(
            receipt,
            expectedHash: expectedHash,
            authority: .legacyAnchorHeal
        )
    }

    @discardableResult
    private func save(
        _ receipt: V011SessionTransactionReceipt,
        expectedHash: String?,
        authority: V011ReceiptTransitionAuthority
    ) throws -> String {
        guard receipt.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withLock(operation: LOCK_EX) { root in
            let receiptRecordLeaf = receiptLeaf(receipt.id)
            var reservation = try loadReservationUnlocked(
                receipt.id,
                root: root
            )
            try requireReceiptBinding(receipt, reservation: reservation)
            guard reservation.state == .committed else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            var reservationFileHash = try reservationHashUnlocked(
                receipt.id,
                root: root
            )
            let currentData: Data?
            let currentReceipt: V011SessionTransactionReceipt?
            if let expectedHash {
                guard try root.hash(
                    receiptRecordLeaf,
                    maximumBytes: Self.maximumRecordBytes,
                    requiredPermissions: 0o600
                ) == expectedHash else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                currentData = try requiredData(
                    receiptRecordLeaf,
                    root: root
                )
                reservationFileHash = try reconcileReceiptAnchorUnlocked(
                    reservation: &reservation,
                    reservationFileHash: reservationFileHash,
                    receiptData: currentData!,
                    receiptHash: expectedHash,
                    root: root
                )
                guard reservation.latestReceiptHash == expectedHash,
                      reservation.pendingReceiptHash == nil else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                currentReceipt = try decodedReceipt(
                    currentData!,
                    expectedID: receipt.id
                )
            } else {
                guard try root.hash(
                    receiptRecordLeaf,
                    maximumBytes: Self.maximumRecordBytes
                ) == nil,
                      reservation.latestReceiptHash == nil,
                      reservation.pendingReceiptHash == nil,
                      isCanonicalInitialReceipt(receipt, reservation: reservation)
                else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                currentData = nil
                currentReceipt = nil
            }
            try validateTransition(
                from: currentReceipt,
                to: receipt,
                expectedHash: expectedHash,
                reservation: reservation,
                authority: authority
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(receipt)
            let data = try currentData.map {
                try preservingUnknownJSONFields(
                    encoded,
                    from: $0,
                    knownRootKeys: [
                        "schemaVersion", "id", "configTransactionID",
                        "configHash", "targetProvider", "targetProfileID",
                        "historyPolicy", "phase", "attempt", "createdAt",
                        "updatedAt", "failureCode", "failureStage",
                        "nextAction", "supersededBy", "expectedReceiptHash",
                        "estimatedJournalBytes", "actualJournalBytes",
                        "journalLimitBytes", "rolloutFileCount",
                        "rolloutCount", "patchCount", "estimateVersion",
                        "recoveryID",
                    ]
                )
            } ?? encoded
            guard data.count <= Self.maximumRecordBytes else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            let candidateHash = TOMLSemanticEngine.sha256(data)
            if let currentData, data == currentData {
                return candidateHash
            }
            if let currentData, let expectedHash {
                try preserveRawRecordPreimage(
                    currentData,
                    targetLeaf: receiptRecordLeaf,
                    root: root
                )
                reservation.pendingReceiptHash = candidateHash
                reservation.pendingReceiptPreviousHash = expectedHash
                reservation.updatedAt = Date()
                reservationFileHash = try saveReservationUnlocked(
                    reservation,
                    expectedHash: reservationFileHash,
                    root: root
                )
            }
            try root.writeAtomic(
                data,
                leaf: receiptRecordLeaf,
                expectedHash: expectedHash,
                permissions: 0o600
            )
            try preserveRawRecordPreimage(
                data,
                targetLeaf: receiptRecordLeaf,
                root: root
            )
            reservation.latestReceiptHash = candidateHash
            reservation.pendingReceiptHash = nil
            reservation.pendingReceiptPreviousHash = nil
            reservation.updatedAt = Date()
            _ = try saveReservationUnlocked(
                reservation,
                expectedHash: reservationFileHash,
                root: root
            )
            return candidateHash
        }
    }

    func hash(_ id: String) throws -> String {
        try withLock(operation: LOCK_SH) { root in
            guard let hash = try root.hash(
                receiptLeaf(id),
                maximumBytes: Self.maximumRecordBytes,
                requiredPermissions: 0o600
            ) else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return hash
        }
    }

    func hashIfPresent(_ id: String) throws -> String? {
        guard UUID(uuidString: id) != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withLock(operation: LOCK_SH) { root in
            try root.hash(
                receiptLeaf(id),
                maximumBytes: Self.maximumRecordBytes,
                requiredPermissions: 0o600
            )
        }
    }

    /// Persist a cooperative cancellation as a retryable SessionTxn outcome.
    /// The configuration transaction is intentionally not touched. Callers
    /// must supply the receipt hash observed immediately before the request;
    /// a changed hash is a fail-closed stale/third-value condition.
    @discardableResult
    func cancel(
        _ id: String,
        expectedHash: String,
        at date: Date = Date(),
        reason: String = "userRequested"
    ) throws -> V011SessionTransactionReceipt {
        var receipt = try load(id)
        guard receipt.isOpen else {
            throw V011SessionTransactionControlError.notResumable
        }
        guard try hash(id) == expectedHash else {
            throw V011SessionTransactionControlError.staleReceipt
        }
        receipt.phase = .retryableFailure
        receipt.failureCode = .sessionCancelled
        receipt.failureStage = "cancelled"
        receipt.nextAction = "resume"
        receipt.updatedAt = date
        receipt.expectedReceiptHash = expectedHash
        _ = try save(receipt, expectedHash: expectedHash)
        return try load(id)
    }

    /// Resume only a cancelled/retryable SessionTxn after re-reading all
    /// binding values. Provider/profile/config drift, stale CAS, or a third
    /// value stops without writing and leaves the durable receipt untouched.
    @discardableResult
    func resume(
        _ request: V011SessionResumeRequest,
        at date: Date = Date()
    ) throws -> V011SessionTransactionReceipt {
        var receipt = try load(request.receiptID)
        guard try hash(receipt.id) == request.expectedReceiptHash else {
            throw V011SessionTransactionControlError.staleReceipt
        }
        guard receipt.configHash == request.currentConfigHash else {
            throw V011SessionTransactionControlError.staleConfiguration
        }
        guard receipt.targetProvider == request.currentProvider else {
            throw V011SessionTransactionControlError.providerDrift
        }
        guard receipt.targetProfileID == request.currentProfileID else {
            throw V011SessionTransactionControlError.profileDrift
        }
        let storedProfileHash = Self.profileHash(
            provider: receipt.targetProvider,
            profileID: receipt.targetProfileID
        )
        guard storedProfileHash == request.currentProfileHash else {
            throw V011SessionTransactionControlError.profileDrift
        }
        guard receipt.phase == .retryableFailure,
              receipt.failureCode != nil,
              receipt.nextAction == "resume"
        else {
            throw V011SessionTransactionControlError.notResumable
        }
        receipt.phase = .prepared
        receipt.attempt += 1
        receipt.failureCode = nil
        receipt.failureStage = nil
        receipt.nextAction = nil
        receipt.updatedAt = date
        receipt.expectedReceiptHash = request.expectedReceiptHash
        _ = try save(receipt, expectedHash: request.expectedReceiptHash)
        return try load(receipt.id)
    }

    static func profileHash(
        provider: String,
        profileID: String?
    ) -> String? {
        guard let profileID else { return nil }
        return TOMLSemanticEngine.sha256(
            Data("ai-access-assistant.build63.profile\u{0}\(provider)\u{0}\(profileID)".utf8)
        )
    }

    func supersedeOpenReceipts(
        by configTransactionID: String,
        at date: Date
    ) throws {
        let receipts = try all()
        for var receipt in receipts
        where receipt.configTransactionID != configTransactionID
            && receipt.isOpen {
            let expectedHash = try hash(receipt.id)
            receipt.phase = .superseded
            receipt.updatedAt = date
            receipt.failureCode = nil
            receipt.expectedReceiptHash = expectedHash
            let intent = V011SessionSupersedeIntent(
                receiptID: receipt.id,
                expectedReceiptHash: expectedHash,
                supersededBy: configTransactionID
            )
            _ = try saveSuperseded(
                receipt,
                expectedHash: expectedHash,
                intent: intent
            )
        }
    }

    func openSupersedeIntents(
        supersededBy configTransactionID: String
    ) throws -> [V011SessionSupersedeIntent] {
        try all().filter {
            $0.configTransactionID != configTransactionID
                && $0.isOpen
        }.map {
            V011SessionSupersedeIntent(
                receiptID: $0.id,
                expectedReceiptHash: try hash($0.id),
                supersededBy: configTransactionID
            )
        }
    }

    @discardableResult
    func saveReservation(
        _ reservation: V011SessionTxnReservation,
        expectedHash: String?
    ) throws -> String {
        guard reservation.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withLock(operation: LOCK_EX) { root in
            try saveReservationUnlocked(
                reservation,
                expectedHash: expectedHash,
                root: root
            )
        }
    }

    func loadReservation(_ id: String) throws
        -> V011SessionTxnReservation {
        guard UUID(uuidString: id) != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withLock(operation: LOCK_SH) { root in
            try loadReservationUnlocked(id, root: root)
        }
    }

    func reservationHash(_ id: String) throws -> String {
        try withLock(operation: LOCK_SH) { root in
            try reservationHashUnlocked(id, root: root)
        }
    }

    func discardUnmaterializedReservation(
        _ id: String,
        configTransactionID: String
    ) throws {
        guard UUID(uuidString: id) != nil,
              UUID(uuidString: configTransactionID) != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try withLock(operation: LOCK_EX) { root in
            guard try root.hash(
                receiptLeaf(id),
                maximumBytes: Self.maximumRecordBytes
            ) == nil else {
                return
            }
            let reservationRecordLeaf = reservationLeaf(id)
            guard let data = try root.data(
                reservationRecordLeaf,
                maximumBytes: Self.maximumRecordBytes,
                requiredPermissions: 0o600
            ) else {
                return
            }
            let reservation = try loadReservationUnlocked(id, root: root)
            guard reservation.configTxnID == configTransactionID,
                  reservation.state == .reserved,
                  reservation.latestReceiptHash == nil,
                  reservation.pendingReceiptHash == nil else {
                throw V011SwitchError.concurrentConfigurationChange
            }
            let hash = TOMLSemanticEngine.sha256(data)
            try preserveRawRecordPreimage(
                data,
                targetLeaf: reservationRecordLeaf,
                root: root
            )
            try root.removeRegularFile(
                reservationRecordLeaf,
                expectedHash: hash,
                maximumBytes: Self.maximumRecordBytes
            )
        }
    }

    private func loadUnlocked(
        _ id: String,
        root: V011AnchoredDirectory
    ) throws
        -> V011SessionTransactionReceipt {
        let data = try requiredData(receiptLeaf(id), root: root)
        let receipt = try decodedReceipt(
            data,
            expectedID: id
        )
        var reservation = try loadReservationUnlocked(id, root: root)
        let receiptHash = TOMLSemanticEngine.sha256(data)
        let reservationHash = try reservationHashUnlocked(id, root: root)
        _ = try reconcileReceiptAnchorUnlocked(
            reservation: &reservation,
            reservationFileHash: reservationHash,
            receiptData: data,
            receiptHash: receiptHash,
            root: root
        )
        guard reservation.latestReceiptHash == receiptHash,
              reservation.pendingReceiptHash == nil else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        return receipt
    }

    private func loadReservationUnlocked(
        _ id: String,
        root: V011AnchoredDirectory
    ) throws -> V011SessionTxnReservation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reservation = try decoder.decode(
            V011SessionTxnReservation.self,
            from: requiredData(reservationLeaf(id), root: root)
        )
        guard reservation.id == id,
              reservation.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return reservation
    }

    private func reservationHashUnlocked(
        _ id: String,
        root: V011AnchoredDirectory
    ) throws -> String {
        guard let hash = try root.hash(
            reservationLeaf(id),
            maximumBytes: Self.maximumRecordBytes,
            requiredPermissions: 0o600
        ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return hash
    }

    @discardableResult
    private func saveReservationUnlocked(
        _ reservation: V011SessionTxnReservation,
        expectedHash: String?,
        root: V011AnchoredDirectory
    ) throws -> String {
        guard reservation.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let leaf = reservationLeaf(reservation.id)
        guard try root.hash(
            leaf,
            maximumBytes: Self.maximumRecordBytes,
            requiredPermissions: expectedHash == nil ? nil : 0o600
        ) == expectedHash else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        let currentData = try expectedHash.map { _ in
            try requiredData(leaf, root: root)
        }
        if let currentData {
            try preserveRawRecordPreimage(
                currentData,
                targetLeaf: leaf,
                root: root
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(reservation)
        guard data.count <= Self.maximumRecordBytes else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try root.writeAtomic(
            data,
            leaf: leaf,
            expectedHash: expectedHash,
            permissions: 0o600
        )
        try preserveRawRecordPreimage(
            data,
            targetLeaf: leaf,
            root: root
        )
        return TOMLSemanticEngine.sha256(data)
    }

    private func requireReceiptBinding(
        _ receipt: V011SessionTransactionReceipt,
        reservation: V011SessionTxnReservation
    ) throws {
        guard receipt.id == reservation.sessionTxnID,
              receipt.configTransactionID == reservation.configTxnID,
              receipt.configHash == reservation.targetConfigHash,
              receipt.targetProvider == reservation.targetProvider,
              receipt.targetProfileID == reservation.targetProfileID,
              receipt.historyPolicy == reservation.historyPolicy,
              receipt.createdAt == reservation.createdAt else {
            throw V011SwitchError.invalidRecoveryJournal
        }
    }

    private func isCanonicalInitialReceipt(
        _ receipt: V011SessionTransactionReceipt,
        reservation: V011SessionTxnReservation
    ) -> Bool {
        receipt.phase == .notStarted
            && receipt.attempt == 0
            && receipt.failureCode == nil
            && receipt.failureStage == nil
            && receipt.nextAction == nil
            && receipt.supersededBy == nil
            && receipt.expectedReceiptHash
                == reservation.expectedReservationHash
            && receipt.estimatedJournalBytes == nil
            && receipt.actualJournalBytes == nil
            && receipt.journalLimitBytes == nil
            && receipt.rolloutFileCount == nil
            && receipt.patchCount == nil
            && receipt.estimateVersion == nil
            && receipt.recoveryID == reservation.sessionTxnID.lowercased()
    }

    @discardableResult
    private func reconcileReceiptAnchorUnlocked(
        reservation: inout V011SessionTxnReservation,
        reservationFileHash: String,
        receiptData: Data,
        receiptHash: String,
        root: V011AnchoredDirectory
    ) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            V011SessionTransactionReceipt.self,
            from: receiptData
        )
        guard receipt.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try requireReceiptBinding(receipt, reservation: reservation)
        if reservation.latestReceiptHash == receiptHash,
           reservation.pendingReceiptHash == nil {
            return reservationFileHash
        }
        if reservation.pendingReceiptHash == receiptHash,
           reservation.pendingReceiptPreviousHash
            == reservation.latestReceiptHash {
            reservation.latestReceiptHash = receiptHash
            reservation.pendingReceiptHash = nil
            reservation.pendingReceiptPreviousHash = nil
            reservation.updatedAt = Date()
            return try saveReservationUnlocked(
                reservation,
                expectedHash: reservationFileHash,
                root: root
            )
        }
        if reservation.latestReceiptHash == receiptHash,
           reservation.pendingReceiptPreviousHash == receiptHash,
           reservation.pendingReceiptHash != nil {
            reservation.pendingReceiptHash = nil
            reservation.pendingReceiptPreviousHash = nil
            reservation.updatedAt = Date()
            return try saveReservationUnlocked(
                reservation,
                expectedHash: reservationFileHash,
                root: root
            )
        }
        if reservation.latestReceiptHash == nil,
           reservation.pendingReceiptHash == nil,
           isCanonicalInitialReceipt(receipt, reservation: reservation) {
            reservation.latestReceiptHash = receiptHash
            reservation.updatedAt = Date()
            try preserveRawRecordPreimage(
                receiptData,
                targetLeaf: receiptLeaf(receipt.id),
                root: root
            )
            return try saveReservationUnlocked(
                reservation,
                expectedHash: reservationFileHash,
                root: root
            )
        }
        throw V011SwitchError.concurrentConfigurationChange
    }

    private func receiptLeaf(_ id: String) -> String {
        "\(id).json"
    }

    private func reservationLeaf(_ id: String) -> String {
        "\(id).reservation"
    }

    private func requiredData(
        _ leaf: String,
        root: V011AnchoredDirectory
    ) throws -> Data {
        guard let data = try root.data(
            leaf,
            maximumBytes: Self.maximumRecordBytes,
            requiredPermissions: 0o600
        ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return data
    }

    private func decodedReceipt(
        _ data: Data,
        expectedID: String
    ) throws -> V011SessionTransactionReceipt {
        guard let object = try JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue
                == V011SessionTransactionReceipt.currentSchemaVersion else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            V011SessionTransactionReceipt.self,
            from: data
        )
        guard receipt.id == expectedID,
              receipt.isStructurallyValid else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return receipt
    }

    private func validateTransition(
        from current: V011SessionTransactionReceipt?,
        to candidate: V011SessionTransactionReceipt,
        expectedHash: String?,
        reservation: V011SessionTxnReservation,
        authority: V011ReceiptTransitionAuthority
    ) throws {
        guard isValidWritePhase(candidate.phase),
              phaseFieldsAreValid(candidate) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        guard let current else {
            guard expectedHash == nil,
                  isCanonicalInitialReceipt(
                      candidate,
                      reservation: reservation
                  ) else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return
        }
        guard isValidWritePhase(current.phase),
              phaseFieldsAreValid(current),
              candidate.updatedAt >= current.updatedAt,
              candidate.attempt >= current.attempt else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        if candidate == current { return }
        guard let expectedHash,
              candidate.expectedReceiptHash == expectedHash else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        if isTerminal(current.phase) {
            throw V011SwitchError.concurrentConfigurationChange
        }
        switch authority {
        case .ordinary:
            guard candidate.phase != .superseded,
                  ordinaryTransitionAllowed(
                      from: current.phase,
                      to: candidate.phase
                  ) else {
                throw V011SwitchError.invalidRecoveryJournal
            }
        case let .supersede(intent):
            guard intent.isStructurallyValid,
                  intent.receiptID == current.id,
                  intent.expectedReceiptHash == expectedHash,
                  intent.supersededBy == candidate.supersededBy,
                  candidate.phase == .superseded,
                  current.isOpen else {
                throw V011SwitchError.concurrentConfigurationChange
            }
        case .legacyAnchorHeal:
            guard current.phase == .notStarted,
                  candidate.phase == .notStarted,
                  current.expectedReceiptHash == nil,
                  candidate.expectedReceiptHash
                    == reservation.expectedReservationHash,
                  current.attempt == 0,
                  candidate.attempt == 0,
                  current.failureCode == nil,
                  current.failureStage == nil,
                  current.nextAction == nil,
                  current.supersededBy == nil else {
                throw V011SwitchError.invalidRecoveryJournal
            }
        }
    }

    private func isValidWritePhase(
        _ phase: V011SessionTransactionPhase
    ) -> Bool {
        ![.reserved, .succeeded, .cancelled].contains(phase)
    }

    private func isTerminal(
        _ phase: V011SessionTransactionPhase
    ) -> Bool {
        [.committed, .skipped, .superseded, .terminalFailure]
            .contains(phase)
    }

    private func ordinaryTransitionAllowed(
        from current: V011SessionTransactionPhase,
        to candidate: V011SessionTransactionPhase
    ) -> Bool {
        switch current {
        case .notStarted:
            return [.prepared, .running, .skipped, .retryableFailure,
                    .terminalFailure].contains(candidate)
        case .prepared, .running:
            return [.prepared, .running, .committed, .retryableFailure,
                    .terminalFailure].contains(candidate)
        case .retryableFailure:
            return [.prepared, .running, .retryableFailure, .skipped,
                    .terminalFailure].contains(candidate)
        case .reserved, .committed, .succeeded, .skipped, .superseded,
             .cancelled, .terminalFailure:
            return false
        }
    }

    private func phaseFieldsAreValid(
        _ receipt: V011SessionTransactionReceipt
    ) -> Bool {
        switch receipt.phase {
        case .notStarted:
            return receipt.attempt == 0
                && receipt.failureCode == nil
                && receipt.failureStage == nil
                && receipt.nextAction == nil
                && receipt.supersededBy == nil
        case .prepared:
            return receipt.failureCode == nil
                && receipt.failureStage == nil
                && receipt.nextAction == nil
                && receipt.supersededBy == nil
        case .running:
            return receipt.attempt > 0
                && receipt.failureCode == nil
                && receipt.failureStage == nil
                && receipt.nextAction == nil
                && receipt.supersededBy == nil
        case .retryableFailure:
            return receipt.failureCode != nil
                && receipt.failureStage != nil
                && receipt.nextAction != nil
                && receipt.supersededBy == nil
        case .committed:
            return receipt.failureCode == nil
                && receipt.failureStage == nil
                && receipt.nextAction == nil
                && receipt.supersededBy == nil
        case .skipped:
            return receipt.supersededBy == nil
        case .superseded:
            return receipt.supersededBy != nil
                && receipt.failureCode == nil
                && receipt.failureStage == nil
                && receipt.nextAction == nil
        case .terminalFailure:
            return receipt.failureCode != nil
                && receipt.failureStage != nil
                && receipt.supersededBy == nil
        case .reserved, .succeeded, .cancelled:
            return false
        }
    }

    private func withLock<T>(
        operation: Int32,
        _ body: (V011AnchoredDirectory) throws -> T
    ) throws -> T {
        try V011AnchoredDirectory.withCanonicalRoot(
            rootURL,
            create: true
        ) { root in
            let descriptor = Darwin.openat(
                root.descriptor,
                ".session-receipts.lock",
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            defer { _ = Darwin.close(descriptor) }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  flock(descriptor, operation | LOCK_NB) == 0 else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            try anchoredIOHook(.receiptLockAcquired)
            guard root.verifyIdentity() else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            let result = try body(root)
            guard Darwin.fsync(root.descriptor) == 0,
                  root.verifyIdentity() else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return result
        }
    }
}
