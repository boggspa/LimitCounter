import SwiftUI
#if os(macOS)
import AppKit
#endif

public enum AppChromeStyle {
    case panel
    case header
    case hud
    case darkPanel
    case bare
}

public enum AppBackdropStyle {
    case liquidGlass
    case darkGlass
    case ultraThinMaterial
}

public enum GlassIntensity: String, Codable, CaseIterable, Hashable {
    case dashboard
    case popover
    case floatingPanel
    case widget
    case settings

    var backdropInkOpacity: Double {
        switch self {
        case .dashboard: return 0.0  // was 0.34 → 0.10 → 0.04 → 0 — window ink removed entirely for pure see-through dashboard
        case .popover: return 0.28
        case .floatingPanel: return 0.24
        case .widget: return 0.26
        case .settings: return 0.32
        }
    }

    var darkBackdropInkOpacity: Double {
        switch self {
        case .dashboard: return 0.42
        case .popover: return 0.34
        case .floatingPanel: return 0.30
        case .widget: return 0.32
        case .settings: return 0.38
        }
    }

    var ambientGradientOpacity: Double {
        switch self {
        case .dashboard, .settings: return 0.050
        case .popover: return 0.045
        case .floatingPanel: return 0.040
        case .widget: return 0.050
        }
    }

    var accentGlowOpacity: Double {
        switch self {
        case .dashboard, .settings: return 0.055
        case .popover: return 0.050
        case .floatingPanel: return 0.045
        case .widget: return 0.050
        }
    }

    var panelDarkeningScale: Double {
        switch self {
        case .dashboard: return 0.82
        case .popover: return 0.72
        case .floatingPanel: return 0.64
        case .widget: return 0.70
        case .settings: return 0.78
        }
    }

    var shadowScale: Double {
        switch self {
        case .dashboard: return 0.68
        case .popover: return 0.52
        case .floatingPanel: return 0.50
        case .widget: return 0.44
        case .settings: return 0.58
        }
    }

    var borderScale: Double {
        switch self {
        case .dashboard: return 0.76
        case .popover: return 0.88
        case .floatingPanel: return 0.92
        case .widget: return 0.78
        case .settings: return 0.82
        }
    }
}

public enum ProGlassTheme {
    public static let accent = Color(hex: "#0A84FF")
    public static let panelAccent = Color(hex: "#5B8AF5")
    public static let ink = Color(hex: "#05070D")
    public static let charcoal = Color(hex: "#0A0D14")
    public static let elevatedCharcoal = Color(hex: "#111520")
    public static let hairline = Color.white.opacity(0.105)
}

public struct LiquidGlassBackdrop: View {
    let style: AppBackdropStyle
    let intensity: GlassIntensity

    public init(style: AppBackdropStyle = .liquidGlass, intensity: GlassIntensity = .dashboard) {
        self.style = style
        self.intensity = intensity
    }

    public var body: some View {
        Group {
            switch style {
            case .liquidGlass:
                ZStack {
                    // Backdrop material is intensity-dependent:
                    //   • `.dashboard` (the main window) → NO material,
                    //     so the desktop shows through cleanly and the
                    //     per-card `.glassEffect()` does the work.
                    //   • Everything else — `.settings`, `.popover`,
                    //     `.floatingPanel`, `.widget` — KEEPS the
                    //     `.ultraThinMaterial` so config sheets, the
                    //     menu-bar popover, and provider windows stay
                    //     readable. Stripping it globally (an earlier
                    //     change) made those surfaces transparent and
                    //     unusable.
                    if intensity == .dashboard {
                        Color.clear
                    } else {
                        Color.clear
                            .background(.ultraThinMaterial)
                    }

                    ProGlassTheme.ink.opacity(intensity.backdropInkOpacity)

                    LinearGradient(
                        colors: [
                            Color(hex: "#060810").opacity(intensity.ambientGradientOpacity),
                            Color(hex: "#0A1020").opacity(intensity.ambientGradientOpacity),
                            Color(hex: "#111326").opacity(intensity.ambientGradientOpacity * 0.8),
                            Color.black.opacity(intensity.ambientGradientOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RadialGradient(
                        colors: [
                            ProGlassTheme.accent.opacity(intensity.accentGlowOpacity),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.78, y: 0.12),
                        startRadius: 12,
                        endRadius: 520
                    )
                    .blendMode(.screen)

                    RadialGradient(
                        colors: [
                            Color(hex: "#6B5CFF").opacity(intensity.accentGlowOpacity * 0.6),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.18, y: 0.08),
                        startRadius: 10,
                        endRadius: 430
                    )
                    .blendMode(.screen)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.030),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.overlay)
                }
            case .darkGlass:
                ZStack {
                    Color.clear
                        .background(.thinMaterial)

                    Color.black.opacity(intensity.darkBackdropInkOpacity)

                    LinearGradient(
                        colors: [
                            Color(hex: "#020308").opacity(intensity.ambientGradientOpacity),
                            Color(hex: "#060913").opacity(intensity.ambientGradientOpacity),
                            Color(hex: "#0B1020").opacity(intensity.ambientGradientOpacity),
                            Color.black.opacity(intensity.ambientGradientOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RadialGradient(
                        colors: [
                            ProGlassTheme.accent.opacity(intensity.accentGlowOpacity),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: 400
                    )
                    .blendMode(.screen)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.02),
                            Color.clear,
                            Color.black.opacity(0.14)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.overlay)
                }
            case .ultraThinMaterial:
                ZStack {
                    Color.black.opacity(0.12)
                    Color.clear
                        .background(.ultraThinMaterial)
                }
            }
        }
        .ignoresSafeArea()
    }
}

public struct GlassPanel<S: InsettableShape>: View {
    let style: AppChromeStyle
    let accent: Color
    let shape: S
    let intensity: GlassIntensity

    public init(style: AppChromeStyle = .panel, accent: Color = .white, shape: S, intensity: GlassIntensity = .dashboard) {
        self.style = style
        self.accent = accent
        self.shape = shape
        self.intensity = intensity
    }

    public var body: some View {
        materialLayer
        .overlay(
            Group {
                if style != .bare {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(baseTintOpacity),
                                    accent.opacity(accentTintOpacity),
                                    Color.clear,
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.softLight)
                }
            }
        )
            .overlay(style == .bare ? nil : highlight)
            .overlay(style == .bare ? nil : border)
            .shadow(color: Color.black.opacity(style == .bare ? 0 : shadowOpacity), radius: shadowRadius, y: shadowYOffset)
    }

    private var materialDarkeningOpacity: Double {
        switch style {
        case .panel: return 0.07 * intensity.panelDarkeningScale  // was 0.50 → 0.18 → 0.07 — pushed for highly-transparent provider/heatmap cards (effective ~5.7% charcoal at dashboard intensity)
        case .header: return 0.42 * intensity.panelDarkeningScale
        case .hud: return 0.48 * intensity.panelDarkeningScale     // HUD pills (refresh/settings) stay denser to remain readable as controls
        case .darkPanel: return 0
        case .bare: return 0
        }
    }

    private var baseTintOpacity: Double {
        switch style {
        case .panel: return 0.030
        case .header: return 0.040
        case .hud: return 0.045
        case .darkPanel: return 0.020
        case .bare: return 0
        }
    }

    private var accentTintOpacity: Double {
        switch style {
        case .panel: return 0.040
        case .header: return 0.050
        case .hud: return 0.070
        case .darkPanel: return 0.030
        case .bare: return 0
        }
    }

    private var shadowOpacity: Double {
        switch style {
        case .panel: return 0.28 * intensity.shadowScale
        case .header: return 0.22 * intensity.shadowScale
        case .hud: return 0.32 * intensity.shadowScale
        case .darkPanel: return 0.34 * intensity.shadowScale
        case .bare: return 0
        }
    }

    private var shadowRadius: CGFloat {
        switch style {
        case .panel: return 22
        case .header: return 18
        case .hud: return 26
        case .darkPanel: return 28
        case .bare: return 0
        }
    }

    private var shadowYOffset: CGFloat {
        switch style {
        case .panel: return 8
        case .header: return 6
        case .hud: return 10
        case .darkPanel: return 14
        case .bare: return 0
        }
    }

    @ViewBuilder
    private var highlight: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(style == .darkPanel ? 0.16 : 0.22),
                        Color.white.opacity(style == .darkPanel ? 0.035 : 0.055),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .blendMode(BlendMode.screen)
    }

    @ViewBuilder
    private var border: some View {
        shape
            .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
            .blendMode(BlendMode.overlay)
    }

    private var borderOpacity: Double {
        switch style {
        case .panel: return 0.115 * intensity.borderScale
        case .header: return 0.13 * intensity.borderScale
        case .hud: return 0.15 * intensity.borderScale
        case .darkPanel: return 0.08 * intensity.borderScale
        case .bare: return 0
        }
    }

    @ViewBuilder
    private var materialLayer: some View {
        if style == .bare {
            shape.fill(Color.clear)
        } else if #available(macOS 26.0, iOS 26.0, *) {
            // Liquid Glass on macOS 26+ / iOS 26+ — Dock-style backing.
            //
            // The layering is order-sensitive. The macOS 26 Dock and
            // Control Center use a `.regularMaterial` (or thicker)
            // backing PLUS the Liquid Glass effect on top — that's
            // what gives them their characteristic refractive-with-
            // body look. We mirror that:
            //
            //   1. `.fill(Color.clear)` — shape stays an empty mask
            //   2. `.background(shape.fill(.regularMaterial))` — the
            //      Dock-equivalent material *behind* the glass effect.
            //      Critical that this is in `.background()` rather
            //      than `.fill()` directly, otherwise SwiftUI treats
            //      the material as foreground when `.glassEffect()` is
            //      stacked above it.
            //   3. `.glassEffect(...)` — Liquid Glass adds refraction,
            //      specular highlights, and edge lensing over the
            //      backing.
            //   4. Light charcoal overlay — tunes the perceived
            //      darkness so cards stay readable on bright wallpaper.
            //
            // For `.darkPanel` we use `.thinMaterial` for a slightly
            // heavier presence appropriate to modal/popover chrome.
            // Reverted from `.regularMaterial` back to `.ultraThinMaterial`
            // — even though Apple's Dock uses a thicker backing,
            // stacking `.regularMaterial` under `.glassEffect()` here
            // causes SwiftUI to composite the glass over the
            // foreground content (text/bars disappear). `.thinMaterial`
            // exhibits the same issue. `.ultraThinMaterial` is the
            // only system material that survives the
            // background-of-`.glassEffect()` composition without
            // inverting z-order.
            shape
                .fill(Color.clear)
                .background(shape.fill(style == .darkPanel ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial)))
                .glassEffect(.regular.tint(accent.opacity(nativeGlassTintOpacity)), in: shape)
                .overlay(
                    Group {
                        if style == .darkPanel {
                            ProGlassTheme.ink.opacity(0.40 * intensity.panelDarkeningScale)
                        } else {
                            ProGlassTheme.charcoal.opacity(materialDarkeningOpacity)
                        }
                    }
                    .clipShape(shape)
                )
        } else if style == .darkPanel {
            shape
                .fill(.thinMaterial)
                .overlay(ProGlassTheme.ink.opacity(0.46 * intensity.panelDarkeningScale))
        } else {
            // Pre-macOS-26 fallback: legacy `.ultraThinMaterial` with
            // tunable charcoal darkening (the old chrome).
            shape
                .fill(.ultraThinMaterial)
                .overlay(ProGlassTheme.charcoal.opacity(materialDarkeningOpacity))
        }
    }

    private var nativeGlassTintOpacity: Double {
        switch style {
        case .panel: return 0.045
        case .header: return 0.055
        case .hud: return 0.065
        case .darkPanel: return 0.025
        case .bare: return 0
        }
    }
}

// MARK: - Liquid Glass Card Background Modifier

/// Card background modifier that applies the **Apple-recommended
/// Liquid Glass layering** on macOS 26+ / iOS 26+:
///
/// ```
/// content (text, bars, icons)
///   ↑ on top of
/// .glassEffect(.regular.tint(...))  ← refractive surround on the view itself
///   ↑ on top of
/// background charcoal overlay (tunable darkness)
///   ↑ on top of
/// background material (.regularMaterial for Dock-like body)
/// ```
///
/// Crucially, `.glassEffect()` is applied **directly on the view**,
/// not via a `.background(GlassPanel(...))` wrapper. The legacy
/// background-of-`.glassEffect()` approach inverted z-order and
/// hid card content when the backing material was thicker than
/// `.ultraThinMaterial`. Applying glass at the container level lets
/// us use `.regularMaterial` (Dock material) without burying content.
///
/// Falls back to the legacy `GlassPanel` background on pre-macOS-26.
public extension View {
    @ViewBuilder
    func glassCardBackground(
        accent: Color = .white,
        cornerRadius: CGFloat = 16,
        intensity: GlassIntensity = .dashboard,
        style: AppChromeStyle = .panel,
        // Default tuned to `.none`: the parent `LiquidGlassBackdrop`
        // already supplies the window-level material, so adding a
        // second one here would stack frosts and produce the
        // "double-blur" look that defeats transparency. The
        // `.glassEffect()` modifier handles the per-card visual
        // texture on its own. Callers presenting cards over a
        // non-frosted surface can override with `.ultraThin` / `.thin`
        // / `.regular` / `.thick`.
        material: GlassBackingMaterial = .none
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            modifier(LiquidGlassCardModifier(
                accent: accent,
                cornerRadius: cornerRadius,
                intensity: intensity,
                style: style,
                material: material
            ))
        } else {
            background(
                GlassPanel(
                    style: style,
                    accent: accent,
                    shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                    intensity: intensity
                )
            )
        }
    }
}

/// Button chrome for surfaces that sit on the glass cards.
///
/// `.glass` is a macOS 26 button style with no earlier equivalent, so it has to
/// be reached through a runtime branch — and the branch has to be real rather
/// than an `@available` annotation on a type that gets built unconditionally,
/// because a post-26 symbol is weak-imported at a lower deployment target and
/// binds to NULL at runtime instead of failing to link.
///
/// The pre-26 fallback is deliberately the plain system bordered style. It is
/// the honest substitute rather than a good one: nothing before 26 can sample
/// what is behind a button, so a chrome that matches the frosted cards around it
/// is a design problem, not a one-line default. It is isolated here so that
/// problem has exactly one place to be solved.
public extension View {
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
/// Choice of backing material for the Liquid Glass card.
///
/// **`.none`** is the recommended default when the parent surface
/// (`LiquidGlassBackdrop`) already supplies a material — adding a
/// second material here just stacks frosts, producing the "double
/// blur" look where cards become opaque even at low charcoal
/// overlay. The `.glassEffect()` modifier provides its own visual
/// texture so cards don't go invisible without a material.
///
/// Use `.ultraThin` / `.thin` / `.regular` / `.thick` when the card
/// is presented over a non-frosted surface (e.g. a popover with no
/// `LiquidGlassBackdrop`) and needs its own backing.
public enum GlassBackingMaterial {
    case none
    case ultraThin
    case thin
    case regular
    case thick

    @available(macOS 26.0, iOS 26.0, *)
    fileprivate var anyStyle: AnyShapeStyle? {
        switch self {
        case .none:      return nil
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin:      return AnyShapeStyle(.thinMaterial)
        case .regular:   return AnyShapeStyle(.regularMaterial)
        case .thick:     return AnyShapeStyle(.thickMaterial)
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private struct LiquidGlassCardModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let intensity: GlassIntensity
    let style: AppChromeStyle
    let material: GlassBackingMaterial

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var nativeGlassTintOpacity: Double {
        switch style {
        case .panel: return 0.045
        case .header: return 0.055
        case .hud: return 0.065
        case .darkPanel: return 0.025
        case .bare: return 0
        }
    }

    private var charcoalOverlayOpacity: Double {
        // Card panels stay nearly clear so the wallpaper / window
        // contents behind the app show through; `.hud` and `.darkPanel`
        // keep more body to read clearly as controls / modal chrome.
        switch style {
        case .panel: return 0.008 * intensity.panelDarkeningScale  // was 0.07 → 0.035 → 0.015 → 0.008 — cards on the verge of pure-glass; layout carries readability
        case .header: return 0.06 * intensity.panelDarkeningScale
        case .hud: return 0.18 * intensity.panelDarkeningScale
        case .darkPanel: return 0.30 * intensity.panelDarkeningScale
        case .bare: return 0
        }
    }

    private var borderOpacity: Double {
        switch style {
        case .panel: return 0.115 * intensity.borderScale
        case .header: return 0.13 * intensity.borderScale
        case .hud: return 0.15 * intensity.borderScale
        case .darkPanel: return 0.08 * intensity.borderScale
        case .bare: return 0
        }
    }

    private var shadowOpacity: Double {
        switch style {
        case .panel: return 0.28 * intensity.shadowScale
        case .header: return 0.22 * intensity.shadowScale
        case .hud: return 0.32 * intensity.shadowScale
        case .darkPanel: return 0.34 * intensity.shadowScale
        case .bare: return 0
        }
    }

    func body(content: Content) -> some View {
        // Backgrounds stack BEHIND content: first applied is closest
        // to content, later ones go further back. We put the charcoal
        // closer (just behind content) and the material (if any)
        // further back. When `material == .none`, we skip the second
        // background entirely so cards stay transparent.
        let withBackgrounds = content
            .background(
                shape.fill(ProGlassTheme.charcoal.opacity(charcoalOverlayOpacity))
            )

        let withMaterial = Group {
            if let style = material.anyStyle {
                withBackgrounds.background(shape.fill(style))
            } else {
                withBackgrounds
            }
        }

        return withMaterial
            // `.glassEffect()` is applied to the view itself, NOT as a
            // background — this is the critical difference from the
            // legacy approach. Content stays in the foreground; the
            // glass effect adds refraction + specular around the edge.
            .glassEffect(.regular.tint(accent.opacity(nativeGlassTintOpacity)), in: shape)
            // Edge stroke on top so the card outline reads clearly
            // against busy wallpapers.
            .overlay {
                shape.strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 22, y: 8)
    }
}

public struct GlassCardContainer<Content: View>: View {
    let style: AppChromeStyle
    let accent: Color
    let cornerRadius: CGFloat
    let intensity: GlassIntensity
    @ViewBuilder let content: Content

    public init(
        style: AppChromeStyle = .panel,
        accent: Color = .white,
        cornerRadius: CGFloat = 24,
        intensity: GlassIntensity = .dashboard,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.intensity = intensity
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        if style == .bare {
            content.padding(0)
        } else {
            content
                .padding(10)
                .glassCardBackground(
                    accent: accent,
                    cornerRadius: cornerRadius,
                    intensity: intensity,
                    style: style
                )
        }
    }
}

#if os(macOS)
public struct TransparentWindowConfigurator: NSViewRepresentable {
    public var cornerRadius: CGFloat = 22

    public init(cornerRadius: CGFloat = 22) {
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = NSColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 0.30)
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        // Only the dashboard's dedicated titlebar strip should move this
        // window. Background dragging also claims drags that start on meters.
        window.isMovableByWindowBackground = false

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            if contentView.layer == nil {
                contentView.makeBackingLayer()
            }
            contentView.layer?.backgroundColor = NSColor(red: 0.018, green: 0.022, blue: 0.032, alpha: 0.20).cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }
    }
}
#endif
