import SwiftUI

/// One place for every surface, radius, weight and readout in the app.
///
/// Before this, the camera screen used three different materials for three floating
/// panels — a flat black at 55%, an ultra-thin material, and a solid colour — which
/// is why nothing looked like it belonged to the same app. Every floating surface
/// now goes through `sentryGlass`, so the look is decided once.
///
/// It is also the single place that knows about Liquid Glass. On iOS 26 and later a
/// surface gets the real material, which refracts and reacts to what is behind it;
/// before that it falls back to a thin material that looks deliberate rather than
/// broken. Gating it here rather than at forty call sites is what keeps the app
/// installable on iOS 17 without littering availability checks through the UI.
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

    // MARK: Type
    //
    // One scale, and nothing in it is bold. A camera app's chrome sits on top of a
    // moving picture, and weight is the wrong tool for separating it from the feed —
    // the material behind the text already does that. Weight is reserved for the one
    // control that arms the camera. Everything else is regular or medium, and every
    // number is monospaced so a changing readout does not jitter its neighbours.

    /// Section and screen headings.
    static let title = Font.system(size: 19, weight: .medium)
    /// The one line that says what the app is doing.
    static let headline = Font.system(size: 15, weight: .medium)
    /// Ordinary interface text.
    static let body = Font.system(size: 14, weight: .regular)
    /// Chips, captions, anything secondary.
    static let caption = Font.system(size: 12, weight: .regular)
    /// The quiet explanatory line under a control.
    static let footnote = Font.system(size: 11, weight: .regular)
    /// Live numbers.
    static let readout = Font.system(size: 12, weight: .regular).monospacedDigit()
    /// A cumulative figure, always rendered quieter than a live one.
    static let total = Font.system(size: 11, weight: .regular).monospacedDigit()

    /// Secondary text opacity, used everywhere rather than invented per view.
    static let dim: Double = 0.55
    static let dimmer: Double = 0.38
}

extension View {
    /// The app's one floating surface.
    func sentryGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(SentryGlass(shape: shape, interactive: interactive))
    }

    /// A readout that should not jump around as digits change.
    func sentryReadout() -> some View {
        self.font(Style.readout).lineLimit(1)
    }
}

private struct SentryGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Verified against Apple's declaration: there is exactly one overload,
            // `glassEffect(_ glass: Glass = .regular, in shape: some Shape)`. There
            // is no `isEnabled:` variant, and `interactive(_:)` takes its Bool
            // unlabelled with no documented default, so it is passed explicitly.
            content.glassEffect(interactive ? .regular.interactive(true) : .regular,
                                in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// Groups adjacent glass surfaces so they blend and morph together rather than
/// stacking as separate panes.
///
/// Apple is explicit that this is required, not cosmetic: "combine custom Liquid
/// Glass effects to improve rendering performance… using a GlassEffectContainer".
/// A row of eight chips each with its own effect is eight separate refraction
/// passes; inside a container it is one.
struct SentryGlassGroup<Content: View>: View {
    var spacing: CGFloat = Style.gap
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A chip: the app's one small, tappable, labelled thing.
///
/// Used for active layers and for anything else that is a short label with a state.
/// Having exactly one of these is most of why the screen now looks coherent —
/// previously each row invented its own padding and corner.
struct SentryChip: View {
    let title: String
    var value: String?
    /// A cumulative figure, drawn quieter and after the live one, so a session
    /// total never reads as what is in front of the camera right now.
    var total: String?
    var icon: String?
    var tone: Tone = .neutral
    var action: (() -> Void)?

    enum Tone { case neutral, active, warn, alert }

    var body: some View {
        let content = HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(Style.dim))
            }
            Text(title)
                .font(Style.caption)
                .lineLimit(1)
            if let value {
                Text(value)
                    .font(Style.readout)
                    .foregroundStyle(accent)
            }
            if let total {
                Text(total)
                    .font(Style.total)
                    .foregroundStyle(.white.opacity(Style.dimmer))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .sentryGlass(Capsule(), interactive: action != nil)
        .overlay(Capsule().stroke(accent.opacity(tone == .neutral ? 0 : 0.45),
                                  lineWidth: 1))

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var accent: Color {
        switch tone {
        case .neutral: return .white.opacity(0.75)
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
                .font(.system(size: 17, weight: .regular))
                .frame(width: Style.control, height: Style.control)
                .foregroundStyle(tone == .alert ? .red : .white)
                .sentryGlass(Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
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
