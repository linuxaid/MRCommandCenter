import SwiftUI

/// A GitLab label in its GitLab colors. The name is always shown, so color is never the only signal.
struct LabelChip: View {
    let name: String
    let style: LabelStyle?

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .fixedSize()
            .accessibilityLabel("Label \(name)")
    }

    private var background: Color {
        style.flatMap { Color(hex: $0.color) } ?? Color.secondary.opacity(0.2)
    }

    private var foreground: Color {
        style?.textColor.flatMap { Color(hex: $0) } ?? .primary
    }
}

/// All of an MR's labels, wrapping.
struct LabelList: View {
    let labels: [String]
    let styles: [String: LabelStyle]

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(labels, id: \.self) { name in
                LabelChip(name: name, style: styles[name])
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: \(labels.joined(separator: ", "))")
    }
}

extension Color {
    /// Parses `#RGB` or `#RRGGBB`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
