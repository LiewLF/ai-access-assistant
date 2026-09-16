import SwiftUI

struct V013CPACollectionControlsView: View {
    @ObservedObject private var collection = V013CPACollectionModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("旧采集连接恢复",
                    systemImage: "waveform.path")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if collection.isBusy { ProgressView().controlSize(.small) }
                else if collection.needsShutdown {
                    Button("停止采集并恢复官方连接") { Task { await collection.stop() } }
                }
            }
            Text(collection.status).font(.caption).foregroundStyle(.secondary)
            if let error = collection.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("周/月容量外推已退役。此入口仅用于停止已有采集并恢复官方连接。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
