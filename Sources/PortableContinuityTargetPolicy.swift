import Foundation

/// Shared by migration target selection and the final write preflight.
enum PortableContinuityTargetPolicy {
    static func updateBlockReason(
        _ profile: CodexRelayProfile,
        state: V011ManagedState,
        protectedProviderID: String?
    ) -> PortableContinuityApplyError? {
        guard profile.v011ProviderID != protectedProviderID,
              state.activeProfileID != profile.id else {
            return .activeProfile
        }
        guard state.activeCutoverConfiguration?.profileID != profile.id,
              state.activeCutoverConfiguration?.providerID != profile.v011ProviderID,
              state.lastKnownGoodCutoverConfiguration?.profileID != profile.id,
              state.lastKnownGoodCutoverConfiguration?.providerID != profile.v011ProviderID else {
            return .referencedProfile
        }
        return nil
    }

    static func selectionIssue(
        targetID: String,
        state: V011ManagedState,
        protectedProviderID: String?
    ) -> String? {
        if targetID.isEmpty { return nil }
        guard let profile = state.relayProfiles.first(where: { $0.id == targetID }) else {
            return "请选择当前设备上的具体目标；档案已变化时请重新预检。"
        }
        return updateBlockReason(profile, state: state,
            protectedProviderID: protectedProviderID)?.localizedDescription
    }
}
