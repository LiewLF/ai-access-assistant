import SwiftUI

private struct AppDisplayTextSizeKey: EnvironmentKey {
    static let defaultValue = AppDisplayTextSize.standard
}

extension EnvironmentValues {
    var appDisplayTextSize: AppDisplayTextSize {
        get { self[AppDisplayTextSizeKey.self] }
        set { self[AppDisplayTextSizeKey.self] = newValue }
    }
}

/// Keep app-controlled sizing independent of macOS semantic font scaling.
/// Allocate logical space before scaling so text, controls and hit targets agree.
private struct AppDisplayScaleLayout: Layout {
    let scale: CGFloat

    private func logical(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value) / scale
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(
            width: logical(proposal.width), height: logical(proposal.height)))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
    }
}

private struct AppDisplayScaleModifier: ViewModifier {
    let size: AppDisplayTextSize

    func body(content: Content) -> some View {
        AppDisplayScaleLayout(scale: size.scaleFactor) {
            content
                .dynamicTypeSize(.large)
                .scaleEffect(size.scaleFactor, anchor: .topLeading)
        }
        .environment(\.appDisplayTextSize, size)
    }
}

extension View {
    func appDisplayScale(_ size: AppDisplayTextSize) -> some View {
        modifier(AppDisplayScaleModifier(size: size))
    }
}

struct AppDisplayTextSizeMenu: View {
    @Binding var selection: AppDisplayTextSize

    var body: some View {
        Menu {
            Picker("文字与界面大小", selection: $selection) {
                ForEach(AppDisplayTextSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            Divider()
            Text("仅调整本应用的文字与控件。")
            Text("不改系统设置；系统菜单保留系统字号。")
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help("调整本应用的文字与控件大小，不修改 macOS 系统设置。")
        .accessibilityLabel("显示字号")
        .accessibilityIdentifier("build174.display-text-size")
    }
}
