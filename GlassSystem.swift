// GlassSystem.swift
// NewsApp Liquid Glass & Platform Behavioral System

import SwiftUI

// MARK: - App Glass Tokens & Configurations

public enum AppGlass {
    /// Standard glass material for static controls and navigation framing.
    public static let control = Glass.regular
    
    /// Interactive glass material with responsive hover/press behavior.
    public static let interactive = Glass.regular.interactive()
}

// MARK: - Glass Modifiers & View Extensions

public struct GlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppColor.surfaceMid, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
        } else {
            if interactive {
                content
                    .glassEffect(AppGlass.interactive, in: shape)
            } else {
                content
                    .glassEffect(AppGlass.control, in: shape)
            }
        }
    }
}

public extension View {
    /// Applies the native Liquid Glass effect to a control or navigation element.
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        self.modifier(GlassControlModifier(shape: shape, interactive: interactive))
    }
    
    /// Grouped glass container helper that allows adjacent glass elements to morph and render efficiently.
    @ViewBuilder
    func inGlassContainer() -> some View {
        GlassEffectContainer {
            self
        }
    }
}
