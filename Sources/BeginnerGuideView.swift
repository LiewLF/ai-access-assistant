import AppKit
import SwiftUI

struct BeginnerGuideView: View {
    let openSettingsSection: (BeginnerSettingsSection) -> Void
    let openAccessSection: (BeginnerAccessSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("使用说明")
                        .font(.system(size: 28, weight: .bold))
                    Text("这里只列出软件里真有窗口、真有按钮的地方。没做出来的功能，不会在这里假装存在。")
                        .foregroundStyle(.secondary)
                }

                guideCard(
                    title: "添加中转",
                    detail: "入口：接入与切换 > 配置向导。粘贴网址、文字或截图后整理成可保存的中转资料。",
                    icon: "plus.circle.fill"
                ) {
                    Button("打开配置向导") {
                        openAccessSection(.addRelay)
                    }
                    .buttonStyle(.borderedProminent)
                }

                guideCard(
                    title: "编辑当前候选",
                    detail: "入口：接入与切换 > 模式切换。这里能改已保存中转、设置并自动应用、导入受管模型目录。",
                    icon: "slider.horizontal.3"
                ) {
                    Button("打开切换模式") {
                        openAccessSection(.switchMode)
                    }
                    .buttonStyle(.borderedProminent)
                }

                guideCard(
                    title: "处理红黄警告",
                    detail: "受管模型目录和来源引用，去 软件与能力 > 扩展能力；切换与恢复状态，去 高级诊断 > 事务详情。",
                    icon: "exclamationmark.triangle.fill"
                ) {
                    HStack {
                        Button("打开扩展能力") {
                            openSettingsSection(.capabilities)
                        }
                        Button("打开高级诊断") {
                            openSettingsSection(.diagnostics)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                guideCard(
                    title: "你能直接处理什么",
                    detail: "有功能，就要有窗口；没窗口，就不要在软件里单独提示。",
                    icon: "checkmark.shield.fill"
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• 受管模型目录：软件与能力 > 扩展能力 > 导入受管模型目录")
                        Text("• 来源引用：软件与能力 > 扩展能力 > 验证 Web Search 与来源引用")
                        Text("• 当前配置目标 / 最小请求验证地址：高级诊断 > 事务详情 > 检测连接")
                        Text("• 上次切换没有完成：高级诊断 > 事务详情 > 重新读取当前状态")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func guideCard<Content: View>(
        title: String,
        detail: String,
        icon: String,
        @ViewBuilder actions: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            actions()
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }
}
