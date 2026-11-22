import SwiftUI

/// One place for every surface, radius and readout in the app.
///
/// Before this, the camera screen used three different materials for three
/// floating panels — a flat black at 55%, an ultra-thin material, and a solid
/// colour — which is why nothing looked like it belonged to the same app. Every
/// floating surface now goes through `sentryGlass`, so the look is decided once.
///
/// It is also the single place that knows about Liquid Glass. On iOS 26 and later
/// a surface gets the real material, which refracts and reacts to what is behind
/// it; before that it falls back to a thin material that looks deliberate rather
/// than broken. Gating it here rather than at forty call sites is what keeps the
/// app installable on iOS 17 without littering availability checks through the UI.
enum Style {
    /// Floating controls and pills.
    static let radiusSmall: CGFloat = 12
    /// Panels and cards.
    static let radiusMedium: CGFloat = 18
    /// Tap targets. 44pt is Apple's minimum and smaller is genuinely hard to hit
    /// one-handed on a phone that is propped up somewhere awkward.
    static let control: CGFloat = 46

    static let gap: CGFloat = 10
    static let inset: CGFloat = 12

    /// Flipped on once the real Liquid Glass call sites are verified against
    /// Apple's declarations. Until then every surface takes the material path,
    /// which looks deliberate rather than broken.
    static let liquidGlassEnabled = false
}

extension View {
    /// The app's one floating surface.
    func sentryGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(SentryGlass(shape: shape, interactive: interactive))
    }

    /// A readout that should not jump around as digits change.
    func sentryReadout() -> some View {
        self.font(.system(size: 12, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct SentryGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if Style.liquidGlassEnabled, #available(iOS 26.0, *) {
            // Liquid Glass. `interactive` is for things that are tapped, which
            // makes the material respond to touch rather than sit inert.
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// A chip: the app's one small, tappable, labelled thing.
///
/// Used for active layers and for anything else that is a short label with a
/// state. Having exactly one of these is most of why the screen now looks
/// coherent — previously each row invented its own padding and corner.
struct SentryChip: View {
    let title: String
    var value: String?
    var icon: String?
    var tone: Tone = .neutral
    var action: (() -> Void)?

    enum Tone { case neutral, active, warn, alert }

    var body: some View {
        let content = HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .sentryGlass(Capsule(), interactive: action != nil)
        .overlay(Capsule().stroke(accent.opacity(tone == .neutral ? 0.18 : 0.55), lineWidth: 1))

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var accent: Color {
        switch tone {
        case .neutral: return .white
        case .active:  return .cyan
        case .warn:    return .orange
        case .alert:   return .red
        }
    }
}

/// A round icon button, the app's one tool control.
struct SentryToolButton: View {
    let icon: String
    var label: String?
    var badge: Int = 0
    var tone: SentryChip.Tone = .neutral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: Style.control, height: Style.control)
                .foregroundStyle(tone == .alert ? .red : .white)
                .sentryGlass(Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 6, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? icon)
    }
}
