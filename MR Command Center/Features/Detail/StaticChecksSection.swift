import SwiftUI

/// Prominent static check results at the top of Overview. Findings link to the diff line.
struct StaticChecksSection: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @State private var showsPassing = false

    var body: some View {
        let report = appModel.staticChecks.report(for: mr)
        let sorted = report.results.sorted { ($0.outcome, order($1.id)) > ($1.outcome, order($0.id)) }
        let attention = sorted.filter { $0.outcome >= .pending }
        let passing = sorted.filter { $0.outcome < .pending }
        let visible = showsPassing ? sorted : attention

        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { result in
                    CheckRow(result: result) { finding in
                        appModel.showInDiff(mr: mr, path: finding.path, line: finding.line)
                    }
                    Divider()
                }
                if !passing.isEmpty {
                    Button(showsPassing ? "Hide passed checks" : "Show \(passing.count) passed \(passing.count == 1 ? "check" : "checks")") {
                        withAnimation { showsPassing.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 6)
                }
            }
        } label: {
            HStack {
                Label("Static checks", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                summary(report)
                if appModel.staticChecks.inFlight.contains(mr.key) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .overlay {
            if report.failures > 0 {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.5), lineWidth: 1.5)
            }
        }
        .task(id: "\(mr.key)@\(mr.headSHA)") {
            await appModel.staticChecks.evaluate(mr)
        }
    }

    private func order(_ id: CheckID) -> Int {
        CheckID.allCases.firstIndex(of: id) ?? 0
    }

    private func summary(_ report: CheckReport) -> some View {
        var parts: [String] = []
        if report.failures > 0 { parts.append("\(report.failures) failing") }
        if report.warnings > 0 { parts.append("\(report.warnings) \(report.warnings == 1 ? "warning" : "warnings")") }
        if report.pending > 0 { parts.append("\(report.pending) pending") }
        return Text(parts.isEmpty ? "All passing" : parts.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(report.failures > 0 ? .red : .secondary)
    }
}

private struct CheckRow: View {
    let result: CheckResult
    let open: (PatternFinding) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.outcome.systemImage)
                    .foregroundStyle(result.outcome.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.outcome.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(result.outcome.color)
                if !result.findings.isEmpty {
                    Button(isExpanded ? "Hide" : "Show") { isExpanded.toggle() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(result.outcome.label): \(result.title). \(result.detail)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.findings, id: \.self) { finding in
                        Button { open(finding) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(finding.path):\(finding.line)")
                                    .foregroundStyle(Color.accentColor)
                                Text(finding.rule).foregroundStyle(.secondary)
                                Text(finding.excerpt)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.caption.monospaced())
                        }
                        .buttonStyle(.plain)
                        .help("Show in Changes")
                        .accessibilityLabel("\(finding.rule) at \(finding.path) line \(finding.line). Show in Changes.")
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }
}

extension CheckOutcome {
    var label: String {
        switch self {
        case .pass: "Passed"
        case .fail: "Failed"
        case .warning: "Warning"
        case .pending: "Pending"
        case .notApplicable: "N/A"
        }
    }

    var systemImage: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .pending: "clock"
        case .notApplicable: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .fail: .red
        case .warning: .orange
        case .pending: .blue
        case .notApplicable: .secondary
        }
    }
}
