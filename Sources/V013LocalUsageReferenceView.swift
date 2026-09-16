import SwiftUI

struct V013LocalUsageReferenceView: View {
    let value: V013LocalUsageReference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("最近 7 天本机已读用量", systemImage: "sum")
                .font(.headline)
            Text("\(value.tokens.formatted()) Token · \(value.requestCount) 个完成请求")
                .font(.subheadline.monospacedDigit())
            if value.pricedRequestCount > 0 {
                Text("\(value.isFullyPriced ? "API 参考金额" : "可计价部分 API 参考金额")："
                    + value.pricedAPIEquivalentUSD.formatted(.currency(code: "USD")))
                    .font(.body.weight(.semibold).monospacedDigit())
            } else {
                Text("API 参考金额：缺少可用计价依据")
            }
            Text("\(value.pricedRequestCount)/\(value.requestCount) 个请求可计价；"
                + "\(value.assumedStandardCount) 个缺少档位，按标准价参考。")
                .font(.caption)
            Text(value.isFullyPriced
                ? "本机 API 参考，不是订阅账单或实际 credits 消耗。"
                : "本机 API 参考；其余金额未知，不是订阅账单或实际 credits 消耗。")
                .font(.caption)
            DisclosureGroup("计算说明与未计价原因") {
                Text("已记录档位按对应价格计算；缺失档位的标准价假设仅用于 API 参考，credits 不套用。")
                Text("\(value.from.formatted(date: .abbreviated, time: .shortened)) — "
                    + value.through.formatted(date: .abbreviated, time: .shortened)
                    + "；仅汇总本机已读官方会话，可能跨账号，不代表账号全部用量。")
                Text("API 价表核验：\(value.pricingCheckedAt.formatted(date: .abbreviated, time: .omitted))")
                if !value.isFullyPriced { Text("未计价请求没有按零计入总额。") }
                ForEach(value.issues, id: \.self) { issue in
                    Text(issue)
                }
            }
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
    }
}
