// GlassSystem.swift
// NewsApp Frosted Surface & Native Liquid Glass System

import SwiftUI

// MARK: - Surface Elevation & Tint Tokens

public enum FrostedElevation: Sendable {
    case control    // Floating toolbars, segmented pickers, buttons
    case card       // AI summary cards, popovers, containers
    case elevated   // Dialogs, sheets, modals

    var shadowRadius: CGFloat {
        switch self {
        case .control: return 12.0
        case .card: return 8.0
        case .elevated: return 20.0
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .control: return 3.0
        case .card: return 2.0
        case .elevated: return 6.0
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .control: return 0.16
        case .card: return 0.10
        case .elevated: return 0.22
        }
    }

    var surfaceBackingOpacity: Double {
        switch self {
        case .control: return 0.65  // High legibility over bright hero imagery
        case .card: return 0.38
        case .elevated: return 0.50
        }
    }
}

// MARK: - Frosted Diffused Surface Modifier

public struct FrostedSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let elevation: FrostedElevation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(shape: S, elevation: FrostedElevation = .control) {
        self.shape = shape
        self.elevation = elevation
    }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppColor.surface, in: shape)
                .overlay(shape.stroke(AppColor.borderSubtle, lineWidth: 1))
        } else {
            content
                // 1. Apple-native diffuse material providing authentic backdrop diffusion
                .background(.ultraThinMaterial, in: shape)
                // 2. Subtle semantic surface tinting (restrained, translucent)
                .background(AppColor.surface.opacity(elevation.surfaceBackingOpacity), in: shape)
                // 3. Diffuse specular light highlight
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: shape
                )
                // 4. Delicate precision rim stroke
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                Color.white.opacity(0.10),
                                AppColor.borderSubtle
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                // 5. Restrained ambient shadow
                .shadow(
                    color: Color.black.opacity(elevation.shadowOpacity),
                    radius: elevation.shadowRadius,
                    x: 0,
                    y: elevation.shadowY
                )
        }
    }
}

// MARK: - Native Liquid Glass Modifier (macOS 26+)

public struct NativeLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppColor.surface, in: shape)
                .overlay(shape.stroke(AppColor.borderSubtle, lineWidth: 1))
        } else {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
            } else {
                content
                    .modifier(FrostedSurfaceModifier(shape: shape, elevation: .control))
            }
        }
    }
}

// MARK: - Backward Compatibility Wrapper

public struct GlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    public init(shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        content.modifier(FrostedSurfaceModifier(shape: shape, elevation: .card))
    }
}

// MARK: - View Extensions

public extension View {
    /// Applies the refined frosted diffused surface to a control, toolbar, or container.
    /// Diffuses content underneath without optical inversion or caustic mirroring.
    func frostedSurface<S: Shape>(in shape: S, elevation: FrostedElevation = .control) -> some View {
        self.modifier(FrostedSurfaceModifier(shape: shape, elevation: elevation))
    }

    /// Convenience wrapper applying a frosted diffused surface in a Capsule pill.
    func frostedPill(elevation: FrostedElevation = .control) -> some View {
        self.frostedSurface(in: Capsule(), elevation: elevation)
    }

    /// Applies Apple-native Liquid Glass (macOS 26+) where optical refraction is contextually desired.
    func nativeLiquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        self.modifier(NativeLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    // MARK: - Backward Compatibility Aliases

    /// Backward-compatible alias for liquidGlass, now routed to the stable frosted surface.
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        self.frostedSurface(in: shape, elevation: .card)
    }

    /// Backward-compatible alias for glassPill.
    func glassPill(interactive: Bool = false) -> some View {
        self.frostedPill()
    }

    /// Grouped glass container helper for macOS 26+.
    @ViewBuilder
    func inGlassContainer() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                self
            }
        } else {
            self
        }
    }

    /// Modern edge-to-edge background extension with backward compatibility.
    @ViewBuilder
    func adaptiveBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }
}
