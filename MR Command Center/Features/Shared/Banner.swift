import SwiftUI

/// Full-width message strip (offline, auth problems, storage warnings).
struct Banner: View {
    enum Style {
        case info, warning, error

        var tint: Color {
            switch self {
            case .info: .blue
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let message: String
    let systemImage: String
    var style: Style = .info
    var actionTitle: String?
    var action: (() -> Void)?
    /// Shows a close button when set.
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(style.tint.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}
