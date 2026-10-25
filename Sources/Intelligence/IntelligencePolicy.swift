import Foundation

/// The one energy rule for background intelligence (#523): classification, overview warm-up, story images and World
/// Tension pause in Low Power Mode and from the serious thermal state on; clustering runs with the rules alone and
/// defers what its models would have decided (#534). Every caller used to carry its own copy.
enum IntelligencePolicy {
    static func allowsEnergy(_ info: ProcessInfo = .processInfo) -> Bool {
        !info.isLowPowerModeEnabled && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}
