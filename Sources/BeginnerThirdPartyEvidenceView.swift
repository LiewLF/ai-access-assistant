// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

struct BeginnerThirdPartyEvidenceView: View {
    let records: [PlatformAdapterEvidence]
    let now: Date

    init(
        records: [PlatformAdapterEvidence] =
            PlatformEvidenceCatalog.thirdPartyRecords,
        now: Date = Date()
    ) {
        self.records = records
        self.now = now
    }

    var body: some View {
        DisclosureGroup("第三方工具适配证据") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(records) { record in
                    evidenceRow(record)
                    if record.id != records.last?.id {
                        Divider()
                    }
                }
                Text(
                    "这里只显示内置的版本绑定记录；不会后台联网刷新，也不会自动写 Codex 或第三方工具配置。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .padding(13)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .accessibilityIdentifier("m32.third-party-evidence")
    }

    private func evidenceRow(
        _ record: PlatformAdapterEvidence
    ) -> some View {
        let freshness = record.freshness(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.toolName)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(record.statusText(at: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: freshness))
            }
            Text(
                "\(record.upstreamVersion) · 记录 v\(record.recordVersion)"
            )
            .font(.caption.monospaced())
            .textSelection(.enabled)
            Text(
                "核验：\(record.verifiedAt ?? "未记录") · 有效至：\(record.expiresAt ?? "未确定")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(record.automationDecision)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.toolName)，\(record.statusText(at: now))"
        )
    }

    private func color(
        for freshness: PlatformEvidenceFreshness
    ) -> Color {
        switch freshness {
        case .current: return .green
        case .expired: return .orange
        case .unverified: return .red
        }
    }
}
