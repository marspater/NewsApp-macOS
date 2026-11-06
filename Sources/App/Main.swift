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

/// The app's entry point, in a file of its own: the test runner and the harness apps compile every other file under
/// Sources/ with their own @main (News.xcodeproj excludes this one from those targets).
@main
enum NewsMain {
    static func main() {
        NewsApp.main()
    }
}
