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

/// Entry point of the VoiceOver QA app (script/test_voiceover_live_qa.sh); script/appearance_matrix.sh compiles the
/// fixtures in LiveVoiceOverQAHarness.swift with its own entry point instead.
import AppKit
import Foundation

@main
struct LiveVoiceOverEntry {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        // Crash recovery dialogs must never block this disposable fixture's startup.
        // Argument-domain overrides are volatile and do not change the reader's real preferences.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        arguments["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        let delegate = QADelegate()
        app.delegate = delegate
        let visible =
            CommandLine.arguments.contains("--host") || CommandLine.arguments.contains("--manual")
            || CommandLine.arguments.contains("--smoke")
        app.setActivationPolicy(visible ? .regular : .prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
