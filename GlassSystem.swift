// GlassSystem.swift
// NewsApp Liquid Glass & Platform Behavioral System

import SwiftUI

// MARK: - App Glass Tokens & Configurations

@available(macOS 26.0, *)
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
                .background(AppColor.surface, in: shape)
                .overlay(shape.stroke(AppColor.borderSubtle, lineWidth: 1))
        } else {
            if #available(macOS 26.0, *) {
                if interactive {
                    content.glassEffect(AppGlass.interactive, in: shape)
                } else {
                    content.glassEffect(AppGlass.control, in: shape)
                }
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(AppColor.borderSubtle, lineWidth: 0.5))
            }
        }
    }
}

public extension View {
    /// Applies the native Liquid Glass effect to a control or navigation element with fallback for earlier macOS versions.
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        self.modifier(GlassControlModifier(shape: shape, interactive: interactive))
    }
    
    /// Applies the native Liquid Glass effect in a capsule pill shape.
    func glassPill(interactive: Bool = false) -> some View {
        self.liquidGlass(in: Capsule(), interactive: interactive)
    }
    
    /// Grouped glass container helper that allows adjacent glass elements to morph and render efficiently.
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
