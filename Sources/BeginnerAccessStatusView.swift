import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerAccessStatusView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    let localStatus: String?

    @ViewBuilder
    var body: some View {
        if let localStatus {
            Label(
                localStatus,
                systemImage: "info.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.blue)
            .padding(12)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                .blue.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        if let error = model.errorMessage {
            Label(
                BeginnerText.friendly(error),
                systemImage:
                    "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                .red.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        if let error = accessModel.errorMessage {
            Label(
                BeginnerText.friendly(error),
                systemImage:
                    "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                .red.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
        } else if !accessModel.status.isEmpty {
            Label(
                accessModel.status,
                systemImage: accessModel.isWorking
                    ? "hourglass" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
