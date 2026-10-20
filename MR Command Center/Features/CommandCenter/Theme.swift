import SwiftUI

/// The command center's look: warm paper, dark ink, one signal color per lane.
/// The app always runs in light appearance (see `MRCommandCenterApp`), so these are light-only.
enum Theme {
    static let canvas = Color(hex: 0xF6F3EC)
    static let surface = Color.white
    static let sunken = Color(hex: 0xEEE9DF)
    static let hairline = Color(hex: 0xE2DCCF)
    static let ink = Color(hex: 0x1E1C18)
    static let inkSecondary = Color(hex: 0x6A6358)
    static let inkTertiary = Color(hex: 0x9C9486)

    static let yourMove = Color(hex: 0xD9480F)
    static let ready = Color(hex: 0x2B8A3E)
    static let autoMerge = Color(hex: 0x6741D9)
    static let inFlight = Color(hex: 0x1C6DD0)
    static let draft = Color(hex: 0x868E96)
    static let danger = Color(hex: 0xC92A2A)
    static let caution = Color(hex: 0xD98200)

    static func color(for lane: Lane) -> Color {
        switch lane {
        case .yourMove: yourMove
        case .readyToMerge: ready
        case .autoMerge: autoMerge
        case .inFlight: inFlight
        case .drafts: draft
        }
    }

    static func color(for state: ReadinessStep.State) -> Color {
        switch state {
        case .done: ready
        case .waiting: caution
        case .blocked: danger
        case .unknown: hairline
        }
    }

    static func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .pipelinePassed, .approved, .threadsResolved, .conflictsCleared, .readyToMerge: ready
        case .pipelineFailed, .conflicts, .autoMergeFailed, .approvalRevoked: danger
        case .replied: yourMove
        case .autoMerged, .autoMergeWouldMerge: autoMerge
        case .appeared, .pushed: inFlight
        case .left, .other: inkTertiary
        }
    }

    static func systemImage(for kind: ActivityKind) -> String {
        switch kind {
        case .appeared: "tray.and.arrow.down.fill"
        case .pushed: "arrow.up.circle.fill"
        case .pipelinePassed: "checkmark.circle.fill"
        case .pipelineFailed: "xmark.circle.fill"
        case .approved: "checkmark.seal.fill"
        case .approvalRevoked: "seal"
        case .replied: "arrowshape.turn.up.left.fill"
        case .threadsResolved: "bubble.left.and.bubble.right.fill"
        case .conflicts: "exclamationmark.triangle.fill"
        case .conflictsCleared: "checkmark.diamond.fill"
        case .readyToMerge: "flag.checkered"
        case .left: "archivebox.fill"
        case .autoMerged: "wand.and.stars"
        case .autoMergeWouldMerge: "wand.and.rays"
        case .autoMergeFailed: "exclamationmark.octagon.fill"
        case .other: "circle.fill"
        }
    }

    /// Newspaper-style headlines.
    static func headline(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    /// Small caps-style section labels.
    static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A white card on the canvas with a hairline edge.
struct CardBackground: ViewModifier {
    var isSelected = false
    var accent: Color = Theme.ink

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? accent : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: isSelected ? 6 : 2, y: 1)
    }
}

extension View {
    func card(isSelected: Bool = false, accent: Color = Theme.ink) -> some View {
        modifier(CardBackground(isSelected: isSelected, accent: accent))
    }
}

/// Initials in a circle, colored consistently per person.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var color: Color {
        let palette: [UInt32] = [0x5C7CFA, 0x20C997, 0xF76707, 0xAE3EC9, 0x1098AD, 0xE64980, 0x74B816, 0x7950F2]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: palette[hash % palette.count])
    }
}

/// The four-segment "how close to merge" rail: CI · Approvals · Threads · Mergeable.
struct ReadinessRail: View {
    let readiness: Readiness
    var showsLabels = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(readiness.steps) { step in
                VStack(alignment: .leading, spacing: 3) {
                    Capsule()
                        .fill(Theme.color(for: step.state))
                        .overlay {
                            if step.state == .unknown {
                                Capsule().strokeBorder(Theme.inkTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            }
                        }
                        .frame(height: 5)
                    if showsLabels {
                        Text(label(for: step))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(step.state == .done ? Theme.inkTertiary : Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .help("\(step.kind.shortTitle): \(step.summary)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readiness.steps.map { "\($0.kind.shortTitle): \($0.summary)" }.joined(separator: ", "))
    }

    private func label(for step: ReadinessStep) -> String {
        switch (step.kind, step.state) {
        case (.approvals, .waiting): step.summary
        case (.threads, .waiting): step.summary
        default: step.kind.shortTitle
        }
    }
}

/// A rounded tag with a colored dot.
struct LanePill: View {
    let lane: Lane

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: lane.systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(lane.title.uppercased())
                .font(Theme.eyebrow)
        }
        .foregroundStyle(Theme.color(for: lane))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.color(for: lane).opacity(0.1), in: .capsule)
    }
}
