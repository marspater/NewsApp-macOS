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

/// The app's entry point, in a file of its own: the test runner and the harness apps compile every other file under
/// Sources/ with their own @main (News.xcodeproj excludes this one from those targets).
@main
enum NewsMain {
    /// Starts the SwiftUI app. Outside an app bundle (the Swift package's `News` executable, which Xcode runs when the
    /// repository folder is opened instead of News.xcodeproj) macOS has no bundle record for the process, and
    /// UserNotifications throws on first use, so the binary stops with a pointer to the project instead of crashing.
    static func main() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            let message = """
                News must run as News.app: open News.xcodeproj in Xcode (not the folder or Package.swift), or run \
                ./build.sh. The Swift package executable is for compile checks only.

                """
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
        NewsApp.main()
    }
}
