// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AppMainNavigationView: View {
    @ObservedObject var shellState: AppShellState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(MainMode.allCases) { item in
                        Button {
                            shellState.selectMainMode(item)
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.body.weight(shellState.mode == item ? .semibold : .regular))
                                .foregroundStyle(shellState.mode == item ? Color.accentColor : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    shellState.mode == item ? Color.accentColor.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("main-navigation.\(item.systemImage)")
                        .accessibilityAddTraits(shellState.mode == item ? .isSelected : [])
                        .disabled(shellState.navigationLocked && shellState.mode != item)
                    }
                }
            }
            if shellState.navigationLocked {
                Text("迁移操作进行中，完成后可切换页面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            Label("切换失败会恢复原状态", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(12)
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

struct AppMissingCodexPage: View {
    let openInstallation: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("先安装 Codex", systemImage: "square.and.arrow.down")
        } description: {
            Text("安装后即可使用接入与历史功能。已有资料会保留。")
        } actions: {
            Button("查看安装步骤", action: openInstallation)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
