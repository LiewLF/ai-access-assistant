// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct BeginnerUnifiedReadinessCard: View {
    let decision: V016AccessReadinessDecision
    let accessibilityIdentifier: String
    let actionEnabled: Bool
    let perform: (V016AccessReadinessPrimaryAction) -> Void

    init(
        decision: V016AccessReadinessDecision,
        accessibilityIdentifier: String,
        actionEnabled: Bool = true,
        perform: @escaping (
            V016AccessReadinessPrimaryAction
        ) -> Void
    ) {
        self.decision = decision
        self.accessibilityIdentifier = accessibilityIdentifier
        self.actionEnabled = actionEnabled
        self.perform = perform
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 29))
                .foregroundStyle(color)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(routeTitle)
                        .font(.caption.weight(.semibold))
                    Text(decision.evidenceSource.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(decision.conclusion)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(decision.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(decision.evidenceLayers, id: \.kind) {
                        layer in
                        HStack(alignment: .firstTextBaseline) {
                            Text(layer.kind.rawValue)
                                .frame(width: 120, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(layer.status)
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        Text(layer.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                }
                .padding(.top, 3)
                if !decision.evidence.isEmpty {
                    DisclosureGroup("查看安全依据") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(
                                Array(decision.evidence.enumerated()),
                                id: \.offset
                            ) { _, item in
                                Text(item)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if decision.state == .checking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(decision.conclusion)
            } else if let primaryAction = decision.primaryAction {
                Button(primaryAction.title) {
                    perform(primaryAction)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actionEnabled)
                .accessibilityLabel(primaryAction.title)
                .accessibilityHint(decision.explanation)
                .accessibilityIdentifier(
                    "\(accessibilityIdentifier).primary"
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(decision.conclusion)
        .accessibilityHint(decision.explanation)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var routeTitle: String {
        switch decision.route {
        case .official: return "Codex 官方"
        case .relay: return "当前中转"
        case .unknown: return "当前接入"
        }
    }

    private var color: Color {
        switch decision.state {
        case .ready: return .green
        case .checking: return .blue
        case .needsAction: return .orange
        case .blocked: return .red
        }
    }

    private var icon: String {
        switch decision.state {
        case .ready: return "checkmark.seal.fill"
        case .checking: return "hourglass.circle.fill"
        case .needsAction:
            return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }
}
