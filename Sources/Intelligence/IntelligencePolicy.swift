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

import Foundation

/// The one energy rule for background intelligence (#523): classification, overview warm-up, story images and World
/// Tension pause in Low Power Mode and from the serious thermal state on; clustering runs with the rules alone and
/// defers what its models would have decided (#534). Every caller used to carry its own copy.
enum IntelligencePolicy {
    static func allowsEnergy(_ info: ProcessInfo = .processInfo) -> Bool {
        !info.isLowPowerModeEnabled && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}
