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

public struct LiquidGlassBackdrop: View {
    let style: AppBackdropStyle

    public init(style: AppBackdropStyle = .liquidGlass) {
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .liquidGlass:
                ZStack {
                    Color.black.opacity(0.24)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.18),
                            Color(hex: "#070810").opacity(0.20),
                            Color(hex: "#0B1020").opacity(0.34),
                            Color(hex: "#05060A").opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RadialGradient(
                        colors: [
                            Color(hex: "#2B6CFF").opacity(0.18),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 12,
                        endRadius: 460
                    )
                    .blendMode(.screen)

                    RadialGradient(
                        colors: [
                            Color(hex: "#C96D4C").opacity(0.12),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: 390
                    )
                    .blendMode(.screen)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.05),
                            Color.clear,
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.overlay)
                }
            case .darkGlass:
                ZStack {
                    Color.black.opacity(0.55)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.40),
                            Color(hex: "#020308").opacity(0.45),
                            Color(hex: "#050812").opacity(0.50),
                            Color(hex: "#010103").opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RadialGradient(
                        colors: [
                            Color(hex: "#1A44AA").opacity(0.15),
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
                            Color.black.opacity(0.25)
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

    public init(style: AppChromeStyle = .panel, accent: Color = .white, shape: S) {
        self.style = style
        self.accent = accent
        self.shape = shape
    }

    public var body: some View {
        Group {
            if style == .bare {
                shape.fill(Color.clear)
            } else if style == .darkPanel {
                shape
                    .fill(.ultraThickMaterial)
                    .overlay(Color.black.opacity(0.35))
            } else {
                shape
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            Group {
                if style != .bare {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(baseTintOpacity),
                                    accent.opacity(accentTintOpacity),
                                    Color.clear
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

    private var baseTintOpacity: Double {
        switch style {
        case .panel: return 0.025
        case .header: return 0.03
        case .hud: return 0.035
        case .darkPanel: return 0.015
        case .bare: return 0
        }
    }

    private var accentTintOpacity: Double {
        switch style {
        case .panel: return 0.07
        case .header: return 0.08
        case .hud: return 0.10
        case .darkPanel: return 0.05
        case .bare: return 0
        }
    }

    private var shadowOpacity: Double {
        switch style {
        case .panel: return 0.16
        case .header: return 0.12
        case .hud: return 0.20
        case .darkPanel: return 0.25
        case .bare: return 0
        }
    }

    private var shadowRadius: CGFloat {
        switch style {
        case .panel: return 18
        case .header: return 14
        case .hud: return 22
        case .darkPanel: return 20
        case .bare: return 0
        }
    }

    private var shadowYOffset: CGFloat {
        switch style {
        case .panel: return 8
        case .header: return 6
        case .hud: return 10
        case .darkPanel: return 10
        case .bare: return 0
        }
    }

    @ViewBuilder
    private var highlight: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(style == .darkPanel ? 0.15 : 0.28),
                        Color.white.opacity(style == .darkPanel ? 0.03 : 0.06),
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
        case .panel: return 0.08
        case .header: return 0.10
        case .hud: return 0.12
        case .darkPanel: return 0.05
        case .bare: return 0
        }
    }
}

public struct GlassCardContainer<Content: View>: View {
    let style: AppChromeStyle
    let accent: Color
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    public init(
        style: AppChromeStyle = .panel,
        accent: Color = .white,
        cornerRadius: CGFloat = 24,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(style == .bare ? 0 : 10)
            .background(
                Group {
                    if style != .bare {
                        GlassPanel(
                            style: style,
                            accent: accent,
                            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                    }
                }
            )
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
        window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.34)
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            if contentView.layer == nil {
                contentView.makeBackingLayer()
            }
            contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.18).cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }
    }
}
#endif
