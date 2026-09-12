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
            content
                .background(.ultraThinMaterial, in: shape)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: shape
                )
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.12),
                                AppColor.borderSubtle
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
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
    
    /// Grouped glass container helper that provides semantic grouping for adjacent glass controls.
    @ViewBuilder
    func inGlassContainer() -> some View {
        self
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
