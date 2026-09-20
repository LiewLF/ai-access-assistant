import SwiftUI

struct BeginnerRuntimeReverificationCard: View {
    @ObservedObject var accessModel: V011AccessModel
    let decision: V016AccessReadinessDecision
    @State private var confirmsBasicConnection = false
    @State private var confirmsRealTask = false

    var body: some View {
        BeginnerUnifiedReadinessCard(
            decision: decision,
            accessibilityIdentifier: "build209.installation.reverification",
            actionEnabled: actionEnabled,
            perform: { action in
                switch action {
                case .checkBasicConnection: confirmsBasicConnection = true
                case .verifyRealTask: confirmsRealTask = true
                default: break
                }
            }
        )
        .confirmationDialog("确认检查当前版本的基础连接？",
                            isPresented: $confirmsBasicConnection) {
            Button("确认联网并检查基础连接") {
                accessModel.detectCurrentConnection(userConsented: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(BeginnerCurrentConnectionCheckCopy.consent)
        }
        .confirmationDialog("确认验证当前版本的真实任务？",
                            isPresented: $confirmsRealTask) {
            Button("确认联网并验证真实任务") {
                accessModel.verifyRealAgentLoop(userConsented: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将按当前官方设置运行一次隔离真实任务，可能消耗账户额度。不会采用新接入或修改日常配置。")
        }
    }

    private var actionEnabled: Bool {
        switch decision.primaryAction {
        case .checkBasicConnection: return accessModel.canCheckCurrentConnection
        case .verifyRealTask: return accessModel.canVerifyRealAgentLoop
        default: return false
        }
    }
}
