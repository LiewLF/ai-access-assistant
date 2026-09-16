import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerSwitchConfirmationCard: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let currentMode: String
    let targetMode: String
    let targetConfigurationWrites: [String]
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认切换").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            "只需确认一次，后面的保护和核对由助手完成。任一步失败会自动恢复原轨；恢复成功后立即可以继续使用和配置。只有恢复证据冲突或自动恢复无法安全完成时才暂停。"
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        modePill(title: "现在", value: currentMode)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        modePill(title: "切换到", value: targetMode)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("目标轨将自动写入")
                            .font(.headline)
                        ForEach(
                            targetConfigurationWrites,
                            id: \.self
                        ) { value in
                            Label(
                                value,
                                systemImage: "slider.horizontal.3"
                            )
                            .font(.callout)
                        }
                        Text(
                            "能力值会随轨道一起应用；已配置或已请求不等于上游已经验证支持。"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    .padding(14)
                    .background(
                        .blue.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("助手将自动完成")
                            .font(.headline)
                        switchProtectionRow(
                            "正常关闭并重开Codex"
                        )
                        switchProtectionRow(
                            "保留ChatGPT官方登录"
                        )
                        switchProtectionRow(
                            "保持全部历史会话可见"
                        )
                        switchProtectionRow(
                            "保留Skills、MCP、Plugins和项目设置"
                        )
                        switchProtectionRow(
                            "失败时自动恢复原轨；恢复成功后立即可以继续使用和配置"
                        )
                    }
                    .padding(14)
                    .background(
                        .green.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()

            HStack {
                Button("取消") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认并开始切换") {
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 760,
               minHeight: 440, idealHeight: 680, maxHeight: 820)
        .accessibilityIdentifier("switch.confirmation")
    }

    private func modePill(
        title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func switchProtectionRow(
        _ text: String
    ) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }
}
