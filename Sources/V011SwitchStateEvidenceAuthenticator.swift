// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

enum V011SwitchStateEvidenceAuthenticator {
    private static let currentVersion = 1
    private static let domain =
        "ai-access-assistant.v011.switch-state-evidence"

    private struct Evidence: Encodable {
        let domain: String
        let version: Int
        let transactionID: String
        let codexHomePath: String
        let sourceConfigHash: String
        let sourceConfigExisted: Bool
        let targetConfigHash: String
        let targetProvider: String
        let targetProfileID: String?
        let stateCASManaged: Bool
        let stateExisted: Bool
        let sourceManagedStateHash: String?
        let targetManagedStateHash: String?
        let forwardManagedStateHash: String?
        let originLedgerExisted: Bool
        let targetOriginLedgerHash: String?
        let configTransactionID: String?
        let configTransactionPhase: V011ConfigTransactionPhase?
        let historyPolicy: V011HistoryPolicy?
        let reservationID: String?
        let reservationHash: String?
        let supersedeIntents: [V011SessionSupersedeIntent]?
    }

    static func seal(
        _ journal: inout V011SwitchJournal,
        key: Data
    ) throws {
        guard key.count == 32,
              journal.stateCASManaged == true,
              evidenceFieldsAreStructurallyValid(journal) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        journal.stateEvidenceVersion = currentVersion
        let code = HMAC<SHA256>.authenticationCode(
            for: try encodedEvidence(journal),
            using: SymmetricKey(data: key)
        )
        journal.stateEvidenceMAC = Data(code).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func allowsAutomaticRecovery(
        _ journal: V011SwitchJournal,
        key: Data
    ) throws -> Bool {
        guard evidenceFieldsAreStructurallyValid(journal)
        else {
            return false
        }
        if journal.stateEvidenceVersion == nil,
           journal.stateEvidenceMAC == nil {
            return journal.targetManagedStateHash == nil
                && journal.forwardManagedStateHash == nil
                && journal.targetOriginLedgerHash == nil
        }
        guard key.count == 32,
              journal.stateEvidenceVersion == currentVersion,
              journal.stateCASManaged == true,
              let encodedMAC = journal.stateEvidenceMAC,
              let mac = data(fromLowercaseHex: encodedMAC) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: try encodedEvidence(journal),
            using: SymmetricKey(data: key)
        )
    }

    private static func evidenceFieldsAreStructurallyValid(
        _ journal: V011SwitchJournal
    ) -> Bool {
        let requiredHashes = [
            journal.sourceConfigHash,
            journal.targetConfigHash,
        ]
        let optionalHashes = [
            journal.sourceManagedStateHash,
            journal.targetManagedStateHash,
            journal.forwardManagedStateHash,
            journal.targetOriginLedgerHash,
            journal.reservationHash,
        ]
        let reservationIDIsValid: Bool
        if let reservationID = journal.reservationID {
            reservationIDIsValid = UUID(uuidString: reservationID) != nil
        } else {
            reservationIDIsValid = true
        }
        let supersedeIntentsAreValid =
            (journal.supersedeIntents ?? []).allSatisfy {
                $0.isStructurallyValid
                    && $0.supersededBy
                        == journal.configTransactionID
            }
        guard requiredHashes.allSatisfy(isLowercaseSHA256),
              optionalHashes.compactMap({ $0 })
                .allSatisfy(isLowercaseSHA256),
              (journal.stateEvidenceVersion == nil)
                == (journal.stateEvidenceMAC == nil),
              (
                  journal.stateCASManaged != true
                    || journal.stateExisted
                        == (journal.sourceManagedStateHash != nil)
              ),
              (
                  journal.configTransactionID == nil
                    && journal.configTransactionPhase == nil
                    && journal.historyPolicy == nil
                  || journal.configTransactionID.map {
                      UUID(uuidString: $0) != nil
                  } == true
                    && journal.configTransactionPhase != nil
                    && journal.historyPolicy != nil
              ),
              (journal.reservationID == nil)
                == (journal.reservationHash == nil),
              reservationIDIsValid,
              supersedeIntentsAreValid else {
            return false
        }
        if let mac = journal.stateEvidenceMAC,
           !isLowercaseSHA256(mac) {
            return false
        }
        if journal.stateCASManaged != true {
            return journal.sourceManagedStateHash == nil
                && journal.targetManagedStateHash == nil
                && journal.forwardManagedStateHash == nil
                && journal.stateEvidenceVersion == nil
                && journal.stateEvidenceMAC == nil
        }
        return true
    }

    private static func isLowercaseSHA256(
        _ value: String
    ) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }

    private static func encodedEvidence(
        _ journal: V011SwitchJournal
    ) throws -> Data {
        let evidence = Evidence(
            domain: domain,
            version: currentVersion,
            transactionID: journal.id,
            codexHomePath: journal.codexHomePath,
            sourceConfigHash: journal.sourceConfigHash,
            sourceConfigExisted: journal.sourceConfigExisted,
            targetConfigHash: journal.targetConfigHash,
            targetProvider: journal.targetProvider,
            targetProfileID: journal.targetProfileID,
            stateCASManaged: journal.stateCASManaged == true,
            stateExisted: journal.stateExisted,
            sourceManagedStateHash:
                journal.sourceManagedStateHash,
            targetManagedStateHash:
                journal.targetManagedStateHash,
            forwardManagedStateHash:
                journal.forwardManagedStateHash,
            originLedgerExisted: journal.originLedgerExisted,
            targetOriginLedgerHash:
                journal.targetOriginLedgerHash,
            configTransactionID: journal.configTransactionID,
            configTransactionPhase:
                journal.configTransactionPhase,
            historyPolicy: journal.historyPolicy,
            reservationID: journal.reservationID,
            reservationHash: journal.reservationHash,
            supersedeIntents: journal.supersedeIntents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(evidence)
    }

    private static func data(
        fromLowercaseHex value: String
    ) -> Data? {
        guard value.count == 64,
              value.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16)
            else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
