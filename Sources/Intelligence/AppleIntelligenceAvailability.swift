// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Angelia · Angelia Core (shared model access and gates) owns this file. Register: docs/ANGELIA.md.

import AppKit
import Foundation
import Observation
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The state of on-device Apple Intelligence across system and app settings (#1212).
public enum AppleIntelligenceState: String, CaseIterable, Equatable, Sendable {
    case ready
    case appDisabled
    case systemDisabled
    case modelDownloading
    case temporarilyBusy
    case unsupportedDevice
    case macOSVersionTooOld

    public var isAvailable: Bool { self == .ready }

    /// Short status label for headings, status pills and diagnostic reports.
    public var statusLabel: String {
        switch self {
        case .ready:
            return "Ready"
        case .appDisabled:
            return "AI story analysis is off"
        case .systemDisabled:
            return "Turned off in System Settings"
        case .modelDownloading:
            return "Model not ready"
        case .temporarilyBusy:
            return "Model busy"
        case .unsupportedDevice:
            return "Not supported on this Mac"
        case .macOSVersionTooOld:
            return "Requires newer macOS"
        }
    }

    /// User-facing sentence explaining the current state and what stands in.
    public var explanation: String {
        switch self {
        case .ready:
            return "The on-device model is ready on this Mac."
        case .appDisabled:
            return
                "Turn on AI story analysis in Settings → Intelligence to assess World Tension and generate overviews."
        case .systemDisabled:
            return
                "Apple Intelligence is turned off in System Settings. Turn it on in System Settings → Apple Intelligence."
        case .modelDownloading:
            return
                "The on-device language model is not ready yet, for example while it downloads. Keyword and extractive estimates stand in."
        case .temporarilyBusy:
            return "The on-device model is temporarily busy. Analysis will retry automatically after the next refresh."
        case .unsupportedDevice:
            return "This Mac does not support Apple Intelligence. Keyword estimates and extractive summaries stand in."
        case .macOSVersionTooOld:
            return "On-device Apple Intelligence requires macOS 26 or later. Keyword and extractive estimates stand in."
        }
    }

    /// Button title for restoring or configuring the model, or nil if no action applies.
    public var actionTitle: String? {
        switch self {
        case .ready, .modelDownloading, .temporarilyBusy, .unsupportedDevice:
            return nil
        case .appDisabled:
            return "Turn On in Settings"
        case .systemDisabled:
            return "Open System Settings…"
        case .macOSVersionTooOld:
            return "Software Update…"
        }
    }

    /// Executes the corrective action for the state.
    @MainActor
    public func performAction() {
        switch self {
        case .appDisabled:
            AppSettings.shared.setAIEnabled(true)
        case .systemDisabled:
            if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence") {
                NSWorkspace.shared.open(url)
            }
        case .macOSVersionTooOld:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") {
                NSWorkspace.shared.open(url)
            }
        case .ready, .modelDownloading, .temporarilyBusy, .unsupportedDevice:
            break
        }
    }
}

/// Unified on-device Apple Intelligence availability service (#1212).
/// Read once, observed for changes, and injected for testing across feature surfaces.
@MainActor
@Observable
public final class AppleIntelligenceAvailability {
    public static let shared = AppleIntelligenceAvailability()

    private static let logger = Logger(subsystem: "com.marspater.news", category: "AppleIntelligenceAvailability")

    /// Injected mock state for unit and regression testing.
    public var mockState: AppleIntelligenceState?

    public init() {}

    /// Current availability state combining app settings, OS version and FoundationModels availability.
    public var state: AppleIntelligenceState {
        if let mock = mockState { return mock }
        return Self.resolveState(aiEnabled: AppSettings.shared.aiEnabled)
    }

    /// Classifies an availability description or FoundationModels unavailable reason string into AppleIntelligenceState.
    public nonisolated static func classifyAvailability(_ reason: String) -> AppleIntelligenceState {
        let lower = reason.lowercased()
        if lower.contains("available") && !lower.contains("unavailable") {
            return .ready
        }
        if lower.contains("devicenoteligible") || lower.contains("ineligible") || lower.contains("unsupported") {
            return .unsupportedDevice
        }
        if lower.contains("appleintelligencenotenabled") || lower.contains("notenabled") || lower.contains("disabled")
            || lower.contains("settings")
        {
            return .systemDisabled
        }
        if lower.contains("modelnotready") || lower.contains("notready") || lower.contains("download")
            || lower.contains("asset")
        {
            return .modelDownloading
        }
        return .temporarilyBusy
    }

    /// Pure evaluation function allowing testing of environment combinations without global mutation.
    public nonisolated static func resolveState(
        aiEnabled: Bool,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        foundationModelsAvailability: String? = nil
    ) -> AppleIntelligenceState {
        guard aiEnabled else { return .appDisabled }

        if osVersion.majorVersion < 26 {
            return .macOSVersionTooOld
        }

        if let explicit = foundationModelsAvailability {
            return classifyAvailability(explicit)
        }

        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let avail = SystemLanguageModel.default.availability
                switch avail {
                case .available:
                    return .ready
                case .unavailable(let reason):
                    return classifyAvailability(String(describing: reason))
                }
            }
        #endif

        // On builds/macOS without FoundationModels support:
        if osVersion.majorVersion < 26 {
            return .macOSVersionTooOld
        }
        return .unsupportedDevice
    }
}
