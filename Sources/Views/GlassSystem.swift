// GlassSystem.swift
// NewsApp Liquid Glass helpers. See docs/DESIGN.md, sections 3 and 4.
//
// Feature views apply custom glass only through these helpers. System glass
// (toolbars, sidebars, menus, popovers, sheets) needs no helper.

import SwiftUI

// MARK: - Native Liquid Glass Modifier

/// Liquid Glass on macOS 26 and later; the system adapts it to Reduce Transparency
/// and Increase Contrast. On macOS 15 the surface falls back to the regular material,
/// or an opaque surface with a separator stroke under Reduce Transparency.
public struct NativeLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else if reduceTransparency {
            content
                .background(AppColor.surface, in: shape)
                .overlay(shape.stroke(AppColor.separator, lineWidth: 1))
        } else {
            content
                .background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - View Extensions

public extension View {
    /// Custom Liquid Glass for a floating control (DESIGN.md 3.2). Apply it last,
    /// after the control's content and padding. Never inside content or on another glass surface.
    func nativeLiquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        self.modifier(NativeLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    /// Groups nearby custom glass so it samples, blends and morphs as one surface on macOS 26 and later.
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

    /// Glass button style for floating buttons: `.glass` or `.glassProminent` on macOS 26 and later,
    /// `.bordered` or `.borderedProminent` on macOS 15.
    @ViewBuilder
    func nativeGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
