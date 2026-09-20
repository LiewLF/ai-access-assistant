import SwiftUI

enum BeginnerCurrentConnectionCheckCopy {
    static let consent = "将按当前设置检查基础响应。官方或本机网关会调用 Codex，过程中可能重试；其他中转由助手直接检查。可能消耗账户额度或产生中转费用，请求次数和费用以实际记录为准。不会切换接入、读取真实项目或历史会话，也不会修改日常配置。运行中可取消，已发送请求的用量无法撤回。"
}

/// Shared by the main window and the capability sheet so navigation never
/// removes the user's way to stop an in-flight basic connection check.
struct BeginnerCurrentConnectionCheckBanner: View {
    @ObservedObject var accessModel: V011AccessModel
    @State private var cancellationRequested = false

    var body: some View {
        Group {
            if accessModel.isCheckingCurrentConnection {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cancellationRequested ? "正在停止基础检测…" : "正在检查基础连接")
                            .font(.callout.weight(.medium))
                        Text("已发送请求的用量以账户记录为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(cancellationRequested ? "正在取消…" : "取消检测") {
                        cancellationRequested = true
                        accessModel.cancelCurrentConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(cancellationRequested)
                    .accessibilityIdentifier("connection-check.cancel")
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: accessModel.isCheckingCurrentConnection) { _, _ in
            cancellationRequested = false
        }
    }
}
