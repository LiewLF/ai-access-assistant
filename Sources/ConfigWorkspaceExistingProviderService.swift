// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceReadOnlyProviderAdoption {
    let imported: ExistingProviderImportResult
    let plan: CodexConfigurationPlan?
}

struct ConfigWorkspaceExistingProviderMigration {
    let report: ExistingProviderImportReport
    let plan: CodexConfigurationPlan
    let usesLegacyBearer: Bool
}

struct ConfigWorkspaceExternalChangeInspection {
    let configChanged: Bool
    let authChanged: Bool

    var detected: Bool {
        configChanged || authChanged
    }
}

enum ConfigWorkspaceExternalRelayPreparation {
    case ready(
        imported: ExistingProviderImportResult,
        plan: CodexConfigurationPlan
    )
    case missingCredential
    case requiresLegacyBearerAuthorization
}

/// Owns existing-provider inspection, read-only adoption, and migration-plan
/// preparation. ConfigWorkspaceModel keeps user gates and Published projection.
struct ConfigWorkspaceExistingProviderService {
    let adapter: CodexConfigurationAdapter
    let engine: CodexSwitchEngine

    func inspect(
        displayName: String?
    ) throws -> ExistingProviderImportResult {
        try adapter.inspectExistingProvider(
            displayName: displayName
        )
    }

    func inspectChange(
        from baseline: OfficialBaseline
    ) throws -> ConfigWorkspaceExternalChangeInspection {
        ConfigWorkspaceExternalChangeInspection(
            configChanged:
                try adapter.currentConfigHash()
                    != baseline.configHash,
            authChanged:
                try adapter.currentAuthHash()
                    != baseline.authHash
        )
    }

    func prepareExternalRelay(
        displayName: String?,
        enteredAPIKey: String,
        allowsLegacyBearerRemoval: Bool
    ) throws -> ConfigWorkspaceExternalRelayPreparation {
        let imported = try inspect(
            displayName: displayName
        )
        if enteredAPIKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
           !imported.report.legacyBearerFieldPresent,
           (try? RelaySecretStore.load(
               relayID: imported.profile.id
           )) == nil {
            return .missingCredential
        }
        if imported.report.legacyBearerFieldPresent,
           !allowsLegacyBearerRemoval {
            return .requiresLegacyBearerAuthorization
        }
        return .ready(
            imported: imported,
            plan: try prepareMigration(for: imported)
        )
    }

    func adoptReadOnly(
        displayName: String?
    ) throws -> ConfigWorkspaceReadOnlyProviderAdoption {
        let imported = try inspect(
            displayName: displayName
        )
        guard imported.report.targetConfigurationUnchanged else {
            throw CodexControlError.externalDrift
        }
        try engine.recordReadOnlyImportedRelay(imported)
        return ConfigWorkspaceReadOnlyProviderAdoption(
            imported: imported,
            plan: try? prepareMigration(for: imported)
        )
    }

    func migration(
        for state: CodexStateStore.State
    ) throws -> ConfigWorkspaceExistingProviderMigration? {
        guard state.currentMode == .relay,
              let activeID = state.activeRelayID,
              let profile = state.relayProfiles.first(
                where: { $0.id == activeID }
              )
        else { return nil }
        let imported = try inspect(
            displayName: profile.name
        )
        let providerID = profile.providerID
            ?? PreservingTOMLEditor.providerIdentifier(
                profile.id
            )
        guard imported.profile.providerID == providerID else {
            return nil
        }
        let report = imported.report
        guard report.legacyBearerFieldPresent
                || report.environmentKeyFieldPresent else {
            return nil
        }
        return ConfigWorkspaceExistingProviderMigration(
            report: report,
            plan: try prepareMigration(for: imported),
            usesLegacyBearer:
                report.legacyBearerFieldPresent
        )
    }

    func prepareMigration(
        for imported: ExistingProviderImportResult
    ) throws -> CodexConfigurationPlan {
        try engine.prepareImportedRelay(
            imported,
            allowLegacyBearerRemoval:
                imported.report.legacyBearerFieldPresent
        )
    }
}
